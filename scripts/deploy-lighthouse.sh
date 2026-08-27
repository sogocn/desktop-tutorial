#!/usr/bin/env bash
# 家庭任务日历 —— 轻量云一键部署脚本（在实例上以 root 运行）
# 前置：仓库已 clone 到 $REPO_DIR，且当前 Shell 工作目录就是仓库根。
# 用法： bash scripts/deploy-lighthouse.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_USER="fq"
APP_HOME="/var/www/familyquest"
PG_USER="familyquest"
PG_DB="familyquest"
PG_PASS="$(openssl rand -hex 16)"
JWT_SECRET="$(openssl rand -hex 32)"
PORT=3000

echo "==> 仓库目录: $REPO_DIR"

# ---- 1. 系统依赖 ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx postgresql postgresql-contrib curl ca-certificates gnupg git openssl

# ---- 2. Node 22 ----
if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
echo "==> node $(node -v)"

# ---- 3. 应用用户 + 目录 ----
id -u "$APP_USER" &>/dev/null || useradd -r -m -s /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_HOME"
cp -r "$REPO_DIR"/dist "$APP_HOME"/dist
cp -r "$REPO_DIR"/server "$APP_HOME"/server
cp -r "$REPO_DIR"/db "$APP_HOME"/db
chown -R "$APP_USER":"$APP_USER" "$APP_HOME"

# ---- 4. Postgres：建库 + 用户 ----
PGVER="$(ls /usr/lib/postgresql | sort -n | tail -1)"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname='$PG_USER') then
    create user $PG_USER with password '$PG_PASS' createrole bypassrls;
  else
    alter user $PG_USER with password '$PG_PASS' createrole bypassrls;
  end if;
end \$\$;
SQL
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "select 1 from pg_database where datname='$PG_DB'" | grep -q 1 || \
  sudo -u postgres createdb -O "$PG_USER" "$PG_DB"

# ---- 5. 前端运行依赖 + 构建（已在仓库 dist/，这里仅装 server 运行依赖）----
cd "$APP_HOME"/server
npm install --omit=dev pg express jsonwebtoken tsx @types/pg @types/express @types/jsonwebtoken
chown -R "$APP_USER":"$APP_USER" "$APP_HOME"/server

# ---- 6. 环境变量 ----
cat > "$APP_HOME"/server/.env <<ENV
DATABASE_URL=postgres://$PG_USER:$PG_PASS@127.0.0.1:5432/$PG_DB
JWT_SECRET=$JWT_SECRET
PORT=$PORT
ENV
chown "$APP_USER":"$APP_USER" "$APP_HOME"/server/.env

# ---- 7. 跑迁移（以 root 运行；PG 连接身份由 DATABASE_URL 决定，与 OS 用户无关）----
cd "$APP_HOME"/server
env "DATABASE_URL=postgres://$PG_USER:$PG_PASS@127.0.0.1:5432/$PG_DB" \
  ./node_modules/.bin/tsx migrate.ts

# 迁移创建了 authenticated 角色，让 API 连接用户能 SET ROLE
sudo -u postgres psql -d "$PG_DB" -c "grant authenticated to $PG_USER;" || true

# ---- 8. systemd 守护 API ----
cat > /etc/systemd/system/familyquest-api.service <<UNIT
[Unit]
Description=FamilyQuest API
After=network.target postgresql.service

[Service]
WorkingDirectory=$APP_HOME/server
EnvironmentFile=$APP_HOME/server/.env
ExecStart=$APP_HOME/server/node_modules/.bin/tsx $APP_HOME/server/index.ts
Restart=on-failure
User=$APP_USER

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now familyquest-api
# tsx 冷启动（即时转译）需要几秒，做重试避免误判
health_ok=0
for i in 1 2 3 4 5 6 7 8; do
  if curl -fsS "http://127.0.0.1:$PORT/api/health"; then health_ok=1; break; fi
  sleep 2
done
if [ "$health_ok" -ne 1 ]; then
  echo "API 健康检查失败（已重试）"; systemctl status familyquest-api --no-pager; exit 1
fi

# ---- 9. nginx ----
sed "s#/var/www/familyquest/dist#$APP_HOME/dist#g" "$REPO_DIR"/deploy/nginx.conf > /etc/nginx/conf.d/familyquest.conf
nginx -t
systemctl reload nginx || systemctl restart nginx

echo "==> 部署完成。前端 http://<实例IP>/ ，API 健康检查通过。"
