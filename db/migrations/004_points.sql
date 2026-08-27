-- =============================================================================
-- 004_points.sql —— 积分流水账（不可变）
-- =============================================================================
-- 只 INSERT，永不 UPDATE / DELETE。
-- 撤销 = 追加一条 entry_kind='reversal' 的反向记账，原记录原样保留。
-- 余额真值 = sum(delta)；members.points_balance 只是同事务行锁下维护的缓存。
-- =============================================================================

create table app.point_ledger (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references app.families(id) on delete cascade,
  member_id     uuid not null references app.members(id) on delete cascade,

  delta         int not null,
  balance_after int,

  entry_kind    text not null default 'primary' check (entry_kind in ('primary', 'reversal')),
  -- signin = 主动签到；streak = 连续天数里程碑（签到 / 活跃 / 满星）
  -- 枚举扩过一次，见 010_signin.sql 里同名约束的 drop/add ——
  -- 已经建过库的设备不会重跑本文件，所以那边必须再补一遍。
  source_type   text not null check (source_type in
                  ('checkin', 'completion', 'milestone', 'manual', 'redemption', 'badge', 'reversal',
                   'signin', 'streak')),
  source_id     uuid,
  -- 同一来源可能要发多笔（同一次完成同时触发多个里程碑），用 seq 区分
  source_seq    int not null default 0,

  reverses_id   uuid references app.point_ledger(id),

  reason        text,
  -- 触发日上限时记录"原本应该发多少"，方便家长看见"今天被截了"
  capped_from   int,

  -- 业务归属日（任务发生在哪天）
  occurrence_date date,
  -- 记账日（按家庭时区 + 日切算出来的"今天"）。日上限按这个字段聚合，
  -- 不用 created_at::date —— 那是 UTC，会在每天早上 8 点前把两天算成一天。
  award_date    date not null,

  created_by    uuid references app.members(id),
  created_at    timestamptz not null default now()
);

-- ---- 幂等靠数据库约束，不靠应用代码记得去查一遍 ----------------------------
-- 同一个来源只能发一次
create unique index uq_ledger_source
  on app.point_ledger (source_type, source_id, source_seq)
  where entry_kind = 'primary' and source_id is not null;
-- 一笔只能被撤销一次（验收标准第 9 条：再撤一次必须报错）
create unique index uq_ledger_reverses
  on app.point_ledger (reverses_id)
  where reverses_id is not null;

create index ledger_member_time_idx on app.point_ledger (member_id, created_at desc);
create index ledger_daily_cap_idx   on app.point_ledger (member_id, award_date) where delta > 0;
create index ledger_family_idx      on app.point_ledger (family_id, created_at desc);

-- 流水账不可变：从数据库层面拦住"手滑写个 UPDATE 改余额"。
create or replace function app.tg_ledger_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'POINT_LEDGER_IMMUTABLE: 流水账只允许 INSERT，撤销请追加 reversal 记录';
end $$;

create trigger ledger_no_update before update on app.point_ledger
  for each row execute function app.tg_ledger_immutable();
create trigger ledger_no_delete before delete on app.point_ledger
  for each row execute function app.tg_ledger_immutable();

-- 待审核奖励（严格档用；宽松档下这张表基本是空的，M3 才接 UI）
create table app.pending_awards (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app.families(id) on delete cascade,
  member_id    uuid not null references app.members(id) on delete cascade,
  source_type  text not null,
  source_id    uuid,
  source_seq   int not null default 0,
  points       int not null,
  reason       text,
  status       text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected')),
  decided_by   uuid references app.members(id),
  decided_at   timestamptz,
  created_at   timestamptz not null default now(),
  constraint uq_pending_source unique (source_type, source_id, source_seq)
);
