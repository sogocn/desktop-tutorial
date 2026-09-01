-- =============================================================================
-- test_checkin_012.sql —— 打卡计分 / 满星计打卡 / 完成全部
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在一个事务里，最后 ROLLBACK。所有"今天"从 app.family_today() 取。
-- =============================================================================

begin;

-- 独立家庭，id 带 012 后缀，避免和别的 suite 撞
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0000000-0000-4000-8000-000000000012', '打卡之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000012', 'f0000000-0000-4000-8000-000000000012',
   'a1000000-0000-4000-8000-000000000012', '爸', 'parent'),
  ('b0000000-0000-4000-8000-000000000012', 'f0000000-0000-4000-8000-000000000012',
   'b1000000-0000-4000-8000-000000000012', '娃', 'child');

-- ---------------------------------------------------------------------------
-- A/B：打卡只发打卡分；打卡达标后当天满星
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000012';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000012';
  v_task  uuid := 'c0000000-0000-4000-8000-000000000012';
  v_today date;
  r jsonb; n int; v_bal int; v_full boolean; v_active boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000012","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  -- 带打卡(2) + 完成(5) 的循环任务，每日打卡上限 1
  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    (v_task, v_fid, v_kid, 'a0000000-0000-4000-8000-000000000012',
     '跳绳', 'recurring', '{"freq":"daily"}',
     v_today - 60, 5, 2, 1, true);

  -- A1 打卡只发打卡分（2），不发完成分（5）
  v_bal := (select points_balance from app.members where id = v_kid);
  r := app.record_checkin(v_task, v_today);
  assert (r->>'points_awarded')::int = 2,
    format('A1 打卡应只发 2 分，实际 %s', r->>'points_awarded');
  assert (select points_balance from app.members where id = v_kid) = v_bal + 2,
    format('A1b 余额应 +2，实际 %s', (select points_balance from app.members where id = v_kid));
  select count(*) into n from app.point_ledger
   where member_id = v_kid and source_type = 'completion' and entry_kind = 'primary';
  assert n = 0, format('A1c 打卡不应产生 completion 流水，实际 %s 条', n);

  -- B1 打卡达标后当天应满星（当天只有这一条任务，达标即满星）
  select fullstar, active into v_full, v_active
    from app.member_day where member_id = v_kid and day = v_today;
  assert v_full, 'B1 打卡达标后当天应满星';
  assert v_active, 'B1b 打卡后当天应活跃';

  -- B2 反例：清空当天打卡后重算，满星应回落
  delete from app.checkins where occurrence_id in (
    select id from app.task_occurrences where task_id = v_task and occurrence_date = v_today);
  perform app.refresh_day_status(v_kid, v_today);
  select fullstar into v_full from app.member_day where member_id = v_kid and day = v_today;
  assert not v_full, 'B2 清空打卡后当天不应满星';

  raise notice '  [A/B] 打卡计分 & 满星计打卡 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- C：完成全部 —— 批量完成 + 完成分只发一次（幂等）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000012';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000012';
  v_task  uuid := 'c0000000-0000-4000-8000-000000000013';
  v_today date;
  r jsonb; n int; v_bal int; v_badge int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000012","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  -- 无打卡、完成分 5 的循环任务，ends_on = 今天+2（共 3 天）
  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, ends_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    (v_task, v_fid, v_kid, 'a0000000-0000-4000-8000-000000000012',
     '写日记', 'recurring', '{"freq":"daily"}',
     v_today - 60, v_today + 2, 5, 0, 1, true);

  select coalesce(sum(delta), 0) into v_badge
    from app.point_ledger
   where member_id = v_kid and source_type = 'badge' and entry_kind = 'primary';

  v_bal := (select points_balance from app.members where id = v_kid);
  r := app.complete_all_occurrences(v_task, null);
  assert (r->>'completed_occurrences')::int = 3,
    format('C1 应完成 3 天，实际 %s', r->>'completed_occurrences');
  -- 013 起：完成全部 = 补齐各日「单次分」+ 一笔完成分。
  -- 本任务无打卡分，单次分即完成分 5 → 3 天共 15；无独立完成分故不再额外结算。
  assert (r->>'points_awarded')::int = 15,
    format('C2 应补齐 3 天单次分(5×3=15)，实际 %s', r->>'points_awarded');
  -- 013 起首发勋章会带额外奖励分（此处为「第一步」5 分），单独计入基线
  select coalesce(sum(delta), 0) - v_badge into v_badge
    from app.point_ledger
   where member_id = v_kid and source_type = 'badge' and entry_kind = 'primary';
  assert (select points_balance from app.members where id = v_kid) = v_bal + 15 + v_badge,
    format('C2b 余额应 +15(+勋章%s)，实际 %s', v_badge,
      (select points_balance from app.members where id = v_kid));
  -- 逐次结算：completion 类型 primary 流水应为 3 条（source_id = 各 occurrence）
  select count(*) into n from app.point_ledger l
    join app.task_occurrences o on o.id = l.source_id
   where l.member_id = v_kid and l.source_type = 'completion' and l.entry_kind = 'primary'
     and o.task_id = v_task;
  assert n = 3, format('C3 完成全部应产生 3 条逐次 completion 流水，实际 %s 条', n);

  -- C4 幂等：再跑一次，应 0 完成、0 发分
  v_bal := (select points_balance from app.members where id = v_kid);
  r := app.complete_all_occurrences(v_task, null);
  assert (r->>'completed_occurrences')::int = 0,
    format('C4 第二次应完成 0 天，实际 %s', r->>'completed_occurrences');
  assert (r->>'points_awarded')::int = 0,
    format('C4b 第二次应发 0 分，实际 %s', r->>'points_awarded');
  assert (select points_balance from app.members where id = v_kid) = v_bal,
    format('C4c 余额不应变化，实际 %s', (select points_balance from app.members where id = v_kid));

  raise notice '  [C] 完成全部 批量+单次发分+幂等 ✓';
end $$;

do $$
begin
  raise notice '===========================================';
  raise notice '  打卡/完成逻辑断言通过（A/B/C 共 11 项）';
  raise notice '===========================================';
end $$;

rollback;
