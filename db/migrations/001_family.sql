-- =============================================================================
-- 001_family.sql —— 家庭 / 成员 / 邀请 / 家长会话
-- =============================================================================

create table app.families (
  id                        uuid primary key default gen_random_uuid(),
  name                      text not null check (length(btrim(name)) between 1 and 40),

  -- 时间语义的三个源头字段 ------------------------------------------------
  -- IANA 时区名，不存 'UTC+8'：夏令时和历史时区变更只有 IANA 名扛得住。
  timezone                  text not null default 'Asia/Shanghai',
  -- "22 点后完成算不算当天"。设 2 表示凌晨 0~2 点仍算前一天。
  day_cutoff_hour           smallint not null default 0 check (day_cutoff_hour between 0 and 6),

  -- 防刷分参数 -------------------------------------------------------------
  child_task_points_policy  text not null default 'capped'
                              check (child_task_points_policy in ('free', 'capped', 'zero')),
  child_task_points_cap     int  not null default 5   check (child_task_points_cap >= 0),
  child_daily_points_cap    int  not null default 200 check (child_daily_points_cap >= 0),

  -- 惰性月结算用（M3）
  last_settled_month        date,

  created_at                timestamptz not null default now()
);

create table app.members (
  id             uuid primary key default gen_random_uuid(),
  family_id      uuid not null references app.families(id) on delete cascade,
  -- 对应 auth.uid()。家长在自己设备上注册时 = 当前登录用户；
  -- 家长代建的孩子成员先占一个 uuid，孩子拿邀请码在自己设备上认领时改写。
  user_id        uuid unique,
  nickname       text not null check (length(btrim(nickname)) between 1 and 20),
  role           text not null check (role in ('parent', 'child')),
  avatar_emoji   text not null default '🙂',

  -- 余额只是缓存，真值永远是 sum(point_ledger.delta)，见 app.reconcile_balance()
  points_balance int  not null default 0,

  pin_hash       text,
  pin_salt       text,

  archived_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index members_family_idx on app.members (family_id);

-- 设备绑定（共享平板上记住"这台设备默认是谁"）。M1 只落表不用。
create table app.member_devices (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references app.members(id) on delete cascade,
  device_key  text not null,
  label       text,
  last_seen_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  constraint uq_member_device unique (member_id, device_key)
);

create table app.invites (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references app.families(id) on delete cascade,
  code       text not null unique,
  -- 家长码与孩子码分开签发：孩子拿到的码永远换不出家长身份。
  role       text not null check (role in ('parent', 'child')),
  -- 非空时表示这个码是"认领某个已存在成员"，而不是"新建成员"
  member_id  uuid references app.members(id) on delete cascade,
  created_by uuid references app.members(id),
  max_uses   int not null default 0 check (max_uses >= 0),  -- 0 = 不限
  used_count int not null default 0 check (used_count >= 0),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index invites_family_idx on app.invites (family_id);

-- 家长 PIN 验证通过后签发的短期令牌。所有"家长专属"函数都要求带上它。
-- 不放进 JWT claims：云端 JWT 由服务端签发，前端塞不进自定义字段。
create table app.parent_sessions (
  token      text primary key,
  member_id  uuid not null references app.members(id) on delete cascade,
  issued_at  timestamptz not null default now(),
  expires_at timestamptz not null
);
create index parent_sessions_member_idx on app.parent_sessions (member_id);

create table app.pin_attempts (
  id           bigserial primary key,
  member_id    uuid not null references app.members(id) on delete cascade,
  success      boolean not null,
  attempted_at timestamptz not null default now()
);
create index pin_attempts_member_idx on app.pin_attempts (member_id, attempted_at desc);
