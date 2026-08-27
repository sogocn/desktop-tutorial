# 家庭任务日历 —— 自托管部署（轻量云）

目标：在一台腾讯云轻量应用服务器上，用 nginx 托管前端静态文件、用 Node 跑
`server/` 代理、用本机 Postgres 存数据，实现「一家人看到同一份数据」的多端同步。
**不上 HTTPS**（按需求），令牌明文传输，仅建议家庭内网/自家机器使用。

## 架构

```
浏览器(familyquest 前端)
   │  /           静态资源(nginx)
   │  /api/*  ──► nginx ──► Node API(:3000, server/)
   │                                  │
   │                                  ▼
   │                            Postgres(本机 :5432)
   │  RLS 按 request.jwt.claims.sub 隔离，写操作全走 app.* 函数
```

- 前端：React + Vite，`dist/` 静态托管，业务代码零改动（只换了 backend adapter）。
- 后端：`server/`（Express 代理 + 自签 JWT）。保留 `BackendClient.query/rpc` 语义，
  每次请求 `SET LOCAL ROLE authenticated` + 写入 `request.jwt.claims`，与本地 PGlite
  adapter 的 RLS 验证模式完全一致。
- 数据：Postgres + `db/migrations/*.sql`（与本地同一份 DDL）+ `050_server_auth.sql`
  （自托管专属：成员登录密钥）。

## 一、轻量云实例

1. 轻量云控制台新建 **Ubuntu 22.04** 实例（2 核 2G 远超所需）。
2. 防火墙放行 **22**(SSH) 与 **80**(HTTP)。控制台操作，不在 nginx 里配。
3. SSH 登录。

## 二、装依赖

```bash
# nginx
sudo apt update && sudo apt install -y nginx

# Postgres
sudo apt install -y postgresql postgresql-contrib

# Node 22（用 NodeSource 或 nvm；需 >=20）
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
```

## 三、建数据库

```bash
sudo -u postgres psql <<'SQL'
create user familyquest with password 'CHANGE_ME';
create database familyquest owner familyquest;
grant authenticated to familyquest;   -- 让 API 连接用户能 SET ROLE authenticated
SQL
```
> 注：`authenticated` 角色由迁移里的 `db/local/000_shim.sql` 自动创建，
> 上面这条 grant 需等迁移跑过一次后再执行（或迁移后补执行）。

## 四、上传代码

```bash
# 本地构建前端
npm install
npm run build                # 产出 dist/

# 把 dist/ 和 server/ 传到实例，例如
rsync -avz dist/  用户@IP:/var/www/familyquest/dist
rsync -avz server/ 用户@IP:/var/www/familyquest/server
```

实例上在 `/var/www/familyquest` 装运行依赖：

```bash
cd /var/www/familyquest/server
npm install pg express jsonwebtoken tsx @types/pg @types/express @types/jsonwebtoken
```

## 五、环境变量

在 API 服务环境里设置（systemd 的 Environment 或 .env）：

```
DATABASE_URL=postgres://familyquest:CHANGE_ME@127.0.0.1:5432/familyquest
JWT_SECRET=<随机长串>
PORT=3000
```

## 六、跑迁移

```bash
cd /var/www/familyquest/server
npx tsx migrate.ts
# 跑完后补执行上面的 grant authenticated to familyquest
sudo -u postgres psql -d familyquest -c "grant authenticated to familyquest;"
```

## 七、用 systemd 守护 API

`/etc/systemd/system/familyquest-api.service`：

```ini
[Unit]
Description=FamilyQuest API
After=network.target postgresql.service

[Service]
WorkingDirectory=/var/www/familyquest/server
EnvironmentFile=/var/www/familyquest/server/.env
ExecStart=/usr/bin/npx tsx /var/www/familyquest/server/index.ts
Restart=on-failure
User=www-data

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now familyquest-api
curl http://127.0.0.1:3000/api/health   # 应返回 {"ok":true}
```

## 八、配 nginx

把 `deploy/nginx.conf` 传到 `/etc/nginx/conf.d/familyquest.conf`，**改两处**：
- `root /var/www/familyquest/dist;`
- `server_name` 可留 `_`（IP 直访）

```bash
sudo nginx -t && sudo systemctl reload nginx
```

## 九、开防火墙 & 验收

1. 轻量云控制台确认 **80** 已放行。
2. 浏览器开 `http://<实例IP>`：
   - 建家庭 → 后端返回身份，`knownUsers` 里带了 `loginKey`；
   - 另一台设备/浏览器用邀请码「加入家庭」→ 各自拿到独立身份；
   - 两边数据互通（同一份家庭数据）。
3. 想换设备保留同一身份：把该身份的 `userId + loginKey` 从「我」页导出，
   在新设备导入（前端需补一个身份卡导入入口，见下方待办）。

## 待办 / 已知限制

- **身份卡导入 UI**：后端已支持 `(user_id, login_key)` 跨设备迁移，但「我」页导出/
  导入入口尚未做，目前同一人换设备需手动迁移 localStorage 中的身份（或后续补 UI）。
- **不上 HTTPS**：令牌明文，公网勿用。
- **清空数据 / 本地备份**：云端模式下 `reset()` 与本地 `dump()` 不适用（已在 adapter
  中返回明确提示），后续可加服务端「解散家庭」接口。
