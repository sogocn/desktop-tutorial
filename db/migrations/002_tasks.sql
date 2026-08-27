-- =============================================================================
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
        (r ? 'date') and (r ->> 'date') ~ '^\d{4}-\d{2}-\d{2}$'
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
