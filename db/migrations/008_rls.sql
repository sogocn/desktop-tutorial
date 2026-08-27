-- =============================================================================
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
