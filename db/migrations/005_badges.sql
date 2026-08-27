-- =============================================================================
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
