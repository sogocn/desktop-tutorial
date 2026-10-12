-- =============================================================================
-- test_fullstar_points_025.sql —— 每天完成满星奖励 30 积分（025）
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在一个事务里，最后 ROLLBACK。所有"今天"从 app.family_today() 取。
-- =============================================================================

begin;

insert into app.families (id, name, timezone, day_cutoff_hour) values
  ('f0000000-0000-4000-8000-000000000025', '满星之家', 'Asia/Shanghai', 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000025', 'f0000000-0000-4000-8000-000000000025',
   'a1000000-0000-4000-8000-000000000025', '爸025', 'parent'),
  ('b0000000-0000-4000-8000-000000000025', 'f0000000-0000-4000-8000-000000000025',
   'b1000000-0000-4000-8000-000000000025', '娃025', 'child'),
  -- 什么都不安排的娃：用来验证"没任务的日子不白送分"
  ('c0000000-0000-4000-8000-000000000025', 'f0000000-0000-4000-8000-000000000025',
   'c1000000-0000-4000-8000-000000000025', '闲025', 'child');

-- 本文件只验满星奖励的加减，先把 009 预置的全局勋章摘掉（本事务结束即回滚，
-- 不影响其它 suite）。留着的话"完成第一个任务"会额外发 5 分勋章奖励，
-- 每条余额断言都要再挂一个勋章基线，算式反而不清楚。
delete from app.badges where family_id is null;

-- ---------------------------------------------------------------------------
-- F0 默认分值 30
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid uuid := 'f0000000-0000-4000-8000-000000000025';
  v_pts int;
begin
  select fullstar_points into v_pts from app.families where id = v_fid;
  assert v_pts = 30, format('F0 新建家庭满星奖励默认应为 30，实际 %s', v_pts);
  assert app.fullstar_points(v_fid) = 30, 'F0b fullstar_points() 应返回 30';
  raise notice '✓ F0 满星奖励默认 30 分（可按家庭改）';
end $$;

-- ---------------------------------------------------------------------------
-- F1 当天全部任务完成 → 满星 → +30；F2 反复重算不重复发
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000025';
  v_par   uuid := 'a0000000-0000-4000-8000-000000000025';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000025';
  v_t1    uuid := 'c0000000-0000-4000-8000-000000000025';
  v_t2    uuid := 'd0000000-0000-4000-8000-000000000025';
  v_today date;
  v_bal0  int;
  v_full  boolean;
  n       int;
  v_delta int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000025","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);
  v_bal0 := (select points_balance from app.members where id = v_kid);

  -- 两条每日循环任务，各 5 分完成分，不设打卡分（达标只看完成）
  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    (v_t1, v_fid, v_kid, v_par, '语文作业', 'recurring', '{"freq":"daily"}',
     v_today - 60, 5, 0, 1, true),
    (v_t2, v_fid, v_kid, v_par, '数学作业', 'recurring', '{"freq":"daily"}',
     v_today - 60, 5, 0, 1, true);

  -- F1a 只做完一个：不满星、不发奖励（只有 5 分完成分）
  perform app.complete_occurrence(v_t1, v_today);
  select fullstar into v_full from app.member_day where member_id = v_kid and day = v_today;
  assert not v_full, 'F1a 还剩一个任务时不该满星';
  select count(*) into n from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar' and entry_kind = 'primary';
  assert n = 0, format('F1b 未满星不该发奖励，实际 %s 条', n);

  -- F1c 第二个也做完 → 满星 +30
  perform app.complete_occurrence(v_t2, v_today);
  select fullstar into v_full from app.member_day where member_id = v_kid and day = v_today;
  assert v_full, 'F1c 两个任务都完成应满星';

  select delta into v_delta from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar' and entry_kind = 'primary';
  assert v_delta = 30, format('F1d 满星奖励应为 30 分，实际 %s', v_delta);
  assert (select points_balance from app.members where id = v_kid) = v_bal0 + 5 + 5 + 30,
    format('F1e 余额应为 +40，实际 %s',
           (select points_balance from app.members where id = v_kid) - v_bal0);

  -- F2 反复重算（每完成一次都会调 refresh）不该重复发
  perform app.refresh_day_status(v_kid, v_today);
  perform app.refresh_day_status(v_kid, v_today);
  select count(*) into n from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar' and entry_kind = 'primary';
  assert n = 1, format('F2 同一天重复重算不应重复发，实际 %s 条', n);
  assert (select points_balance from app.members where id = v_kid) = v_bal0 + 40,
    'F2b 重复重算后余额不应变化';

  raise notice '✓ F1 当天全部完成 → 满星 +30';
  raise notice '✓ F2 反复重算只发一次（幂等）';
end $$;

-- ---------------------------------------------------------------------------
-- F3 满星被撤回 → 奖励反向记账收回；F4 家庭调到 50 分后重新满星发 50
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000025';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000025';
  v_t2    uuid := 'd0000000-0000-4000-8000-000000000025';
  v_today date;
  v_bal0  int := 40;   -- 上一段结束时相对起始的增量：5+5+30
  v_bal   int;
  n       int;
  v_seq   int;
  v_delta int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000025","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  -- F3 撤回数学作业 → 完成分 5 与满星 30 一起被收回
  perform app.uncomplete_occurrence(v_t2, v_today);
  v_bal := (select points_balance from app.members where id = v_kid);
  assert v_bal = v_bal0 - 35, format('F3 撤回应收回 5+30，余额应回到 %s，实际 %s', v_bal0 - 35, v_bal);
  select count(*) into n from app.point_ledger
   where member_id = v_kid and entry_kind = 'reversal'
     and reverses_id in (select id from app.point_ledger
                          where member_id = v_kid and source_type = 'fullstar');
  assert n = 1, format('F3b 应有一条满星奖励的反向记账，实际 %s 条', n);

  -- F4 家长把满星奖励调成 50 → 重新做完应发 50（且是新 seq，不是撞死在唯一约束上）
  update app.families set fullstar_points = 50 where id = v_fid;
  perform app.complete_occurrence(v_t2, v_today);
  select source_seq, delta into v_seq, v_delta
    from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar' and entry_kind = 'primary'
   order by source_seq desc limit 1;
  assert v_delta = 50, format('F4 调价后应发 50，实际 %s', v_delta);
  assert v_seq = 1, format('F4b 重新满星应新起 seq=1，实际 %s', v_seq);
  assert (select points_balance from app.members where id = v_kid) = v_bal0 + 20,
    format('F4c 余额应为 %s，实际 %s', v_bal0 + 20,
           (select points_balance from app.members where id = v_kid));

  raise notice '✓ F3 满星被撤回 → 奖励反向收回';
  raise notice '✓ F4 调价到 50 后重新满星发 50（seq 递增，不撞唯一约束）';
end $$;

-- ---------------------------------------------------------------------------
-- F5 未来的日子不发：提前完成明天的任务，不该今天就领明天的奖励
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid    uuid := 'f0000000-0000-4000-8000-000000000025';
  v_kid    uuid := 'b0000000-0000-4000-8000-000000000025';
  v_t1     uuid := 'c0000000-0000-4000-8000-000000000025';
  v_t2     uuid := 'd0000000-0000-4000-8000-000000000025';
  v_today  date;
  v_before int;
  v_after  int;
  n0       int;
  n1       int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000025","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);
  v_before := (select points_balance from app.members where id = v_kid);
  select count(*) into n0 from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar' and entry_kind = 'primary';

  perform app.complete_occurrence(v_t1, v_today + 1);
  perform app.complete_occurrence(v_t2, v_today + 1);
  v_after := (select points_balance from app.members where id = v_kid);
  select count(*) into n1 from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar' and entry_kind = 'primary';

  -- 完成分照发（10），但满星奖励不该发
  assert v_after = v_before + 10,
    format('F5 明天的完成分照发 10，实际 +%s', v_after - v_before);
  assert n1 = n0, format('F5b 明天的满星不该发奖励，满星流水从 %s 变成 %s', n0, n1);
  assert not exists (
    select 1 from app.point_ledger
     where member_id = v_kid and source_type = 'fullstar' and occurrence_date = v_today + 1),
    'F5c 未来的日子不该发满星奖励';

  raise notice '✓ F5 未来日期不发满星奖励（防止提前刷分）';
end $$;

-- ---------------------------------------------------------------------------
-- F6 补满星卡点亮过去的一天 → 补发那天的奖励
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000025';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000025';
  v_today date;
  v_delta int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000025","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  insert into app.member_cards (member_id, kind, qty)
  values (v_kid, 'retro_fullstar', 1)
  on conflict (member_id, kind) do update set qty = 1;

  perform app.use_retro_card('retro_fullstar', v_today - 1, v_kid);

  select delta into v_delta from app.point_ledger
   where member_id = v_kid and source_type = 'fullstar'
     and entry_kind = 'primary' and occurrence_date = v_today - 1;
  -- 上一段已把家庭价调成 50
  assert v_delta = 50, format('F6 补卡点亮昨天应补发满星奖励（50），实际 %s', v_delta);

  raise notice '✓ F6 补满星卡点亮过去一天 → 补发当天奖励';
end $$;

-- ---------------------------------------------------------------------------
-- F7 没安排任务的成员：满星不算、也不发分
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000025';
  v_idle  uuid := 'c0000000-0000-4000-8000-000000000025';
  v_today date;
  v_full  boolean;
  n       int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"c1000000-0000-4000-8000-000000000025","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  perform app.refresh_day_status(v_idle, v_today);
  select fullstar into v_full from app.member_day where member_id = v_idle and day = v_today;
  assert not v_full, 'F7 没有任务的日子不该算满星';

  select count(*) into n from app.point_ledger
   where member_id = v_idle and source_type = 'fullstar';
  assert n = 0, format('F7b 没有任务不该发满星奖励，实际 %s 条', n);

  raise notice '✓ F7 没安排任务的成员不白送分';
end $$;

rollback;
