import{W as c}from"./pglite-QbH7FaPb.js";import{B as m}from"./index-DV6oOlAk.js";const u=`-- =============================================================================
-- 000_shim.sql  ——  仅本地（PGlite）执行，永远不要上传到 CloudBase / Supabase
-- =============================================================================
-- 云端已经预置好这些东西：
--   * anon / authenticated / service_role 三个角色
--   * auth schema 与 auth.uid() / auth.role() / auth.jwt()
-- 本地 PGlite 是一个裸 Postgres，必须自己补出来，否则：
--   1) 迁移文件里的 GRANT ... TO authenticated 会直接报 role 不存在
--   2) 没有 auth.uid()，RLS 策略无从判断"我是谁"
--
-- 所有本地与云端的差异都必须收敛在这一个文件里。任何时候你想在
-- db/migrations/*.sql 里写 "if local then ..."，先回来看这一行。
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

-- 让当前超级用户可以 SET ROLE 过去
do $$
begin
  execute format('grant anon, authenticated, service_role to %I', current_user);
exception when others then
  null; -- 已经授予过
end $$;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- PostgREST / CloudBase 的约定：请求的 JWT payload 放在 request.jwt.claims 里。
-- 本地由 pglite.adapter.ts 在每次切换成员时 set_config 写入。
create or replace function auth.jwt() returns jsonb
  language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  )
$$;

create or replace function auth.uid() returns uuid
  language sql stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
  language sql stable
as $$
  select coalesce(nullif(auth.jwt() ->> 'role', ''), 'anon')
$$;

grant execute on function auth.jwt(), auth.uid(), auth.role()
  to anon, authenticated, service_role;
`,f=`-- =============================================================================
-- 000_init.sql —— schema 与通用工具
-- 本地(PGlite)与云端(CloudBase PG)执行同一份文件，不允许出现任何环境分支。
-- =============================================================================

create schema if not exists app;

-- 不引 pgcrypto：gen_random_uuid() 从 PG13 起已进内核，PIN 哈希用内核的
-- sha256(bytea)。少一个扩展依赖 = 少一个上云时可能没开的东西。
comment on schema app is 'FamilyQuest 业务 schema';

-- ---------------------------------------------------------------------------
-- 随机短码：家庭邀请码用。去掉 0/O/1/I/l 这些肉眼易混的字符。
-- ---------------------------------------------------------------------------
create or replace function app.gen_code(p_len int default 6)
returns text
language plpgsql volatile
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  out_text text := '';
  i int;
begin
  for i in 1..p_len loop
    out_text := out_text || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return out_text;
end $$;

-- ---------------------------------------------------------------------------
-- PIN 哈希（sha256(pin || salt)，salt 每人一份）
-- 家庭 4 位 PIN 的威胁模型是"弟弟偷看"，不是"离线爆破"，sha256 足够；
-- 真正的闸门是 pin_attempts 的失败次数限制。
-- ---------------------------------------------------------------------------
create or replace function app.hash_pin(p_pin text, p_salt text)
returns text
language sql immutable
as $$
  select encode(sha256(convert_to(p_salt || ':' || p_pin, 'UTF8')), 'hex')
$$;

create or replace function app.gen_salt_text()
returns text
language sql volatile
as $$
  select encode(sha256(convert_to(random()::text || clock_timestamp()::text, 'UTF8')), 'hex')
$$;
`,b=`-- =============================================================================
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
`,h=`-- =============================================================================
-- 002_tasks.sql —— 任务定义 / 暂停区间 / 阶段奖励
-- =============================================================================
-- 这里存的是"定义"，不是"某天要做的那一件事"。日历上的格子由
-- app.expand_task() 虚拟展开，只有真发生了行为才会落到 task_occurrences。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- recurrence 的形状校验。写成 CHECK 约束，脏数据在 INSERT 那一刻就被挡住，
-- 而不是等到半年后展开引擎莫名其妙少几天。
--
--   once    {"freq":"once","date":"2026-08-12"}
--   daily   {"freq":"daily"}
--   weekly  {"freq":"weekly","byweekday":[1,2,3,4,5]}        1=周一 … 7=周日 (ISO)
--   monthly {"freq":"monthly","bymonthday":[1,15],"month_overflow":"skip"}
--
-- month_overflow 处理"每月 31 号"在 2 月不存在的情况：
--   skip     —— 该月不出现
--   last_day —— 顺延到当月最后一天
-- 必须显式建模。不建模的结果不是"没这个问题"，是"行为不可预测"。
-- ---------------------------------------------------------------------------
create or replace function app.recurrence_is_valid(r jsonb)
returns boolean
language sql immutable
as $$
  -- coalesce 不能省：缺字段时 r->'x' 是 SQL NULL，整个表达式会算成 NULL，
  -- 而 CHECK 约束遇到 NULL 是"放行"的 —— 校验就白写了。
  select coalesce(case
    when r is null or jsonb_typeof(r) <> 'object' then false
    else case r ->> 'freq'
      when 'once' then
        (r ? 'date') and (r ->> 'date') ~ '^\\d{4}-\\d{2}-\\d{2}$'
      when 'daily' then
        true
      when 'weekly' then
        jsonb_typeof(r -> 'byweekday') = 'array'
        and jsonb_array_length(r -> 'byweekday') between 1 and 7
        and not exists (
          select 1 from jsonb_array_elements(r -> 'byweekday') e
          where jsonb_typeof(e) <> 'number' or (e #>> '{}')::int not between 1 and 7
        )
      when 'monthly' then
        jsonb_typeof(r -> 'bymonthday') = 'array'
        and jsonb_array_length(r -> 'bymonthday') between 1 and 31
        and not exists (
          select 1 from jsonb_array_elements(r -> 'bymonthday') e
          where jsonb_typeof(e) <> 'number' or (e #>> '{}')::int not between 1 and 31
        )
        and coalesce(r ->> 'month_overflow', 'skip') in ('skip', 'last_day')
      else false
    end
  end, false)
$$;

create table app.tasks (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references app.families(id) on delete cascade,
  assignee_id   uuid not null references app.members(id) on delete cascade,
  created_by    uuid not null references app.members(id),

  title         text not null check (length(btrim(title)) between 1 and 60),
  notes         text check (notes is null or length(notes) <= 500),
  icon_emoji    text not null default '⭐',
  color         text not null default 'sky'
                  check (color in ('sky', 'violet', 'emerald', 'amber', 'rose', 'slate')),

  -- 排期 ---------------------------------------------------------------------
  schedule_kind text not null check (schedule_kind in ('once', 'recurring')),
  recurrence    jsonb not null check (app.recurrence_is_valid(recurrence)),
  starts_on     date not null,
  ends_on       date,               -- RRULE 的 UNTIL（含当天）
  max_occurrences int check (max_occurrences is null or max_occurrences > 0), -- RRULE 的 COUNT

  -- 墙上时间，不是时刻。"每天 18:00 练琴"存 timestamptz 换个时区就漂成 17:00。
  window_start_time time,
  window_end_time   time,
  due_time          time,
  -- deadline 型：只在截止日显示在日历上，另在「今天」页顶部长期条里倒计时
  is_deadline_style boolean not null default false,

  -- 奖励 ---------------------------------------------------------------------
  checkin_points      int not null default 0 check (checkin_points between 0 and 1000),
  checkin_daily_limit int not null default 1 check (checkin_daily_limit between 1 and 20),
  completion_points   int not null default 0 check (completion_points between 0 and 1000),
  -- 宽松档默认：两种分都自动到账，家长事后抽查 + 可撤销
  checkin_auto_approve boolean not null default true,
  requires_approval    boolean not null default false,

  version     int not null default 1,
  archived_at timestamptz,          -- 软删。历史实例仍然留在日历上（灰色）
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint tasks_window_order check (
    window_start_time is null or window_end_time is null
    or window_start_time < window_end_time
  ),
  constraint tasks_date_range check (ends_on is null or ends_on >= starts_on),
  constraint tasks_once_shape check (
    schedule_kind <> 'once' or (recurrence ->> 'freq') = 'once'
  ),
  constraint tasks_recurring_shape check (
    schedule_kind <> 'recurring' or (recurrence ->> 'freq') in ('daily', 'weekly', 'monthly')
  )
);
create index tasks_family_idx    on app.tasks (family_id) where archived_at is null;
create index tasks_assignee_idx  on app.tasks (assignee_id) where archived_at is null;

-- 改任务定义时自动 +1 版本号并刷新 updated_at。
-- 已落库的 occurrence 保存的是旧版本快照，历史因此不会被改动。
create or replace function app.tg_tasks_bump_version()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  if new.version = old.version then
    new.version := old.version + 1;
  end if;
  return new;
end $$;

create trigger tasks_bump_version
  before update on app.tasks
  for each row execute function app.tg_tasks_bump_version();

-- 暂停区间：寒假停"写作业"，不用删任务也不用改重复规则。
create table app.task_pause_periods (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid not null references app.tasks(id) on delete cascade,
  starts_on  date not null,
  ends_on    date not null,
  reason     text,
  created_at timestamptz not null default now(),
  constraint pause_range check (ends_on >= starts_on)
);
create index pause_task_idx on app.task_pause_periods (task_id);

-- 阶段奖励（里程碑）。一个任务可挂多条。
create table app.task_milestones (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references app.tasks(id) on delete cascade,
  rule_kind   text not null check (rule_kind in
                ('streak_days', 'total_count', 'completion_rate', 'checkin_total')),
  -- streak_days/total_count/checkin_total 用整数；completion_rate 用 0~1 小数
  threshold   numeric not null check (threshold > 0),
  window_kind text not null default 'lifetime' check (window_kind in ('lifetime', 'month')),
  points      int not null default 0 check (points >= 0),
  badge_id    uuid,                        -- 008 之后再加外键，避免建表顺序耦合
  label       text,
  -- true = 每达成一个 threshold 的整数倍都发（连续 7 天、14 天、21 天…）
  repeatable  boolean not null default false,
  created_at  timestamptz not null default now()
);
create index milestone_task_idx on app.task_milestones (task_id);
`,y=`-- =============================================================================
-- 003_occurrences.sql —— 任务实例 / 打卡
-- =============================================================================
-- 只记录"真发生过的行为"。没打卡没完成的日子不落库，日历上那一格是虚拟的。
-- UNIQUE (task_id, occurrence_date) 是跨设备一致性的基石：
-- 任何设备算出的同一个虚拟实例，身份都由这对值唯一确定。
-- =============================================================================

create table app.task_occurrences (
  id              uuid primary key default gen_random_uuid(),
  task_id         uuid not null references app.tasks(id) on delete cascade,
  -- 冗余存一份，让日历范围查询不必 join tasks
  family_id       uuid not null references app.families(id) on delete cascade,
  assignee_id     uuid not null references app.members(id) on delete cascade,

  -- 家庭本地日历日，不是时刻。JS 侧一律以 'YYYY-MM-DD' 字符串传递。
  occurrence_date date not null,

  status          text not null default 'pending'
                    check (status in ('pending', 'completed', 'skipped', 'missed')),
  completed_at    timestamptz,
  completed_by    uuid references app.members(id),
  note            text check (note is null or length(note) <= 300),

  -- ---- 快照：落库那一刻任务定义长什么样 ----------------------------------
  -- 之后家长把"每日阅读"从 5 分改成 10 分，历史记录仍然显示 5 分。
  snap_title             text not null,
  snap_icon_emoji        text not null,
  snap_color             text not null,
  snap_checkin_points    int  not null,
  snap_completion_points int  not null,
  snap_window_start_time time,
  snap_window_end_time   time,
  snap_due_time          time,
  task_version           int  not null,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint uq_occurrence unique (task_id, occurrence_date)
);
create index occ_family_date_idx   on app.task_occurrences (family_id, occurrence_date);
create index occ_assignee_date_idx on app.task_occurrences (assignee_id, occurrence_date);

create table app.checkins (
  id             uuid primary key default gen_random_uuid(),
  occurrence_id  uuid not null references app.task_occurrences(id) on delete cascade,
  member_id      uuid not null references app.members(id) on delete cascade,
  -- 同一天第几次打卡。配合 UNIQUE 做幂等：重放请求撞唯一键而不是重复发分。
  seq            int not null check (seq > 0),
  points_awarded int not null default 0,
  note           text check (note is null or length(note) <= 300),
  created_at     timestamptz not null default now(),
  constraint uq_checkin_seq unique (occurrence_id, seq)
);
create index checkin_member_idx on app.checkins (member_id, created_at desc);
`,g=`-- =============================================================================
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
`,v=`-- =============================================================================
-- 005_badges.sql —— 勋章
-- =============================================================================
-- family_id 为 NULL 表示系统内置勋章（009_seed 播种），所有家庭共享。
-- 家庭自定义勋章挂自己的 family_id。
-- =============================================================================

create table app.badges (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid references app.families(id) on delete cascade,
  code        text not null,
  name        text not null,
  description text,
  emoji       text not null default '🏅',
  tier        text not null default 'bronze'
                check (tier in ('bronze', 'silver', 'gold', 'special')),
  -- 自动解锁规则，形如 {"kind":"total_completions","threshold":10}
  -- kind: total_completions | total_points | streak_days | first_task
  rule        jsonb,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- 系统勋章（family_id is null）与家庭勋章各自 code 唯一
create unique index uq_badge_code
  on app.badges (coalesce(family_id, '00000000-0000-0000-0000-000000000000'::uuid), code);
create index badges_family_idx on app.badges (family_id);

create table app.member_badges (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references app.members(id) on delete cascade,
  badge_id    uuid not null references app.badges(id) on delete cascade,
  awarded_at  timestamptz not null default now(),
  source_type text,
  source_id   uuid,
  constraint uq_member_badge unique (member_id, badge_id)
);
create index member_badges_member_idx on app.member_badges (member_id);

-- 002 里 task_milestones.badge_id 先留空，这里补上外键
alter table app.task_milestones
  add constraint task_milestones_badge_fk
  foreign key (badge_id) references app.badges(id) on delete set null;
`,k=`-- =============================================================================
-- 006_shop.sql —— 兑换商城
-- =============================================================================
-- 两种定价模式共存一张表：
--   fixed —— 固定商品，price_points 分换 1 件（"看一集动画 = 30 分"）
--   rate  —— 按量兑换，rate_points 分换 1 个 unit_label（"100 分 = 1 元"）
--
-- "默认只有现金"是通过建家庭时播种一条普通记录实现的，
-- 代码里没有任何 kind === 'cash' 的特判。第一个品类就走通用模型，
-- 可扩展性才是真的；给通用模型开后门只会在加第二个品类时还债。
-- =============================================================================

create table app.reward_items (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app.families(id) on delete cascade,
  name         text not null check (length(btrim(name)) between 1 and 40),
  emoji        text not null default '🎁',
  description  text,

  pricing_mode text not null check (pricing_mode in ('fixed', 'rate')),
  price_points int  check (price_points is null or price_points > 0),
  rate_points  int  check (rate_points is null or rate_points > 0),
  unit_label   text,
  min_quantity numeric not null default 1 check (min_quantity > 0),
  step_quantity numeric not null default 1 check (step_quantity > 0),

  stock        int,                       -- null = 不限量
  requires_approval boolean not null default true,
  active       boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),

  constraint pricing_shape check (
    (pricing_mode = 'fixed' and price_points is not null)
    or (pricing_mode = 'rate' and rate_points is not null and unit_label is not null)
  )
);
create index reward_items_family_idx on app.reward_items (family_id) where active;

create table app.redemptions (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app.families(id) on delete cascade,
  member_id    uuid not null references app.members(id) on delete cascade,
  item_id      uuid not null references app.reward_items(id),
  quantity     numeric not null default 1 check (quantity > 0),
  points_cost  int not null check (points_cost >= 0),
  -- 快照商品名，商品改名/下架后历史记录仍可读
  snap_name    text not null,
  snap_emoji   text not null,
  status       text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected', 'delivered', 'cancelled')),
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   uuid references app.members(id),
  note         text
);
create index redemptions_member_idx on app.redemptions (member_id, requested_at desc);
create index redemptions_family_pending_idx on app.redemptions (family_id) where status = 'pending';
`,w=`-- =============================================================================
-- 007_functions.sql —— 展开引擎 / 记账核心 / 业务入口
-- =============================================================================
-- 约定：所有会写数据的函数一律 SECURITY DEFINER。
-- 原因见 008_rls.sql —— 前端对 point_ledger / checkins / task_occurrences
-- 这些表只有 SELECT 权限，写入的唯一通道就是这里的函数。
-- =============================================================================


-- ###########################################################################
-- 一、身份
-- ###########################################################################

-- 这三个会被 RLS 策略调用。必须是 SECURITY DEFINER：
-- 否则策略里查 members 又会触发 members 的策略，无限递归。
create or replace function app.current_member_id()
returns uuid language sql stable security definer set search_path = app, public as $$
  select m.id from app.members m
   where m.user_id = auth.uid() and m.archived_at is null
   limit 1
$$;

create or replace function app.current_family_id()
returns uuid language sql stable security definer set search_path = app, public as $$
  select m.family_id from app.members m
   where m.user_id = auth.uid() and m.archived_at is null
   limit 1
$$;

create or replace function app.is_parent()
returns boolean language sql stable security definer set search_path = app, public as $$
  select coalesce((select m.role = 'parent' from app.members m
                    where m.user_id = auth.uid() and m.archived_at is null limit 1), false)
$$;

-- 孩子自建任务的单项积分上限（RLS 的 WITH CHECK 用）
create or replace function app.child_points_cap()
returns int language sql stable security definer set search_path = app, public as $$
  select case f.child_task_points_policy
           when 'free'   then 1000000
           when 'zero'   then 0
           else f.child_task_points_cap
         end
    from app.families f
   where f.id = app.current_family_id()
$$;

create or replace function app.require_member()
returns app.members language plpgsql stable security definer set search_path = app, public as $$
declare m app.members%rowtype;
begin
  select * into m from app.members
   where user_id = auth.uid() and archived_at is null;
  if not found then
    raise exception 'NOT_A_MEMBER: 当前身份不属于任何家庭';
  end if;
  return m;
end $$;

-- 家长专属操作的守卫。PIN 验证通过后拿到的 token 在这里兑现。
create or replace function app.require_parent(p_token text)
returns app.members language plpgsql stable security definer set search_path = app, public as $$
declare m app.members%rowtype; s app.parent_sessions%rowtype;
begin
  select * into s from app.parent_sessions where token = p_token;
  if not found then raise exception 'PARENT_TOKEN_INVALID: 需要家长验证'; end if;
  if s.expires_at < now() then raise exception 'PARENT_TOKEN_EXPIRED: 家长验证已过期，请重新输入 PIN'; end if;

  select * into m from app.members where id = s.member_id and archived_at is null;
  if not found or m.role <> 'parent' then raise exception 'PARENT_TOKEN_INVALID'; end if;
  return m;
end $$;


-- ###########################################################################
-- 二、时间：全系统"今天"只有这一个来源
-- ###########################################################################
-- 前端禁止裸 new Date() 算业务日期。孩子把设备时间改到明天来刷分，
-- 是一定会发生的事。
create or replace function app.family_today(p_family_id uuid)
returns date language sql stable security definer set search_path = app, public as $$
  select ((now() at time zone f.timezone) - make_interval(hours => f.day_cutoff_hour))::date
    from app.families f where f.id = p_family_id
$$;

create or replace function app.today()
returns date language sql stable security definer set search_path = app, public as $$
  select app.family_today(app.current_family_id())
$$;


-- ###########################################################################
-- 三、展开引擎
-- ###########################################################################

-- 只做"频率匹配"，不管有效期 / 暂停 / count。
-- 抽出来是为了让 expand_task 里算 count 截断点时能复用同一套匹配逻辑，
-- 而不是把规则写两遍——写两遍必然会漂。
create or replace function app._match_dates(r jsonb, p_from date, p_to date)
returns setof date language sql immutable as $$
  -- 用整数偏移生成日期，不经过 timestamp —— 少一层时区转换就少一类"差一天"的 bug
  select x.d
    from generate_series(0, p_to - p_from) as g(i)
   cross join lateral (select (p_from + g.i)::date) as x(d)
   where case r ->> 'freq'
     when 'once'  then d = (r ->> 'date')::date
     when 'daily' then true
     when 'weekly' then (r -> 'byweekday') @> to_jsonb(extract(isodow from d)::int)
     when 'monthly' then (
       (r -> 'bymonthday') @> to_jsonb(extract(day from d)::int)
       -- month_overflow = last_day：31 号在 2 月不存在时顺延到月末
       or (
         coalesce(r ->> 'month_overflow', 'skip') = 'last_day'
         and d = (date_trunc('month', d) + interval '1 month' - interval '1 day')::date
         and exists (
           select 1 from jsonb_array_elements(r -> 'bymonthday') e
            where (e #>> '{}')::int
                  > extract(day from (date_trunc('month', d) + interval '1 month' - interval '1 day'))::int
         )
       )
     )
     else false
   end
$$;

-- 有效期裁剪 → 频率匹配 → 排除暂停区间 → 应用 until / count
create or replace function app.expand_task(p_task_id uuid, p_from date, p_to date)
returns setof date language plpgsql stable security definer set search_path = app, public as $$
declare
  t      app.tasks%rowtype;
  v_from date;
  v_to   date;
  v_probe date;
  v_cut  date;
begin
  select * into t from app.tasks where id = p_task_id;
  if not found then return; end if;

  -- 跨家庭窥探防护（测试脚本以 superuser 直连、auth.uid() 为空时放行）
  if auth.uid() is not null and t.family_id <> app.current_family_id() then
    return;
  end if;

  v_from := greatest(p_from, t.starts_on);
  v_to   := p_to;
  if t.ends_on is not null then v_to := least(v_to, t.ends_on); end if;
  if v_from > v_to then return; end if;

  -- COUNT 截断：先算出"第 N 次落在哪天"，再把上界收到那天。
  -- 探测上界按频率给一个必然够用的富余量，避免无界扫描。
  if t.max_occurrences is not null then
    v_probe := case t.recurrence ->> 'freq'
      when 'once'    then t.starts_on
      when 'daily'   then t.starts_on + (t.max_occurrences + 1)
      when 'weekly'  then t.starts_on + ((t.max_occurrences + 1) * 7)
      when 'monthly' then (t.starts_on + make_interval(months => t.max_occurrences + 2))::date
      else t.starts_on
    end;
    if t.ends_on is not null then v_probe := least(v_probe, t.ends_on); end if;

    select max(s.d) into v_cut from (
      select m.d from app._match_dates(t.recurrence, t.starts_on, v_probe) as m(d)
       where not exists (
         select 1 from app.task_pause_periods p
          where p.task_id = t.id and m.d between p.starts_on and p.ends_on)
       order by m.d
       limit t.max_occurrences
    ) s;

    if v_cut is null then return; end if;
    v_to := least(v_to, v_cut);
    if v_from > v_to then return; end if;
  end if;

  return query
    select m.d
      from app._match_dates(t.recurrence, v_from, v_to) as m(d)
     where not exists (
       select 1 from app.task_pause_periods p
        where p.task_id = t.id and m.d between p.starts_on and p.ends_on)
     order by m.d;
end $$;


-- 前端画日历只调这一个函数。
-- 虚拟展开 + 已落库实例合并（落库的用快照字段覆盖）+ 孤儿实例补入。
-- "孤儿实例" = 已落库但当前规则算不出来的日子，比如任务归档了、
-- 或者家长把"每周一三五"改成了"每周二四"。它们必须继续显示，否则
-- 孩子会发现自己前天挣的分对应的任务凭空消失了。
create or replace function app.get_calendar(
  p_from date, p_to date, p_member_id uuid default null
)
returns table (
  task_id            uuid,
  occurrence_id      uuid,
  occurrence_date    date,
  assignee_id        uuid,
  title              text,
  icon_emoji         text,
  color              text,
  status             text,
  checkin_points     int,
  completion_points  int,
  checkin_count      int,
  checkin_daily_limit int,
  window_start_time  time,
  window_end_time    time,
  due_time           time,
  is_deadline_style  boolean,
  archived           boolean,
  is_virtual         boolean,
  schedule_kind      text
)
language plpgsql stable security definer set search_path = app, public as $$
declare v_family uuid;
begin
  v_family := app.current_family_id();
  if v_family is null then return; end if;

  return query
  with ft as (
    select t.* from app.tasks t
     where t.family_id = v_family
       and (p_member_id is null or t.assignee_id = p_member_id)
  ),
  virt as (
    select t.id as tid, e.d as odate
      from ft t
      cross join lateral app.expand_task(t.id, p_from, p_to) as e(d)
     where t.archived_at is null
  ),
  occ as (
    select o.* from app.task_occurrences o
     where o.task_id in (select id from ft)
       and o.occurrence_date between p_from and p_to
  ),
  keys as (
    select tid, odate from virt
    union
    select o.task_id, o.occurrence_date from occ o
  )
  select
    k.tid,
    o.id,
    k.odate,
    t.assignee_id,
    coalesce(o.snap_title, t.title),
    coalesce(o.snap_icon_emoji, t.icon_emoji),
    coalesce(o.snap_color, t.color),
    coalesce(o.status, 'pending'),
    coalesce(o.snap_checkin_points, t.checkin_points),
    coalesce(o.snap_completion_points, t.completion_points),
    coalesce((select count(*)::int from app.checkins c where c.occurrence_id = o.id), 0),
    t.checkin_daily_limit,
    coalesce(o.snap_window_start_time, t.window_start_time),
    coalesce(o.snap_window_end_time, t.window_end_time),
    coalesce(o.snap_due_time, t.due_time),
    t.is_deadline_style,
    (t.archived_at is not null),
    (o.id is null),
    t.schedule_kind
  from keys k
  join ft t on t.id = k.tid
  left join occ o on o.task_id = k.tid and o.occurrence_date = k.odate
  order by k.odate,
           coalesce(o.snap_window_start_time, t.window_start_time) nulls last,
           t.created_at;
end $$;


-- 兑换商城商品。扣分同样走流水账，不直接改余额 ——
-- 余额只是缓存，流水账才是事实来源。
-- redemptions 对 authenticated 只读，前端拼不出 INSERT，必须经这里。
create or replace function app.redeem(
  p_item_id  uuid,
  p_quantity numeric default 1,
  p_note     text   default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me     app.members%rowtype;
  item   app.reward_items%rowtype;
  v_cost int;
  v_id   uuid;
  v_bal  int;
begin
  me := app.require_member();
  if p_quantity is null or p_quantity <= 0 then raise exception 'BAD_QTY'; end if;

  select * into item from app.reward_items where id = p_item_id;
  if not found or item.family_id <> me.family_id then raise exception 'ITEM_NOT_FOUND'; end if;
  if not item.active then raise exception 'ITEM_INACTIVE: 这个商品已下架'; end if;

  -- 阶梯量校验：min/step 是家长设的规则，绕过它就等于绕过定价
  if p_quantity < item.min_quantity then
    raise exception 'BELOW_MIN_QTY: 至少要兑 % %', item.min_quantity, coalesce(item.unit_label, '个');
  end if;
  if mod((p_quantity - item.min_quantity)::numeric, item.step_quantity) <> 0 then
    raise exception 'BAD_STEP_QTY: 数量必须按 % 递增', item.step_quantity;
  end if;

  if item.stock is not null and item.stock < p_quantity then
    raise exception 'OUT_OF_STOCK: 库存不足';
  end if;

  v_cost := ceil(
    case when item.pricing_mode = 'fixed' then item.price_points * p_quantity
         else item.rate_points * p_quantity end
  )::int;

  -- 锁住成员行再读余额，防止连点两次各扣一半
  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < v_cost then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', v_cost - v_bal;
  end if;

  insert into app.redemptions (family_id, member_id, item_id, quantity, points_cost,
                               snap_name, snap_emoji, note)
  values (me.family_id, me.id, item.id, p_quantity, v_cost,
          item.name, item.emoji, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  -- 分先扣掉。家长驳回时走 revoke_ledger_entry 退回。
  perform app._post_ledger(me.id, -v_cost, 'redemption', v_id, 0,
                           '兑换 ' || item.name, null, me.id);

  if item.stock is not null then
    update app.reward_items set stock = stock - p_quantity where id = item.id;
  end if;

  return jsonb_build_object(
    'redemption_id', v_id,
    'points_spent', v_cost,
    'balance', (select points_balance from app.members where id = me.id),
    'pending', item.requires_approval,
    'message', case when item.requires_approval then '已提交，等家长确认' else '兑换成功' end);
end $$;


-- 家长处理兑换申请。驳回 = 退分（追加反向记账），不是删记录。
create or replace function app.decide_redemption(
  p_redemption_id uuid, p_decision text, p_parent_token text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; r app.redemptions%rowtype; src app.point_ledger%rowtype;
begin
  parent := app.require_parent(p_parent_token);
  if p_decision not in ('approved', 'rejected', 'delivered', 'cancelled') then
    raise exception 'BAD_DECISION';
  end if;

  select * into r from app.redemptions where id = p_redemption_id;
  if not found or r.family_id <> parent.family_id then raise exception 'REDEMPTION_NOT_FOUND'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED: 这笔已经处理过了'; end if;

  update app.redemptions
     set status = p_decision, decided_at = now(), decided_by = parent.id
   where id = r.id;

  if p_decision in ('rejected', 'cancelled') then
    select * into src from app.point_ledger
     where entry_kind = 'primary' and source_type = 'redemption'
       and source_id = r.id and source_seq = 0;
    if found then
      perform app._reverse_ledger(src.id, '兑换未通过，积分退回', parent.id);
    end if;
  end if;

  return jsonb_build_object(
    'redemption_id', r.id, 'status', p_decision,
    'balance', (select points_balance from app.members where id = r.member_id));
end $$;


-- 所有写操作的前置步骤。
-- 内含日期合法性断言 —— 这是防刷分的第一道闸：
-- 没有它，孩子可以给"每周一"的任务在周日打卡，或者给去年的任务补卡。
create or replace function app.materialize(p_task_id uuid, p_date date)
returns app.task_occurrences
language plpgsql security definer set search_path = app, public as $$
declare
  t app.tasks%rowtype;
  o app.task_occurrences%rowtype;
  v_ok boolean;
begin
  select * into t from app.tasks where id = p_task_id;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;

  select exists(select 1 from app.expand_task(p_task_id, p_date, p_date)) into v_ok;
  if not v_ok then
    -- 已经落过库的（家长强制加的实例、规则改动前的历史）允许继续操作
    if not exists (select 1 from app.task_occurrences
                    where task_id = p_task_id and occurrence_date = p_date) then
      raise exception 'DATE_NOT_IN_SCHEDULE: % 不在该任务的排期内', p_date;
    end if;
  end if;

  insert into app.task_occurrences (
    task_id, family_id, assignee_id, occurrence_date,
    snap_title, snap_icon_emoji, snap_color,
    snap_checkin_points, snap_completion_points,
    snap_window_start_time, snap_window_end_time, snap_due_time,
    task_version
  ) values (
    t.id, t.family_id, t.assignee_id, p_date,
    t.title, t.icon_emoji, t.color,
    t.checkin_points, t.completion_points,
    t.window_start_time, t.window_end_time, t.due_time,
    t.version
  )
  -- 冲突时只碰 updated_at，绝不覆盖快照字段
  on conflict (task_id, occurrence_date) do update set updated_at = now()
  returning * into o;

  return o;
end $$;


-- ###########################################################################
-- 四、记账
-- ###########################################################################

-- 唯一允许写 point_ledger 的地方。
-- 幂等 + 日上限 + 余额缓存行锁，三件事都在这里做完。
create or replace function app._post_ledger(
  p_member_id      uuid,
  p_delta          int,
  p_source_type    text,
  p_source_id      uuid,
  p_source_seq     int,
  p_reason         text,
  p_occurrence_date date,
  p_created_by     uuid
)
returns app.point_ledger
language plpgsql security definer set search_path = app, public as $$
declare
  m   app.members%rowtype;
  f   app.families%rowtype;
  e   app.point_ledger%rowtype;
  v_today date;
  v_earned_today int;
  v_delta int;
  v_capped_from int;
begin
  -- 行锁：并发打卡时余额缓存不会互相覆盖
  select * into m from app.members where id = p_member_id for update;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  select * into f from app.families where id = m.family_id;

  v_today := app.family_today(m.family_id);
  v_delta := p_delta;

  -- 每日上限：宽松档下最有效的一道闸。只管孩子、只管挣分的来源。
  if v_delta > 0
     and m.role = 'child'
     and f.child_daily_points_cap > 0
     and p_source_type in ('checkin', 'completion', 'milestone', 'badge')
  then
    select coalesce(sum(delta), 0) into v_earned_today
      from app.point_ledger
     where member_id = p_member_id and award_date = v_today and delta > 0;

    if v_earned_today + v_delta > f.child_daily_points_cap then
      v_capped_from := v_delta;
      v_delta := greatest(f.child_daily_points_cap - v_earned_today, 0);
    end if;
  end if;

  insert into app.point_ledger (
    family_id, member_id, delta, balance_after, entry_kind,
    source_type, source_id, source_seq, reason, capped_from,
    occurrence_date, award_date, created_by
  ) values (
    m.family_id, p_member_id, v_delta, m.points_balance + v_delta, 'primary',
    p_source_type, p_source_id, p_source_seq, p_reason, v_capped_from,
    p_occurrence_date, v_today, p_created_by
  )
  on conflict do nothing
  returning * into e;

  -- 撞上唯一约束 = 这笔已经发过了，直接返回原记录，不重复加分
  if e.id is null then
    select * into e from app.point_ledger
     where entry_kind = 'primary' and source_type = p_source_type
       and source_id = p_source_id and source_seq = p_source_seq;
    return e;
  end if;

  update app.members set points_balance = points_balance + v_delta where id = p_member_id;
  return e;
end $$;


-- 撤销 = 追加一条反向记账。原记录永远保留。
create or replace function app._reverse_ledger(
  p_entry_id uuid, p_reason text, p_by uuid
)
returns app.point_ledger
language plpgsql security definer set search_path = app, public as $$
declare src app.point_ledger%rowtype; e app.point_ledger%rowtype; m app.members%rowtype;
begin
  select * into src from app.point_ledger where id = p_entry_id;
  if not found then raise exception 'LEDGER_ENTRY_NOT_FOUND'; end if;
  if src.entry_kind <> 'primary' then
    raise exception 'CANNOT_REVERSE_REVERSAL: 反向记录不能再撤销';
  end if;
  if exists (select 1 from app.point_ledger where reverses_id = p_entry_id) then
    raise exception 'ALREADY_REVERSED: 这笔积分已经撤销过了';
  end if;

  select * into m from app.members where id = src.member_id for update;

  insert into app.point_ledger (
    family_id, member_id, delta, balance_after, entry_kind,
    source_type, source_id, source_seq, reverses_id, reason,
    occurrence_date, award_date, created_by
  ) values (
    src.family_id, src.member_id, -src.delta, m.points_balance - src.delta, 'reversal',
    'reversal', src.id, 0, src.id,
    coalesce(p_reason, '撤销：' || coalesce(src.reason, src.source_type)),
    src.occurrence_date, app.family_today(src.family_id), p_by
  )
  returning * into e;

  update app.members set points_balance = points_balance - src.delta where id = src.member_id;
  return e;
end $$;


create or replace function app.revoke_ledger_entry(
  p_entry_id uuid, p_parent_token text, p_reason text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; src app.point_ledger%rowtype; e app.point_ledger%rowtype;
begin
  parent := app.require_parent(p_parent_token);
  select * into src from app.point_ledger where id = p_entry_id;
  if not found or src.family_id <> parent.family_id then
    raise exception 'LEDGER_ENTRY_NOT_FOUND';
  end if;

  e := app._reverse_ledger(p_entry_id, p_reason, parent.id);
  return jsonb_build_object(
    'reversal_id', e.id,
    'delta', e.delta,
    'balance', (select points_balance from app.members where id = src.member_id)
  );
end $$;


-- 余额对账：缓存 vs 流水真值。UI 上给家长一个"重算"按钮。
create or replace function app.reconcile_balance(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare v_true int; v_cache int;
begin
  select coalesce(sum(delta), 0) into v_true from app.point_ledger where member_id = p_member_id;
  select points_balance into v_cache from app.members where id = p_member_id;
  update app.members set points_balance = v_true where id = p_member_id;
  return jsonb_build_object('before', v_cache, 'after', v_true, 'drift', v_true - v_cache);
end $$;


-- ###########################################################################
-- 五、阶段奖励（事件驱动，无定时任务）
-- ###########################################################################
-- 幂等靠"应发总数 n_should − 已发数 n_done = 补发数"。
-- 重试跑两遍，第二遍差值为 0，天然安全。
create or replace function app.evaluate_milestones(p_task_id uuid)
returns int
language plpgsql security definer set search_path = app, public as $$
declare
  t        app.tasks%rowtype;
  ms       app.task_milestones%rowtype;
  rec      record;
  v_today  date;
  v_progress numeric;
  v_should int;
  v_done   int;
  v_total  int := 0;
  v_streak int;
  v_expanded int;
  v_completed int;
  i int;
begin
  select * into t from app.tasks where id = p_task_id;
  if not found then return 0; end if;
  v_today := app.family_today(t.family_id);

  for ms in select * from app.task_milestones where task_id = p_task_id loop
    v_progress := 0;

    if ms.rule_kind = 'total_count' then
      select count(*) into v_progress from app.task_occurrences
       where task_id = p_task_id and status = 'completed';

    elsif ms.rule_kind = 'checkin_total' then
      select count(*) into v_progress
        from app.checkins c
        join app.task_occurrences o on o.id = c.occurrence_id
       where o.task_id = p_task_id;

    elsif ms.rule_kind = 'streak_days' then
      -- 从今天往回走：completed 计数，skipped 跳过但不断连，
      -- 今天还没做（pending）不算断连，其余一律断。
      v_streak := 0;
      for rec in
        select e.d,
               coalesce(o.status, 'pending') as st
          from app.expand_task(p_task_id, greatest(t.starts_on, v_today - 400), v_today) as e(d)
          left join app.task_occurrences o
                 on o.task_id = p_task_id and o.occurrence_date = e.d
         order by e.d desc
      loop
        if rec.st = 'completed' then
          v_streak := v_streak + 1;
        elsif rec.st = 'skipped' then
          continue;
        elsif rec.d = v_today then
          continue;
        else
          exit;
        end if;
      end loop;
      v_progress := v_streak;

    elsif ms.rule_kind = 'completion_rate' then
      select count(*) into v_expanded
        from app.expand_task(p_task_id,
               case when ms.window_kind = 'month' then date_trunc('month', v_today)::date
                    else t.starts_on end,
               v_today) as e(d);
      select count(*) into v_completed
        from app.task_occurrences
       where task_id = p_task_id and status = 'completed'
         and occurrence_date >= case when ms.window_kind = 'month'
                                     then date_trunc('month', v_today)::date
                                     else t.starts_on end
         and occurrence_date <= v_today;
      -- 请假的日子从分母里扣掉
      select v_expanded - count(*) into v_expanded
        from app.task_occurrences
       where task_id = p_task_id and status = 'skipped'
         and occurrence_date between
             (case when ms.window_kind = 'month' then date_trunc('month', v_today)::date
                   else t.starts_on end) and v_today;
      if v_expanded <= 0 then continue; end if;
      v_progress := v_completed::numeric / v_expanded;
    end if;

    if ms.repeatable and ms.rule_kind <> 'completion_rate' then
      v_should := floor(v_progress / ms.threshold)::int;
    else
      v_should := case when v_progress >= ms.threshold then 1 else 0 end;
    end if;

    select count(*)::int into v_done from app.point_ledger
     where entry_kind = 'primary' and source_type = 'milestone' and source_id = ms.id;

    i := v_done + 1;
    while i <= v_should loop
      perform app._post_ledger(
        t.assignee_id, ms.points, 'milestone', ms.id, i,
        coalesce(ms.label, '阶段奖励：' || t.title), v_today, null);
      v_total := v_total + 1;
      i := i + 1;
    end loop;

    if v_should > 0 and ms.badge_id is not null then
      insert into app.member_badges (member_id, badge_id, source_type, source_id)
      values (t.assignee_id, ms.badge_id, 'milestone', ms.id)
      on conflict (member_id, badge_id) do nothing;
    end if;
  end loop;

  return v_total;
end $$;


-- ###########################################################################
-- 六、业务入口：打卡 / 完成 / 请假 / 撤销完成
-- ###########################################################################

create or replace function app.record_checkin(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  ck app.checkins%rowtype;
  e  app.point_ledger%rowtype;
  v_seq int;
  v_awarded int := 0;
  v_capped int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能给自己的任务打卡';
  end if;

  o := app.materialize(p_task_id, p_date);

  select coalesce(max(seq), 0) + 1 into v_seq from app.checkins where occurrence_id = o.id;
  if v_seq > t.checkin_daily_limit then
    raise exception 'CHECKIN_LIMIT_REACHED: 今天这个任务最多打卡 % 次', t.checkin_daily_limit;
  end if;

  insert into app.checkins (occurrence_id, member_id, seq, points_awarded, note)
  values (o.id, t.assignee_id, v_seq, 0, p_note)
  returning * into ck;

  if o.snap_checkin_points > 0 and t.checkin_auto_approve then
    e := app._post_ledger(t.assignee_id, o.snap_checkin_points, 'checkin', ck.id, 0,
                          '打卡 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
    update app.checkins set points_awarded = v_awarded where id = ck.id;
  end if;

  perform app.evaluate_milestones(p_task_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'checkin_id', ck.id,
    'seq', v_seq,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- ⚠ 本函数在 010_signin.sql 里被再次 create or replace（追加了签到/活跃/满星的
-- 联动调用），最终生效的是那一版。这里保留同样的 source_seq 修复，
-- 好让新建的库从第一天起就是对的、也让读代码的人不会以为这里还是坏的。
create or replace function app.complete_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  e  app.point_ledger%rowtype;
  v_awarded int := 0;
  v_capped int;
  v_seq int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能完成自己的任务';
  end if;

  o := app.materialize(p_task_id, p_date);

  if o.status = 'completed' then
    -- 幂等：重复点击不重复发分
    return jsonb_build_object(
      'occurrence_id', o.id, 'already', true, 'points_awarded', 0,
      'balance', (select points_balance from app.members where id = t.assignee_id));
  end if;

  update app.task_occurrences
     set status = 'completed', completed_at = now(), completed_by = me.id,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id
   returning * into o;

  -- source_seq 不能写死 0：撤销完成只追加 reversal（铁律 5），旧的 primary 还在，
  -- 再次完成时 seq=0 会撞 uq_ledger_source 被 on conflict 静默吞掉 → 分不再加。
  -- 每次真发分都取下一个序号，撤销后重做就是一条新的 primary。
  if o.snap_completion_points > 0 and not t.requires_approval then
    select coalesce(max(l.source_seq), -1) + 1 into v_seq
      from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id;

    e := app._post_ledger(t.assignee_id, o.snap_completion_points, 'completion', o.id, v_seq,
                          '完成 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
  elsif o.snap_completion_points > 0 then
    insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
    values (t.family_id, t.assignee_id, 'completion', o.id, o.snap_completion_points,
            '完成 · ' || o.snap_title)
    on conflict (source_type, source_id, source_seq) do nothing;
  end if;

  perform app.evaluate_milestones(p_task_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'already', false,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- 点错了撤回。分数一起退回去（追加反向记账，不删原始记录）。
create or replace function app.uncomplete_occurrence(p_task_id uuid, p_date date)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  src app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then raise exception 'FORBIDDEN'; end if;

  select * into o from app.task_occurrences
   where task_id = p_task_id and occurrence_date = p_date;
  if not found or o.status <> 'completed' then
    raise exception 'NOT_COMPLETED: 这条本来就不是已完成状态';
  end if;

  update app.task_occurrences
     set status = 'pending', completed_at = null, completed_by = null, updated_at = now()
   where id = o.id;

  -- 取"最后一条还没被撤销的完成记账"。完成→撤销→再完成会产生 seq 0/1/2…，
  -- 写死 seq=0 会去撤一条早就撤过的记录，等于撤不掉。
  select l.* into src from app.point_ledger l
   where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
     and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
   order by l.source_seq desc
   limit 1;
  if src.id is not null then
    perform app._reverse_ledger(src.id, '撤回完成 · ' || o.snap_title, me.id);
  end if;

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


create or replace function app.skip_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  src app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then raise exception 'FORBIDDEN'; end if;

  o := app.materialize(p_task_id, p_date);

  -- 已完成的改成请假，要把完成分退回去（同样取最后一条未撤销的）
  if o.status = 'completed' then
    select l.* into src from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
       and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
     order by l.source_seq desc
     limit 1;
    if src.id is not null then
      perform app._reverse_ledger(src.id, '改为请假 · ' || o.snap_title, me.id);
    end if;
  end if;

  update app.task_occurrences
     set status = 'skipped', completed_at = null, completed_by = null,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id;

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


-- ###########################################################################
-- 七、家庭 / 成员 / PIN
-- ###########################################################################

create or replace function app._new_invite_code()
returns text language plpgsql volatile set search_path = app, public as $$
declare v_code text;
begin
  loop
    v_code := app.gen_code(6);
    exit when not exists (select 1 from app.invites where code = v_code);
  end loop;
  return v_code;
end $$;


create or replace function app.create_family(
  p_family_name text,
  p_nickname    text,
  p_avatar      text default '🙂',
  p_pin         text default null,
  p_timezone    text default 'Asia/Shanghai'
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_uid uuid;
  f app.families%rowtype;
  m app.members%rowtype;
  v_child_code text;
  v_parent_code text;
  v_salt text;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'NO_AUTH: 缺少身份'; end if;
  if exists (select 1 from app.members where user_id = v_uid) then
    raise exception 'ALREADY_IN_FAMILY: 这个身份已经属于某个家庭了';
  end if;
  if p_pin is not null and p_pin !~ '^\\d{4}$' then
    raise exception 'BAD_PIN: PIN 必须是 4 位数字';
  end if;

  insert into app.families (name, timezone) values (btrim(p_family_name), p_timezone)
  returning * into f;

  v_salt := app.gen_salt_text();
  insert into app.members (family_id, user_id, nickname, role, avatar_emoji, pin_hash, pin_salt)
  values (f.id, v_uid, btrim(p_nickname), 'parent', coalesce(p_avatar, '🙂'),
          case when p_pin is null then null else app.hash_pin(p_pin, v_salt) end,
          case when p_pin is null then null else v_salt end)
  returning * into m;

  v_child_code  := app._new_invite_code();
  v_parent_code := app._new_invite_code();
  insert into app.invites (family_id, code, role, created_by) values
    (f.id, v_child_code,  'child',  m.id),
    (f.id, v_parent_code, 'parent', m.id);

  -- 商城默认只播这一条。它是一条普通记录，不是特例。
  insert into app.reward_items (family_id, name, emoji, pricing_mode, rate_points, unit_label,
                                min_quantity, step_quantity, requires_approval, sort_order)
  values (f.id, '现金', '💰', 'rate', 100, '元', 1, 1, true, 0);

  return jsonb_build_object(
    'family_id', f.id, 'member_id', m.id, 'user_id', v_uid,
    'child_invite_code', v_child_code, 'parent_invite_code', v_parent_code);
end $$;


-- 建任务。家长不受积分限制，孩子建的打卡分+完成分合计不能超家庭上限
-- （而且孩子只能 UPDATE 自己建的，所以"先建 5 分过审再改成 100 分"走不通）。
create or replace function app.create_task(
  p_assignee_id     uuid,
  p_title           text,
  p_icon_emoji      text   default '⭐',
  p_color           text   default 'sky',
  p_schedule_kind   text   default 'once',
  p_recurrence      jsonb  default '{"freq":"once"}'::jsonb,
  p_starts_on       date   default null,
  p_ends_on         date   default null,
  p_max_occurrences int    default null,
  p_window_start    time   default null,
  p_window_end      time   default null,
  p_due_time        time   default null,
  p_is_deadline     boolean default false,
  p_checkin_points  int    default 0,
  p_checkin_limit   int    default 1,
  p_completion_points int  default 0
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me     app.members%rowtype;
  v_fid  uuid;
  v_ass  app.members%rowtype;
  v_task app.tasks%rowtype;
  v_start date;
  v_rec  jsonb;
  v_total int := coalesce(p_checkin_points, 0) + coalesce(p_completion_points, 0);
begin
  me := app.require_member();
  v_fid := me.family_id;
  v_start := coalesce(p_starts_on, app.family_today(v_fid));

  select * into v_ass from app.members where id = p_assignee_id and family_id = v_fid;
  if not found then raise exception 'ASSIGNEE_NOT_FOUND'; end if;

  -- 单日任务的"那一天"就是 starts_on，前端没必要两处都填。
  -- 反过来，如果调用方只给了 recurrence.date，starts_on 跟着它走。
  v_rec := coalesce(p_recurrence, '{"freq":"once"}'::jsonb);
  if v_rec ->> 'freq' = 'once' then
    if v_rec ? 'date' then
      v_start := (v_rec ->> 'date')::date;
    else
      v_rec := v_rec || jsonb_build_object('date', v_start::text);
    end if;
  end if;

  if not app.recurrence_is_valid(v_rec) then
    raise exception 'BAD_RECURRENCE: 排期设置不合法';
  end if;

  if not app.is_parent() then
    if v_ass.id <> me.id then raise exception 'FORBIDDEN: 孩子只能给自己建任务'; end if;
    if v_total > app.child_points_cap() then
      raise exception 'CHILD_POINTS_OVER_CAP: 孩子建的任务积分不能超过 %', app.child_points_cap();
    end if;
  end if;

  -- 每日上限不在这里管：任务可以设 50 分，但一天挣满上限后
  -- _post_ledger 会自动截断。两处都判反而会出现"建得出来却发不了分"的错觉。

  insert into app.tasks (
    family_id, assignee_id, created_by, title, icon_emoji, color,
    schedule_kind, recurrence, starts_on, ends_on, max_occurrences,
    window_start_time, window_end_time, due_time, is_deadline_style,
    checkin_points, checkin_daily_limit, completion_points
  ) values (
    v_fid, p_assignee_id, me.id, btrim(p_title), coalesce(p_icon_emoji, '⭐'),
    coalesce(p_color, 'sky'), coalesce(p_schedule_kind, 'once'),
    v_rec, v_start, p_ends_on, p_max_occurrences,
    p_window_start, p_window_end, p_due_time, coalesce(p_is_deadline, false),
    coalesce(p_checkin_points, 0), coalesce(p_checkin_limit, 1), coalesce(p_completion_points, 0)
  ) returning * into v_task;

  return jsonb_build_object(
    'task_id', v_task.id, 'version', v_task.version,
    'starts_on', v_task.starts_on, 'created_by', v_task.created_by);
end $$;

-- 家长在自己设备上直接建孩子成员（不用孩子当场在场）。
-- 同时签发一个认领码，孩子将来在自己设备上输入即可接管这个成员。
create or replace function app.add_member(
  p_nickname text, p_avatar text, p_role text, p_parent_token text
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; m app.members%rowtype; v_code text;
begin
  parent := app.require_parent(p_parent_token);
  if p_role not in ('parent', 'child') then raise exception 'BAD_ROLE'; end if;

  insert into app.members (family_id, user_id, nickname, role, avatar_emoji)
  values (parent.family_id, gen_random_uuid(), btrim(p_nickname), p_role, coalesce(p_avatar, '🙂'))
  returning * into m;

  v_code := app._new_invite_code();
  insert into app.invites (family_id, code, role, member_id, created_by, max_uses)
  values (parent.family_id, v_code, p_role, m.id, parent.id, 1);

  return jsonb_build_object('member_id', m.id, 'user_id', m.user_id, 'claim_code', v_code);
end $$;


create or replace function app.join_family(
  p_code text, p_nickname text default null, p_avatar text default '🙂'
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_uid uuid; inv app.invites%rowtype; m app.members%rowtype;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'NO_AUTH'; end if;
  if exists (select 1 from app.members where user_id = v_uid) then
    raise exception 'ALREADY_IN_FAMILY';
  end if;

  select * into inv from app.invites where code = upper(btrim(p_code));
  if not found then raise exception 'INVITE_NOT_FOUND: 邀请码不存在'; end if;
  if inv.revoked_at is not null then raise exception 'INVITE_REVOKED: 邀请码已作废'; end if;
  if inv.expires_at is not null and inv.expires_at < now() then
    raise exception 'INVITE_EXPIRED: 邀请码已过期'; end if;
  if inv.max_uses > 0 and inv.used_count >= inv.max_uses then
    raise exception 'INVITE_USED_UP: 邀请码已用完'; end if;

  if inv.member_id is not null then
    -- 认领一个家长代建的成员
    update app.members
       set user_id = v_uid,
           nickname = coalesce(nullif(btrim(p_nickname), ''), nickname)
     where id = inv.member_id
     returning * into m;
  else
    if nullif(btrim(coalesce(p_nickname, '')), '') is null then
      raise exception 'NICKNAME_REQUIRED: 请填写昵称';
    end if;
    insert into app.members (family_id, user_id, nickname, role, avatar_emoji)
    values (inv.family_id, v_uid, btrim(p_nickname), inv.role, coalesce(p_avatar, '🙂'))
    returning * into m;
  end if;

  update app.invites set used_count = used_count + 1 where id = inv.id;

  return jsonb_build_object('family_id', m.family_id, 'member_id', m.id, 'role', m.role);
end $$;


create or replace function app.set_pin(p_pin text, p_old_pin text default null)
returns boolean
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype; v_salt text;
begin
  me := app.require_member();
  if me.role <> 'parent' then raise exception 'FORBIDDEN: 只有家长能设置 PIN'; end if;
  if p_pin !~ '^\\d{4}$' then raise exception 'BAD_PIN: PIN 必须是 4 位数字'; end if;

  if me.pin_hash is not null then
    if p_old_pin is null or app.hash_pin(p_old_pin, me.pin_salt) <> me.pin_hash then
      raise exception 'WRONG_PIN: 原 PIN 不正确';
    end if;
  end if;

  v_salt := app.gen_salt_text();
  update app.members set pin_hash = app.hash_pin(p_pin, v_salt), pin_salt = v_salt
   where id = me.id;
  return true;
end $$;


-- 连续 5 次失败锁 15 分钟。PIN 只有 4 位，真正的防线是这个计数器。
create or replace function app.verify_parent_pin(p_pin text, p_member_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype; target app.members%rowtype;
  v_fails int; v_token text;
begin
  me := app.require_member();
  if p_member_id is null then
    target := me;
  else
    select * into target from app.members where id = p_member_id and family_id = me.family_id;
    if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  end if;

  if target.role <> 'parent' then raise exception 'NOT_A_PARENT'; end if;
  if target.pin_hash is null then raise exception 'PIN_NOT_SET: 还没有设置家长 PIN'; end if;

  select count(*) into v_fails from app.pin_attempts
   where member_id = target.id and not success and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then
    raise exception 'PIN_LOCKED: 尝试次数过多，请 15 分钟后再试';
  end if;

  if app.hash_pin(p_pin, target.pin_salt) <> target.pin_hash then
    insert into app.pin_attempts (member_id, success) values (target.id, false);
    raise exception 'WRONG_PIN: PIN 不正确';
  end if;

  insert into app.pin_attempts (member_id, success) values (target.id, true);
  delete from app.parent_sessions where expires_at < now();

  v_token := encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex');
  insert into app.parent_sessions (token, member_id, expires_at)
  values (v_token, target.id, now() + interval '30 minutes');

  return jsonb_build_object('token', v_token, 'member_id', target.id,
                            'expires_at', now() + interval '30 minutes');
end $$;


-- 一次拿全启动所需数据，省掉三个来回
-- ⚠ 在 010_signin.sql 里被再次 create or replace（members 每个元素追加
-- signed_today / active_today / fullstar_today），最终生效的是那一版。
create or replace function app.bootstrap_state()
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare v_fid uuid; v_mid uuid;
begin
  v_fid := app.current_family_id();
  if v_fid is null then return jsonb_build_object('in_family', false); end if;
  v_mid := app.current_member_id();

  return jsonb_build_object(
    'in_family', true,
    'today', app.family_today(v_fid),
    'me_id', v_mid,
    'family', (select to_jsonb(f) from app.families f where f.id = v_fid),
    'members', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.role, x.created_at)
        from (select id, family_id, user_id, nickname, role, avatar_emoji, points_balance,
                     (pin_hash is not null) as has_pin, created_at
                from app.members where family_id = v_fid and archived_at is null) x
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from app.invites i where i.family_id = v_fid and i.revoked_at is null
    ), '[]'::jsonb)
  );
end $$;
`,x=`-- =============================================================================
-- 008_rls.sql —— 权限白名单 + 全表 RLS
-- =============================================================================
-- 设计原则：先把所有权限收干净，再一条条发回去。
--
-- 最关键的一条：point_ledger / checkins / task_occurrences / member_badges /
-- redemptions 对 authenticated 只有 SELECT。前端就算把 SQL 拼出花来，
-- 也插不进一条积分记录 —— 写入的唯一通道是 007 里的 SECURITY DEFINER 函数。
--
-- 宽松档（完成分自动到账）下，这是唯一真正的防线。
-- =============================================================================

revoke all on schema app from public;
grant usage on schema app to anon, authenticated, service_role;

revoke all on all tables in schema app from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;
revoke all on all functions in schema app from public, anon;

-- ---- 读：家庭范围内基本都能读，具体行由下面的 policy 卡 --------------------
grant select on
  app.families, app.members, app.invites,
  app.tasks, app.task_pause_periods, app.task_milestones,
  app.task_occurrences, app.checkins,
  app.point_ledger, app.badges, app.member_badges,
  app.reward_items, app.redemptions, app.pending_awards
to authenticated;

-- ---- 写：只开这几处，其余一律走函数 ----------------------------------------
grant insert, update, delete on app.tasks to authenticated;
grant insert, delete on app.task_pause_periods to authenticated;
grant insert, update, delete on app.task_milestones to authenticated;
grant insert, update, delete on app.reward_items to authenticated;
grant update (nickname, avatar_emoji) on app.members to authenticated;
grant update (name, timezone, day_cutoff_hour, child_task_points_policy,
              child_task_points_cap, child_daily_points_cap) on app.families to authenticated;

grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
grant all on all tables in schema app to service_role;

-- ###########################################################################
-- RLS
-- ###########################################################################
alter table app.families           enable row level security;
alter table app.members            enable row level security;
alter table app.member_devices     enable row level security;
alter table app.invites            enable row level security;
alter table app.parent_sessions    enable row level security;
alter table app.pin_attempts       enable row level security;
alter table app.tasks              enable row level security;
alter table app.task_pause_periods enable row level security;
alter table app.task_milestones    enable row level security;
alter table app.task_occurrences   enable row level security;
alter table app.checkins           enable row level security;
alter table app.point_ledger       enable row level security;
alter table app.pending_awards     enable row level security;
alter table app.badges             enable row level security;
alter table app.member_badges      enable row level security;
alter table app.reward_items       enable row level security;
alter table app.redemptions        enable row level security;

-- ---- families -------------------------------------------------------------
create policy families_select on app.families for select to authenticated
  using (id = app.current_family_id());
create policy families_update on app.families for update to authenticated
  using (id = app.current_family_id() and app.is_parent())
  with check (id = app.current_family_id() and app.is_parent());

-- ---- members --------------------------------------------------------------
create policy members_select on app.members for select to authenticated
  using (family_id = app.current_family_id());
-- 只能改自己的昵称/头像（能改哪些列由上面的列级 GRANT 卡死）
create policy members_update_self on app.members for update to authenticated
  using (id = app.current_member_id())
  with check (id = app.current_member_id());

-- ---- invites --------------------------------------------------------------
create policy invites_select on app.invites for select to authenticated
  using (family_id = app.current_family_id());

-- ---- parent_sessions / pin_attempts：前端一律看不到 ------------------------
-- （不建任何 policy = 默认拒绝所有行。函数是 SECURITY DEFINER，不受影响。）

-- ---- tasks ----------------------------------------------------------------
create policy tasks_select on app.tasks for select to authenticated
  using (family_id = app.current_family_id());

-- 家长随便建；孩子只能给自己建，且积分不能超过家庭设定的上限
create policy tasks_insert on app.tasks for insert to authenticated
  with check (
    family_id = app.current_family_id()
    and created_by = app.current_member_id()
    and (
      app.is_parent()
      or (
        assignee_id = app.current_member_id()
        and checkin_points + completion_points <= app.child_points_cap()
      )
    )
  );

-- 孩子不能 UPDATE 任何任务，包括自己建的。
-- 否则"先建一个 5 分的过审，再改成 100 分"就成立了。
create policy tasks_update on app.tasks for update to authenticated
  using (family_id = app.current_family_id() and app.is_parent())
  with check (family_id = app.current_family_id() and app.is_parent());

create policy tasks_delete on app.tasks for delete to authenticated
  using (family_id = app.current_family_id() and app.is_parent());

-- ---- 任务的附属表：跟随任务，且只有家长能写 --------------------------------
create policy pause_select on app.task_pause_periods for select to authenticated
  using (exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()));
create policy pause_write on app.task_pause_periods for insert to authenticated
  with check (app.is_parent() and exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()));
create policy pause_delete on app.task_pause_periods for delete to authenticated
  using (app.is_parent() and exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()));

create policy milestone_select on app.task_milestones for select to authenticated
  using (exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()));
create policy milestone_insert on app.task_milestones for insert to authenticated
  with check (app.is_parent() and exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()));
create policy milestone_update on app.task_milestones for update to authenticated
  using (app.is_parent() and exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()))
  with check (app.is_parent());
create policy milestone_delete on app.task_milestones for delete to authenticated
  using (app.is_parent() and exists (select 1 from app.tasks t
                  where t.id = task_id and t.family_id = app.current_family_id()));

-- ---- 只读表（写入全部走函数）----------------------------------------------
create policy occ_select on app.task_occurrences for select to authenticated
  using (family_id = app.current_family_id());

create policy checkin_select on app.checkins for select to authenticated
  using (exists (select 1 from app.task_occurrences o
                  where o.id = occurrence_id and o.family_id = app.current_family_id()));

create policy ledger_select on app.point_ledger for select to authenticated
  using (family_id = app.current_family_id());

create policy pending_select on app.pending_awards for select to authenticated
  using (family_id = app.current_family_id());

create policy member_badges_select on app.member_badges for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

create policy redemptions_select on app.redemptions for select to authenticated
  using (family_id = app.current_family_id());

-- ---- badges：系统勋章全员可见 ----------------------------------------------
create policy badges_select on app.badges for select to authenticated
  using (family_id is null or family_id = app.current_family_id());

-- ---- 商城：家长维护品类 ----------------------------------------------------
create policy shop_select on app.reward_items for select to authenticated
  using (family_id = app.current_family_id());
create policy shop_insert on app.reward_items for insert to authenticated
  with check (app.is_parent() and family_id = app.current_family_id());
create policy shop_update on app.reward_items for update to authenticated
  using (app.is_parent() and family_id = app.current_family_id())
  with check (app.is_parent() and family_id = app.current_family_id());
create policy shop_delete on app.reward_items for delete to authenticated
  using (app.is_parent() and family_id = app.current_family_id());

-- ---- member_devices --------------------------------------------------------
create policy devices_select on app.member_devices for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));
`,q=`-- =============================================================================
-- 009_seed.sql —— 系统内置勋章（family_id is null，所有家庭共享）
-- =============================================================================
insert into app.badges (family_id, code, name, description, emoji, tier, rule, sort_order) values
  (null, 'first_step',    '第一步',     '完成第一个任务',            '👟', 'bronze',
     '{"kind":"total_completions","threshold":1}',    10),
  (null, 'streak_3',      '三日连击',   '连续 3 天完成任务',          '🔥', 'bronze',
     '{"kind":"streak_days","threshold":3}',          20),
  (null, 'streak_7',      '一周不断',   '连续 7 天完成任务',          '🔥', 'silver',
     '{"kind":"streak_days","threshold":7}',          30),
  (null, 'streak_30',     '满月坚持',   '连续 30 天完成任务',         '🏔️', 'gold',
     '{"kind":"streak_days","threshold":30}',         40),
  (null, 'complete_10',   '小有成就',   '累计完成 10 个任务',         '🌱', 'bronze',
     '{"kind":"total_completions","threshold":10}',   50),
  (null, 'complete_50',   '熟能生巧',   '累计完成 50 个任务',         '🌳', 'silver',
     '{"kind":"total_completions","threshold":50}',   60),
  (null, 'complete_200',  '百炼成钢',   '累计完成 200 个任务',        '⛰️', 'gold',
     '{"kind":"total_completions","threshold":200}',  70),
  (null, 'points_500',    '小金库',     '累计获得 500 积分',          '💎', 'silver',
     '{"kind":"total_points","threshold":500}',       80),
  (null, 'points_2000',   '大富翁',     '累计获得 2000 积分',         '👑', 'gold',
     '{"kind":"total_points","threshold":2000}',      90),
  (null, 'early_bird',    '早起鸟',     '在早上 8 点前完成一个任务',   '🌅', 'special',
     '{"kind":"first_task","threshold":1}',          100)
on conflict do nothing;
`,$=`-- =============================================================================
-- 010_signin.sql —— 签到 / 活跃 / 满星 / 连续奖励 / 补签卡 / 家长手动调分
-- =============================================================================
-- 为什么新开一个文件而不是直接改 007：
--   适配器按文件名记录已应用的迁移（public.__migrations），已经建过库的设备
--   永远不会重跑 007。所以凡是"存量库也必须拿到"的函数改动，都要落在一个
--   全新的迁移文件里。007 里同名函数保留了同样的修复，新库两遍结果一致。
--
-- 三个维度，全部**按孩子个人**统计（每个 member 只看自己名下的任务）：
--   signed   主动签到（每天 +2 分）
--   active   当天名下至少完成 1 个任务
--   fullstar 当天名下所有任务都已完成或请假（没有任务的日子不算满星）
--
-- 连续天数奖励（同一档只发一次，member_streak_awards 防重）：
--   signin    3→+10   7→+30   30→+100
--   active    3→+15   7→+40   30→+150
--   fullstar  3→+20   7→+60   30→+200
-- 每满 7 天（7/14/21…）额外发一张对应的补签卡，member_card_grants 防重。
-- =============================================================================


-- ###########################################################################
-- 一、流水账来源枚举扩容
-- ###########################################################################
-- 004 里已经写成新枚举了（新库直接就是对的），这里为存量库补一遍。
-- 同名 drop/add 对新库是等价替换，重复执行无副作用。
alter table app.point_ledger drop constraint if exists point_ledger_source_type_check;
alter table app.point_ledger add constraint point_ledger_source_type_check
  check (source_type in ('checkin', 'completion', 'milestone', 'manual', 'redemption',
                         'badge', 'reversal', 'signin', 'streak'));


-- ###########################################################################
-- 二、表
-- ###########################################################################

-- 一个成员的一天。三个布尔就是三条连续链的原始事实。
-- retro_active / retro_fullstar 是"补卡盖过来的"标记：refresh_day_status 会
-- 按当天任务实况重算 active/fullstar，没有这两个粘性标记，补的活跃会被立刻刷掉。
create table if not exists app.member_day (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references app.members(id) on delete cascade,
  day           date not null,
  signed        boolean not null default false,
  active        boolean not null default false,
  fullstar      boolean not null default false,
  retro_active   boolean not null default false,
  retro_fullstar boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_member_day unique (member_id, day)
);
create index if not exists member_day_member_idx on app.member_day (member_id, day desc);

-- 补签卡库存
create table if not exists app.member_cards (
  member_id  uuid not null references app.members(id) on delete cascade,
  kind       text not null check (kind in ('retro_signin', 'retro_active', 'retro_fullstar')),
  qty        int not null default 0 check (qty >= 0),
  updated_at timestamptz not null default now(),
  constraint pk_member_cards primary key (member_id, kind)
);

-- 发卡日志。streak_at = 触发时的连续天数（7 / 14 / 21 …），防止同一档反复发卡。
create table if not exists app.member_card_grants (
  member_id  uuid not null references app.members(id) on delete cascade,
  kind       text not null,
  streak_at  int  not null,
  granted_at timestamptz not null default now(),
  constraint uq_card_grant unique (member_id, kind, streak_at)
);

-- 连续档位积分奖励的发放日志。tier ∈ (3, 7, 30)。
-- 用它防重而不是拿"当前 streak 值"防重：streak 每天都在变，档位不变。
create table if not exists app.member_streak_awards (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references app.members(id) on delete cascade,
  kind       text not null check (kind in ('signin', 'active', 'fullstar')),
  tier       int  not null check (tier in (3, 7, 30)),
  points     int  not null default 0,
  awarded_at timestamptz not null default now(),
  constraint uq_streak_award unique (member_id, kind, tier)
);


-- ###########################################################################
-- 三、权限（008 已经跑过，新表得自己把 grant / RLS 补上）
-- ###########################################################################
grant select on app.member_day, app.member_cards,
                app.member_card_grants, app.member_streak_awards to authenticated;
grant all on app.member_day, app.member_cards,
             app.member_card_grants, app.member_streak_awards to service_role;

alter table app.member_day           enable row level security;
alter table app.member_cards         enable row level security;
alter table app.member_card_grants   enable row level security;
alter table app.member_streak_awards enable row level security;

drop policy if exists member_day_select on app.member_day;
create policy member_day_select on app.member_day for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

drop policy if exists member_cards_select on app.member_cards;
create policy member_cards_select on app.member_cards for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

drop policy if exists card_grants_select on app.member_card_grants;
create policy card_grants_select on app.member_card_grants for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

drop policy if exists streak_awards_select on app.member_streak_awards;
create policy streak_awards_select on app.member_streak_awards for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));


-- ###########################################################################
-- 四、家长守卫（PIN 是可选的家长锁）
-- ###########################################################################
-- require_parent 硬要 token，可是 PIN 本来就是可选的：没设 PIN 的家庭
-- 一个 token 都拿不到，家长就永远调不了分。这里把两种情况都收进来：
--   * 给了 token   → 按 require_parent 严格校验
--   * 没给 token   → 必须是家长身份；而且**一旦设过 PIN 就必须验**
--     （不然"家长解锁后把手机递给孩子"这条路又通了）
-- 防线的层次没变：孩子无论如何都过不了这道门。
create or replace function app._parent_guard(p_token text)
returns app.members
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  if p_token is not null then
    return app.require_parent(p_token);
  end if;

  me := app.require_member();
  if me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只有家长能做这件事';
  end if;
  if me.pin_hash is not null then
    raise exception 'PARENT_TOKEN_INVALID: 需要家长验证，请先输入 PIN';
  end if;
  return me;
end $$;


-- ###########################################################################
-- 五、家长手动调分
-- ###########################################################################
-- 打赏和扣除都走这里，一样只追加流水（铁律 5）。
-- 家长只能调孩子：调自己等于自己给自己发钱，规则会立刻失去意义。
create or replace function app.adjust_member_points(
  p_parent_token text,
  p_member_id    uuid,
  p_delta        int,
  p_reason       text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  target app.members%rowtype;
  e      app.point_ledger%rowtype;
  v_bal  int;
begin
  parent := app._parent_guard(p_parent_token);

  if p_delta is null or p_delta = 0 then
    raise exception 'BAD_DELTA: 调整分值不能为 0';
  end if;
  if abs(p_delta) > 100000 then
    raise exception 'BAD_DELTA: 单次调整不能超过 100000 分';
  end if;

  select * into target from app.members
   where id = p_member_id and family_id = parent.family_id and archived_at is null;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  if target.id = parent.id then
    raise exception 'FORBIDDEN: 家长不能给自己调分';
  end if;

  select points_balance into v_bal from app.members where id = target.id for update;
  if v_bal + p_delta < 0 then
    raise exception 'NOT_ENOUGH_POINTS: 余额只有 %，最多扣 %', v_bal, v_bal;
  end if;

  e := app._post_ledger(target.id, p_delta, 'manual', null, 0,
                        coalesce(nullif(btrim(p_reason), ''),
                                 case when p_delta > 0 then '家长打赏' else '家长扣分' end),
                        null, parent.id);

  return jsonb_build_object(
    'member_id', target.id,
    'delta', coalesce(e.delta, 0),
    'entry_id', e.id,
    'balance', (select points_balance from app.members where id = target.id));
end $$;


-- ###########################################################################
-- 六、当天状态：活跃 / 满星
-- ###########################################################################
-- "当天有哪些任务"= 规则虚拟展开 ∪ 已落库实例（归档任务和改过规则的历史也要算）。
-- 只看 task_occurrences 会把"3 个任务只落库 1 个"误判成满星。
create or replace function app.refresh_day_status(p_member_id uuid, p_date date)
returns app.member_day
language plpgsql security definer set search_path = app, public as $$
declare
  md       app.member_day%rowtype;
  v_total  int := 0;
  v_done   int := 0;
  v_closed int := 0;
  v_active boolean;
  v_full   boolean;
begin
  if p_member_id is null or p_date is null then return md; end if;

  with sched as (
    select t.id as task_id
      from app.tasks t
     where t.assignee_id = p_member_id
       and t.archived_at is null
       and exists (select 1 from app.expand_task(t.id, p_date, p_date))
    union
    select o.task_id
      from app.task_occurrences o
     where o.assignee_id = p_member_id and o.occurrence_date = p_date
  ),
  st as (
    select coalesce(o.status, 'pending') as status
      from sched s
      left join app.task_occurrences o
             on o.task_id = s.task_id and o.occurrence_date = p_date
  )
  select count(*)::int,
         count(*) filter (where status = 'completed')::int,
         count(*) filter (where status in ('completed', 'skipped'))::int
    into v_total, v_done, v_closed
    from st;

  v_active := v_done > 0;
  -- 没有任务的日子不算满星，否则"什么都不安排"就成了最优策略
  v_full := v_total > 0 and v_closed = v_total;

  insert into app.member_day (member_id, day, active, fullstar)
  values (p_member_id, p_date, v_active, v_full)
  on conflict (member_id, day) do update
     set active   = excluded.active   or member_day.retro_active,
         fullstar = excluded.fullstar or member_day.retro_fullstar,
         updated_at = now()
  returning * into md;

  return md;
end $$;


-- ###########################################################################
-- 七、连续天数
-- ###########################################################################
-- 从"今天"往回逐日看。今天还没达成不算断连（一天还没过完），
-- 昨天及更早只要有一天没达成就断。最多回看 400 天。
create or replace function app.member_streak(p_member_id uuid, p_kind text)
returns int
language plpgsql stable security definer set search_path = app, public as $$
declare
  v_fid   uuid;
  v_today date;
  d       date;
  v_hit   boolean;
  n       int := 0;
begin
  if p_kind not in ('signin', 'active', 'fullstar') then
    raise exception 'BAD_STREAK_KIND: % 不是有效维度', p_kind;
  end if;

  select family_id into v_fid from app.members where id = p_member_id;
  if v_fid is null then return 0; end if;

  v_today := app.family_today(v_fid);
  d := v_today;

  loop
    select coalesce((
      select case p_kind
               when 'signin'   then md.signed
               when 'active'   then md.active
               else                 md.fullstar
             end
        from app.member_day md
       where md.member_id = p_member_id and md.day = d), false)
      into v_hit;

    if v_hit then
      n := n + 1;
    elsif d = v_today then
      null;  -- 今天还有机会，不算断
    else
      exit;
    end if;

    d := d - 1;
    exit when d < v_today - 400;
  end loop;

  return n;
end $$;


-- 连续奖励结算。幂等：档位积分靠 member_streak_awards，补签卡靠 member_card_grants。
create or replace function app.evaluate_streaks(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_fid     uuid;
  v_today   date;
  v_kind    text;
  v_streak  int;
  v_tier    int;
  v_points  int;
  v_card    text;
  v_award   app.member_streak_awards%rowtype;
  v_granted text;
  v_paid    int := 0;
  v_cards   int := 0;
  v_out     jsonb := '{}'::jsonb;
begin
  select family_id into v_fid from app.members where id = p_member_id;
  if v_fid is null then return jsonb_build_object('member_id', p_member_id, 'skipped', true); end if;
  v_today := app.family_today(v_fid);

  foreach v_kind in array array['signin', 'active', 'fullstar'] loop
    v_streak := app.member_streak(p_member_id, v_kind);
    v_out := v_out || jsonb_build_object(v_kind, v_streak);

    -- ---- 档位积分 --------------------------------------------------------
    foreach v_tier in array array[3, 7, 30] loop
      if v_streak < v_tier then continue; end if;

      v_points := case v_kind
        when 'signin'   then case v_tier when 3 then 10 when 7 then 30 else 100 end
        when 'active'   then case v_tier when 3 then 15 when 7 then 40 else 150 end
        else                 case v_tier when 3 then 20 when 7 then 60 else 200 end
      end;

      -- 手动清空：on conflict do nothing 撞上约束时不会返回行，
      -- 别让上一轮循环留下的值被当成"这次发了"
      v_award := null;
      insert into app.member_streak_awards (member_id, kind, tier, points)
      values (p_member_id, v_kind, v_tier, v_points)
      on conflict (member_id, kind, tier) do nothing
      returning * into v_award;

      if v_award.id is not null then
        perform app._post_ledger(
          p_member_id, v_points, 'streak', v_award.id, 0,
          format('连续%s天%s', v_tier,
                 case v_kind when 'signin' then '签到'
                             when 'active' then '完成任务'
                             else '满星' end),
          v_today, p_member_id);
        v_paid := v_paid + v_points;
      end if;
    end loop;

    -- ---- 每满 7 天发一张补签卡 -------------------------------------------
    if v_streak >= 7 and v_streak % 7 = 0 then
      v_card := case v_kind
        when 'signin' then 'retro_signin'
        when 'active' then 'retro_active'
        else               'retro_fullstar'
      end;

      v_granted := null;
      insert into app.member_card_grants (member_id, kind, streak_at)
      values (p_member_id, v_card, v_streak)
      on conflict (member_id, kind, streak_at) do nothing
      returning kind into v_granted;

      if v_granted is not null then
        insert into app.member_cards (member_id, kind, qty)
        values (p_member_id, v_card, 1)
        on conflict (member_id, kind) do update
           set qty = member_cards.qty + 1, updated_at = now();
        v_cards := v_cards + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'member_id', p_member_id,
    'streak', v_out,
    'points_awarded', v_paid,
    'cards_granted', v_cards);
end $$;


-- ###########################################################################
-- 八、签到
-- ###########################################################################
-- 只能签"今天"。补过去的日子必须消耗补签卡，否则连续奖励一文不值。
create or replace function app.do_signin(p_date date default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  md      app.member_day%rowtype;
  e       app.point_ledger%rowtype;
  v_today date;
  v_date  date;
  v_award int := 0;
begin
  me := app.require_member();
  v_today := app.family_today(me.family_id);
  v_date := coalesce(p_date, v_today);

  if v_date <> v_today then
    raise exception 'BAD_SIGNIN_DATE: 只能签今天（%），补以前的日子请用补签卡', v_today;
  end if;

  select * into md from app.member_day where member_id = me.id and day = v_date;
  if md.id is not null and md.signed then
    return jsonb_build_object(
      'signed', true, 'already', true, 'points_awarded', 0,
      'balance', (select points_balance from app.members where id = me.id),
      'summary', app.get_signin_summary(me.id));
  end if;

  insert into app.member_day (member_id, day, signed)
  values (me.id, v_date, true)
  on conflict (member_id, day) do update
     set signed = true, updated_at = now()
  returning * into md;

  -- source_id 用 member_day 行的 id：一个成员一天只有一行，天然幂等
  e := app._post_ledger(me.id, 2, 'signin', md.id, 0, '每日签到', v_date, me.id);
  v_award := coalesce(e.delta, 0);

  perform app.refresh_day_status(me.id, v_date);
  perform app.evaluate_streaks(me.id);
  perform app.evaluate_badges(me.id);

  return jsonb_build_object(
    'signed', true, 'already', false, 'points_awarded', v_award,
    'balance', (select points_balance from app.members where id = me.id),
    'summary', app.get_signin_summary(me.id));
end $$;


-- 补签 / 补活跃 / 补满星。消耗一张卡，把那天的对应维度点亮。
create or replace function app.use_retro_card(
  p_kind      text,
  p_date      date,
  p_member_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  target  app.members%rowtype;
  md      app.member_day%rowtype;
  v_today date;
  v_qty   int;
  v_done  boolean;
begin
  me := app.require_member();

  if p_kind not in ('retro_signin', 'retro_active', 'retro_fullstar') then
    raise exception 'BAD_CARD_KIND: % 不是有效的补签卡', p_kind;
  end if;

  if p_member_id is null or p_member_id = me.id then
    target := me;
  else
    select * into target from app.members
     where id = p_member_id and family_id = me.family_id and archived_at is null;
    if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
    if me.role <> 'parent' then raise exception 'FORBIDDEN: 只能用自己的补签卡'; end if;
  end if;

  v_today := app.family_today(target.family_id);
  if p_date is null or p_date > v_today then
    raise exception 'BAD_DATE: 不能补未来的日子';
  end if;
  if p_date < v_today - 30 then
    raise exception 'RETRO_TOO_OLD: 只能补最近 30 天内的日子';
  end if;

  select * into md from app.member_day where member_id = target.id and day = p_date;
  v_done := case p_kind
    when 'retro_signin'   then coalesce(md.signed, false)
    when 'retro_active'   then coalesce(md.active, false)
    else                       coalesce(md.fullstar, false)
  end;
  if v_done then
    raise exception 'ALREADY_MARKED: % 这天已经达成，不用补', p_date;
  end if;

  select qty into v_qty from app.member_cards
   where member_id = target.id and kind = p_kind for update;
  if v_qty is null or v_qty <= 0 then
    raise exception 'NO_RETRO_CARD: 没有可用的%',
      case p_kind when 'retro_signin' then '补签卡'
                  when 'retro_active' then '补活跃卡'
                  else '补满星卡' end;
  end if;

  update app.member_cards set qty = qty - 1, updated_at = now()
   where member_id = target.id and kind = p_kind;

  insert into app.member_day (member_id, day, signed, active, fullstar,
                              retro_active, retro_fullstar)
  values (target.id, p_date,
          p_kind = 'retro_signin',
          p_kind = 'retro_active',
          p_kind = 'retro_fullstar',
          p_kind = 'retro_active',
          p_kind = 'retro_fullstar')
  on conflict (member_id, day) do update
     set signed         = member_day.signed         or (p_kind = 'retro_signin'),
         active         = member_day.active         or (p_kind = 'retro_active'),
         fullstar       = member_day.fullstar       or (p_kind = 'retro_fullstar'),
         retro_active   = member_day.retro_active   or (p_kind = 'retro_active'),
         retro_fullstar = member_day.retro_fullstar or (p_kind = 'retro_fullstar'),
         updated_at     = now()
  returning * into md;

  perform app.refresh_day_status(target.id, p_date);
  perform app.evaluate_streaks(target.id);
  perform app.evaluate_badges(target.id);

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind,
    'date', p_date,
    'remaining', (select qty from app.member_cards
                   where member_id = target.id and kind = p_kind),
    'balance', (select points_balance from app.members where id = target.id),
    'summary', app.get_signin_summary(target.id));
end $$;


-- 前端签到卡一次拿全：今天三个维度 + 三条连续链 + 补签卡库存 + 已发档位
create or replace function app.get_signin_summary(p_member_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  target  app.members%rowtype;
  md      app.member_day%rowtype;
  v_today date;
begin
  me := app.require_member();

  if p_member_id is null or p_member_id = me.id then
    target := me;
  else
    select * into target from app.members
     where id = p_member_id and family_id = me.family_id;
    if not found then raise exception 'FORBIDDEN: 只能看本家庭成员'; end if;
  end if;

  v_today := app.family_today(target.family_id);
  select * into md from app.member_day where member_id = target.id and day = v_today;

  return jsonb_build_object(
    'member_id', target.id,
    'today', v_today,
    'signed_today',   coalesce(md.signed, false),
    'active_today',   coalesce(md.active, false),
    'fullstar_today', coalesce(md.fullstar, false),
    'streak', jsonb_build_object(
      'signin',   app.member_streak(target.id, 'signin'),
      'active',   app.member_streak(target.id, 'active'),
      'fullstar', app.member_streak(target.id, 'fullstar')),
    'totals', jsonb_build_object(
      'signin',   (select count(*)::int from app.member_day d
                    where d.member_id = target.id and d.signed),
      'active',   (select count(*)::int from app.member_day d
                    where d.member_id = target.id and d.active),
      'fullstar', (select count(*)::int from app.member_day d
                    where d.member_id = target.id and d.fullstar)),
    'retro_cards', jsonb_build_object(
      'retro_signin',   coalesce((select qty from app.member_cards
                                   where member_id = target.id and kind = 'retro_signin'), 0),
      'retro_active',   coalesce((select qty from app.member_cards
                                   where member_id = target.id and kind = 'retro_active'), 0),
      'retro_fullstar', coalesce((select qty from app.member_cards
                                   where member_id = target.id and kind = 'retro_fullstar'), 0)),
    'awarded_tiers', coalesce((
      select jsonb_agg(jsonb_build_object('kind', a.kind, 'tier', a.tier, 'points', a.points)
                       order by a.kind, a.tier)
        from app.member_streak_awards a where a.member_id = target.id), '[]'::jsonb));
end $$;


-- ###########################################################################
-- 九、业务动作接上签到系统
-- ###########################################################################
-- 这三个函数 007 里已经有一版；这里是最终版：在原有逻辑之后追加
-- refresh_day_status + evaluate_streaks + evaluate_badges，让"完成任务"
-- 自动驱动活跃 / 满星 / 连续奖励 / 勋章，全程没有定时任务。

create or replace function app.complete_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  e  app.point_ledger%rowtype;
  v_awarded int := 0;
  v_capped int;
  v_seq int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能完成自己的任务';
  end if;

  o := app.materialize(p_task_id, p_date);

  if o.status = 'completed' then
    -- 幂等：重复点击不重复发分
    return jsonb_build_object(
      'occurrence_id', o.id, 'already', true, 'points_awarded', 0,
      'balance', (select points_balance from app.members where id = t.assignee_id));
  end if;

  update app.task_occurrences
     set status = 'completed', completed_at = now(), completed_by = me.id,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id
   returning * into o;

  -- source_seq 取下一个序号，而不是写死 0。
  -- 撤销完成只追加 reversal（铁律 5），旧的 primary 还在表里；写死 0 会撞
  -- uq_ledger_source，被 _post_ledger 的 on conflict 静默吞掉 —— 于是
  -- "撤销后再点完成"永远不加分。这就是那个积分 bug 的根。
  if o.snap_completion_points > 0 and not t.requires_approval then
    select coalesce(max(l.source_seq), -1) + 1 into v_seq
      from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id;

    e := app._post_ledger(t.assignee_id, o.snap_completion_points, 'completion', o.id, v_seq,
                          '完成 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
  elsif o.snap_completion_points > 0 then
    insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
    values (t.family_id, t.assignee_id, 'completion', o.id, o.snap_completion_points,
            '完成 · ' || o.snap_title)
    on conflict (source_type, source_id, source_seq) do nothing;
  end if;

  perform app.evaluate_milestones(p_task_id);
  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'already', false,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


create or replace function app.uncomplete_occurrence(p_task_id uuid, p_date date)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  src app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then raise exception 'FORBIDDEN'; end if;

  select * into o from app.task_occurrences
   where task_id = p_task_id and occurrence_date = p_date;
  if not found or o.status <> 'completed' then
    raise exception 'NOT_COMPLETED: 这条本来就不是已完成状态';
  end if;

  update app.task_occurrences
     set status = 'pending', completed_at = null, completed_by = null, updated_at = now()
   where id = o.id;

  -- 撤最后一条还没被撤销的完成记账（完成→撤销→再完成会有 seq 0/1/2…）
  select l.* into src from app.point_ledger l
   where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
     and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
   order by l.source_seq desc
   limit 1;
  if src.id is not null then
    perform app._reverse_ledger(src.id, '撤回完成 · ' || o.snap_title, me.id);
  end if;

  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


create or replace function app.skip_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  src app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then raise exception 'FORBIDDEN'; end if;

  o := app.materialize(p_task_id, p_date);

  -- 已完成的改成请假，要把完成分退回去（取最后一条未撤销的）
  if o.status = 'completed' then
    select l.* into src from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
       and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
     order by l.source_seq desc
     limit 1;
    if src.id is not null then
      perform app._reverse_ledger(src.id, '改为请假 · ' || o.snap_title, me.id);
    end if;
  end if;

  update app.task_occurrences
     set status = 'skipped', completed_at = null, completed_by = null,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id;

  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


-- ###########################################################################
-- 十、bootstrap 带上今天的签到状态
-- ###########################################################################
-- streak / 补签卡不塞进来：那是签到卡自己的事，走 get_signin_summary 按需拉，
-- 免得每次启动都算三条连续链。
create or replace function app.bootstrap_state()
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare v_fid uuid; v_mid uuid; v_today date;
begin
  v_fid := app.current_family_id();
  if v_fid is null then return jsonb_build_object('in_family', false); end if;
  v_mid := app.current_member_id();
  v_today := app.family_today(v_fid);

  return jsonb_build_object(
    'in_family', true,
    'today', v_today,
    'me_id', v_mid,
    'family', (select to_jsonb(f) from app.families f where f.id = v_fid),
    'members', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.role, x.created_at)
        from (select m.id, m.family_id, m.user_id, m.nickname, m.role, m.avatar_emoji,
                     m.points_balance, (m.pin_hash is not null) as has_pin, m.created_at,
                     coalesce(md.signed, false)   as signed_today,
                     coalesce(md.active, false)   as active_today,
                     coalesce(md.fullstar, false) as fullstar_today
                from app.members m
                left join app.member_day md
                       on md.member_id = m.id and md.day = v_today
               where m.family_id = v_fid and m.archived_at is null) x
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from app.invites i where i.family_id = v_fid and i.revoked_at is null
    ), '[]'::jsonb)
  );
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
`,j=`-- =============================================================================
-- 011_badges.sql —— 勋章：家长自定义 + 自动评估 + 进度
-- =============================================================================
-- 005 只建了表，规则一直没人算。这里把规则跑起来：
--
--   rule = {"kind":"...", "threshold":N, "dimension":"..."}
--     total_completions  累计完成任务数
--     total_checkins     累计打卡次数
--     total_points       当前积分余额
--     total_signin       累计签到天数
--     total_active       累计活跃天数
--     total_fullstar     累计满星天数
--     streak_days        连续天数，dimension ∈ signin|active|fullstar（默认 active）
--     first_task         完成第一个任务（等价 total_completions threshold=1）
--
-- 评估是事件驱动的：完成任务 / 签到 / 补卡都会调 evaluate_badges，
-- 没有定时任务。达标即写 member_badges（唯一约束兜幂等），不倒扣、不撤回。
-- =============================================================================


-- ###########################################################################
-- 一、规则校验
-- ###########################################################################
create or replace function app.badge_rule_is_valid(r jsonb)
returns boolean
language sql immutable set search_path = app, public as $$
  select coalesce(case
    when r is null or jsonb_typeof(r) <> 'object' then false
    when (r ->> 'kind') is null then false
    when (r ->> 'kind') not in ('total_completions', 'total_checkins', 'total_points',
                                'total_signin', 'total_active', 'total_fullstar',
                                'streak_days', 'first_task') then false
    when (r ->> 'threshold') is null then false
    when (r ->> 'threshold') !~ '^\\d+$' then false
    when (r ->> 'threshold')::int <= 0 then false
    when (r ->> 'kind') = 'streak_days'
         and coalesce(r ->> 'dimension', 'active') not in ('signin', 'active', 'fullstar')
      then false
    else true
  end, false)
$$;


-- ###########################################################################
-- 二、家长维护家庭勋章
-- ###########################################################################
create or replace function app.upsert_badge(
  p_name         text,
  p_rule         jsonb,
  p_parent_token text default null,
  p_id           uuid default null,
  p_emoji        text default '🏅',
  p_tier         text default 'bronze',
  p_description  text default null,
  p_code         text default null,
  p_sort_order   int  default 0
)
returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  b      app.badges%rowtype;
  v_code text;
  v_id   uuid;
begin
  parent := app._parent_guard(p_parent_token);

  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'BAD_BADGE_NAME: 勋章要有名字';
  end if;
  if length(btrim(p_name)) > 20 then
    raise exception 'BAD_BADGE_NAME: 名字最多 20 个字';
  end if;
  if coalesce(p_tier, 'bronze') not in ('bronze', 'silver', 'gold', 'special') then
    raise exception 'BAD_BADGE_TIER: 等级只能是 bronze/silver/gold/special';
  end if;
  if not app.badge_rule_is_valid(p_rule) then
    raise exception 'BAD_BADGE_RULE: 解锁规则不合法';
  end if;

  if p_id is not null then
    select * into b from app.badges where id = p_id;
    if not found then raise exception 'BADGE_NOT_FOUND'; end if;
    -- 系统内置勋章（family_id is null）所有家庭共享，谁都不能改
    if b.family_id is distinct from parent.family_id then
      raise exception 'FORBIDDEN: 只能改自己家庭的勋章';
    end if;

    update app.badges
       set name        = btrim(p_name),
           emoji       = coalesce(nullif(btrim(p_emoji), ''), '🏅'),
           tier        = coalesce(p_tier, 'bronze'),
           description = nullif(btrim(coalesce(p_description, '')), ''),
           rule        = p_rule,
           sort_order  = coalesce(p_sort_order, 0)
     where id = b.id
     returning id into v_id;
    return v_id;
  end if;

  -- code 只是唯一键，家长不需要关心。给一个稳定可读的默认值。
  v_code := nullif(btrim(coalesce(p_code, '')), '');
  if v_code is null then
    v_code := 'custom_' || substr(md5(gen_random_uuid()::text), 1, 10);
  end if;

  insert into app.badges (family_id, code, name, description, emoji, tier, rule, sort_order)
  values (parent.family_id, v_code, btrim(p_name),
          nullif(btrim(coalesce(p_description, '')), ''),
          coalesce(nullif(btrim(p_emoji), ''), '🏅'),
          coalesce(p_tier, 'bronze'), p_rule, coalesce(p_sort_order, 0))
  returning id into v_id;

  return v_id;
end $$;


create or replace function app.delete_badge(p_id uuid, p_parent_token text default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; n int;
begin
  parent := app._parent_guard(p_parent_token);

  -- family_id is null 的系统勋章匹配不到，自然删不掉
  delete from app.badges where id = p_id and family_id = parent.family_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'BADGE_NOT_FOUND: 没有这个家庭勋章'; end if;

  return jsonb_build_object('deleted', n);
end $$;


-- ###########################################################################
-- 三、评估
-- ###########################################################################
-- 返回 jsonb 数组：每个勋章的进度 + 是否已获得，前端直接渲染进度条。
create or replace function app.evaluate_badges(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  m         app.members%rowtype;
  b         app.badges%rowtype;
  v_kind    text;
  v_dim     text;
  v_thr     int;
  v_prog    int;
  v_earned  boolean;
  v_at      timestamptz;
  v_out     jsonb := '[]'::jsonb;
begin
  select * into m from app.members where id = p_member_id;
  if not found then return v_out; end if;

  for b in
    select * from app.badges
     where family_id = m.family_id or family_id is null
     order by (family_id is null), sort_order, name
  loop
    if not app.badge_rule_is_valid(b.rule) then continue; end if;

    v_kind := b.rule ->> 'kind';
    v_thr  := (b.rule ->> 'threshold')::int;
    v_prog := 0;
    v_dim  := null;

    if v_kind = 'total_completions' then
      select count(*)::int into v_prog from app.task_occurrences o
       where o.assignee_id = m.id and o.status = 'completed';

    elsif v_kind = 'first_task' then
      -- 早起鸟：按家庭时区算，早上 8 点前完成的任务
      select count(*)::int into v_prog
        from app.task_occurrences o
        join app.families f on f.id = o.family_id
       where o.assignee_id = m.id and o.status = 'completed'
         and o.completed_at is not null
         and extract(hour from (o.completed_at at time zone f.timezone)) < 8;

    elsif v_kind = 'total_checkins' then
      select count(*)::int into v_prog from app.checkins c where c.member_id = m.id;

    elsif v_kind = 'total_points' then
      v_prog := m.points_balance;

    elsif v_kind = 'total_signin' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.signed;

    elsif v_kind = 'total_active' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.active;

    elsif v_kind = 'total_fullstar' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.fullstar;

    elsif v_kind = 'streak_days' then
      v_dim := coalesce(b.rule ->> 'dimension', 'active');
      v_prog := app.member_streak(m.id, v_dim);
    end if;

    v_earned := v_prog >= v_thr;

    if v_earned then
      insert into app.member_badges (member_id, badge_id, source_type, source_id)
      values (m.id, b.id, 'rule', b.id)
      on conflict (member_id, badge_id) do nothing;
    end if;

    select mb.awarded_at into v_at from app.member_badges mb
     where mb.member_id = m.id and mb.badge_id = b.id;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id',          b.id,
      'badge_id',    b.id,
      'code',        b.code,
      'name',        b.name,
      'emoji',       b.emoji,
      'tier',        b.tier,
      'description', b.description,
      'rule',        b.rule,
      'kind',        v_kind,
      'dimension',   v_dim,
      'progress',    least(v_prog, v_thr),
      'raw_progress', v_prog,
      'threshold',   v_thr,
      'earned',      (v_at is not null),
      'earned_at',   v_at,
      'is_system',   (b.family_id is null)));
  end loop;

  return v_out;
end $$;


-- 前端勋章页调这个：先评估再返回，保证进度和刚做完的动作对得上。
create or replace function app.list_badges_with_progress(p_member_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype; target app.members%rowtype;
begin
  me := app.require_member();

  if p_member_id is null or p_member_id = me.id then
    target := me;
  else
    select * into target from app.members
     where id = p_member_id and family_id = me.family_id;
    if not found then raise exception 'FORBIDDEN: 只能看本家庭成员'; end if;
  end if;

  return app.evaluate_badges(target.id);
end $$;


-- 家长的勋章管理页：本家庭自定义 + 系统内置（系统的只读，is_system=true）
create or replace function app.list_family_badges(p_parent_token text default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  me := app.require_member();
  -- 只读列表不值得再要一次 PIN：是家长就能看。给了 token 就顺手验一下。
  if p_parent_token is not null then
    perform app.require_parent(p_parent_token);
  elsif me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只有家长能管理勋章';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', b.id,
             'code', b.code,
             'name', b.name,
             'emoji', b.emoji,
             'tier', b.tier,
             'description', b.description,
             'rule', b.rule,
             'sort_order', b.sort_order,
             'is_system', (b.family_id is null),
             'earned_count', (select count(*)::int from app.member_badges mb
                               join app.members m2 on m2.id = mb.member_id
                              where mb.badge_id = b.id and m2.family_id = me.family_id))
             order by (b.family_id is null), b.sort_order, b.name)
      from app.badges b
     where b.family_id = me.family_id or b.family_id is null), '[]'::jsonb);
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
`,E=`-- =============================================================================
-- 050_server_auth.sql —— 自托管后端的身份密钥
-- =============================================================================
-- CloudBase / Supabase 自带账号体系与 auth.uid() 的绑定，不需要这一层。
-- 我们选了"全自建在轻量云"：成员身份 = (user_id, login_key)。
--   * user_id     公开标识（UUID），设备用它定位自己的成员行
--   * login_key   私密凭证（随机串），跨设备迁移身份时随身携带
-- 同一人在不同设备只要带上同一对 (user_id, login_key)，就能拿到同一个
-- sub 的 JWT，看到同一份家庭数据 —— 这就是"多端同步"。
-- =============================================================================

alter table app.members add column if not exists login_key_hash text;

-- user_id 必须能唯一定位一个成员（本地每浏览器一个，服务端跨设备复用同一个）
create unique index if not exists members_user_id_uidx on app.members(user_id);

-- 把当前身份的登录密钥哈希写进自己的行。SECURITY DEFINER + auth.uid() 保证
-- 只能写自己，且即使在 RLS 下也能执行（策略不递归）。
create or replace function app.set_member_login_key(p_key_hash text)
returns void
language plpgsql security definer set search_path = app, public as $$
begin
  update app.members set login_key_hash = p_key_hash where user_id = auth.uid();
  if not found then
    raise exception 'NOT_A_MEMBER: 无法绑定登录密钥';
  end if;
end $$;

grant execute on function app.set_member_login_key(text) to authenticated, service_role;
`,_=Object.assign({"/db/local/000_shim.sql":u}),p=Object.assign({"/db/migrations/000_init.sql":f,"/db/migrations/001_family.sql":b,"/db/migrations/002_tasks.sql":h,"/db/migrations/003_occurrences.sql":y,"/db/migrations/004_points.sql":g,"/db/migrations/005_badges.sql":v,"/db/migrations/006_shop.sql":k,"/db/migrations/007_functions.sql":w,"/db/migrations/008_rls.sql":x,"/db/migrations/009_seed.sql":q,"/db/migrations/010_signin.sql":$,"/db/migrations/011_badges.sql":j,"/db/migrations/050_server_auth.sql":E}),l="idb://familyquest",N=1082,D=s=>s.length>=10?s.slice(0,10):s;class O{pg=null;booting=null;identity=null;async ready(){return this.booting||(this.booting=this.boot()),this.booting}async boot(){this.pg=await c.create({dataDir:l,relaxedDurability:!0,parsers:{[N]:D}}),await this.migrate(),await this.applyIdentity()}async migrate(){const e=this.pg;await e.exec("reset role;"),await e.exec(`
      create table if not exists public.__migrations (
        name text primary key,
        applied_at timestamptz not null default now()
      );
    `);const t=[...Object.keys(_).sort().map(n=>[n,_[n]]),...Object.keys(p).sort().map(n=>[n,p[n]])];for(const[n,a]of t)if(!(((await e.query("select count(*)::int as n from public.__migrations where name = $1",[n])).rows[0]?.n??0)>0))try{await e.exec(a),await e.query("insert into public.__migrations (name) values ($1)",[n])}catch(i){throw new Error(`迁移失败 ${n}：${i.message}`)}}async applyIdentity(){const e=this.pg;await e.exec("reset role;"),await e.query("select set_config($1, $2, false)",["request.jwt.claims",JSON.stringify({sub:this.identity,role:"authenticated"})]),await e.exec("set role authenticated;")}async setIdentity(e){this.identity=e,this.pg&&await this.applyIdentity()}async query(e,t=[]){await this.ready();try{return(await this.pg.query(e,t)).rows}catch(n){throw new m(n.message)}}async rpc(e,t={}){const n=Object.keys(t),a=n.map((o,r)=>`${o} => $${r+1}`).join(", "),d=n.map(o=>{const r=t[o];return r!==null&&typeof r=="object"?JSON.stringify(r):r});return(await this.query(`select app.${e}(${a}) as result`,d))[0]?.result}async dump(){return await this.ready(),await this.pg.dumpDataDir("gzip")}async reset(){this.pg&&await this.pg.close(),this.pg=null,this.booting=null;const e=`/pglite/${l.replace(/^idb:\/\//,"")}`;await this.deleteIdb(e)}async deleteIdb(e){const t=Date.now()+3e3;for(;;){if(await new Promise((a,d)=>{const i=indexedDB.deleteDatabase(e);i.onsuccess=()=>a("deleted"),i.onerror=()=>d(i.error),i.onblocked=()=>a("blocked")})==="deleted")return;if(console.warn(`[familyquest] 删除 IndexedDB 库 ${e} 被其他标签页阻塞，300ms 后重试`),Date.now()>=t){console.warn(`[familyquest] 等待 ${e} 释放连接超时（>3s），放弃删除；请关闭其他打开本应用的标签页后重试`);return}await new Promise(a=>setTimeout(a,300))}}}export{O as PGliteBackend};
