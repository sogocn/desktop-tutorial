-- =============================================================================
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
