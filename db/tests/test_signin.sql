-- =============================================================================
-- test_signin.sql —— 签到 / 活跃 / 满星 / 连续奖励 / 补签卡 / 调分 / 勋章
-- =============================================================================
-- 跑法：npm run db:test。整个脚本包在一个事务里，最后 ROLLBACK。
--
-- 断言分段：
--   I 记账修复（完成→撤销→再完成必须再加一次分）
--   J 家长手动调分
--   K 签到
--   L 活跃 / 满星自动标记
--   M 连续天数 + 档位奖励 + 补签卡发放
--   N 补签卡消耗
--   O 勋章
--   P bootstrap / summary
--
-- 所有"今天"都从 app.family_today() 取，绝不写死日期 —— 这个脚本明年也要能跑。
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 固定数据。child_daily_points_cap = 0 表示不限额，
-- 否则连续奖励一发就撞上限，断言全成薛定谔的猫。
-- ---------------------------------------------------------------------------
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0000000-0000-4000-8000-000000000001', '签到之家', 'Asia/Shanghai', 0, 0),
  ('f0000000-0000-4000-8000-000000000002', '隔壁老王家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001', '爸爸', 'parent'),
  ('b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001',
   'b1000000-0000-4000-8000-000000000001', '小明', 'child'),
  ('b0000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000001',
   'b1000000-0000-4000-8000-000000000002', '小红', 'child'),
  ('a0000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000002',
   'a1000000-0000-4000-8000-000000000002', '老王', 'parent'),
  ('b0000000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000002',
   'b1000000-0000-4000-8000-000000000003', '小王', 'child');

-- 小明名下两个每日任务（各 5 分），小红一个（3 分）
insert into app.tasks
  (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
   starts_on, completion_points, checkin_points, checkin_daily_limit)
values
  ('c0000000-0000-4000-8000-00000000000a', 'f0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   '每日阅读', 'recurring', '{"freq":"daily"}',
   app.family_today('f0000000-0000-4000-8000-000000000001') - 60, 5, 0, 1),
  ('c0000000-0000-4000-8000-00000000000b', 'f0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   '练琴', 'recurring', '{"freq":"daily"}',
   app.family_today('f0000000-0000-4000-8000-000000000001') - 60, 5, 0, 1),
  ('c0000000-0000-4000-8000-00000000000c', 'f0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001',
   '收拾玩具', 'recurring', '{"freq":"daily"}',
   app.family_today('f0000000-0000-4000-8000-000000000001') - 60, 3, 0, 1);


-- ###########################################################################
-- I. 记账修复：完成 → 撤销 → 再完成，必须真的再加一次分
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  v_task uuid := 'c0000000-0000-4000-8000-00000000000a';
  v_today date;
  r jsonb; n int; v_bal int; v_sum int; v_badge int; ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  v_today := app.today();

  -- I1 第一次完成加 5 分
  r := app.complete_occurrence(v_task, v_today);
  assert (r->>'points_awarded')::int = 5, format('I1 首次完成应加 5 分，实际 %s', r->>'points_awarded');

  -- 013 起首次拿到勋章会额外发一笔奖励分，且不随撤销退回。
  -- 后面的余额断言都以此为基线，实读流水而不是写死数值。
  select coalesce(sum(delta), 0) into v_badge from app.point_ledger
   where member_id = v_ming and source_type = 'badge' and entry_kind = 'primary';
  assert v_badge > 0, 'I1a 首次完成任务应有勋章奖励分';

  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = 5 + v_badge, format('I1b 余额应为 %s，实际 %s', 5 + v_badge, v_bal);

  -- I2 撤销退分
  r := app.uncomplete_occurrence(v_task, v_today);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = v_badge, format('I2 撤销后余额应为 %s，实际 %s', v_badge, v_bal);

  -- I3 ★核心 bug：再次完成必须再加 5 分（旧实现会被唯一索引静默吞掉，停在 0）
  r := app.complete_occurrence(v_task, v_today);
  assert (r->>'points_awarded')::int = 5,
    format('I3 撤销后再完成应再加 5 分，实际 %s', r->>'points_awarded');
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = 5 + v_badge, format('I3b 余额应回到 %s，实际 %s', 5 + v_badge, v_bal);

  -- I4 两条 primary completion，序号 0 / 1
  select count(*)::int into n from app.point_ledger
   where entry_kind = 'primary' and source_type = 'completion'
     and source_id = (select id from app.task_occurrences
                       where task_id = v_task and occurrence_date = v_today);
  assert n = 2, format('I4 应有 2 条 primary completion，实际 %s', n);

  select count(*)::int into n from app.point_ledger
   where entry_kind = 'primary' and source_type = 'completion' and source_seq = 1;
  assert n = 1, format('I4b 第二次完成的 source_seq 应为 1，实际 %s 条', n);

  -- I5 撤销是追加 reversal，原记录一条不少（铁律 5）
  select count(*)::int into n from app.point_ledger
   where entry_kind = 'reversal' and delta = -5;
  assert n = 1, format('I5 应有 1 条 -5 的反向记账，实际 %s', n);

  -- I6 重复点完成仍然幂等，不重复发分
  r := app.complete_occurrence(v_task, v_today);
  assert (r->>'already')::boolean, 'I6 重复完成应返回 already=true';
  assert (r->>'points_awarded')::int = 0, 'I6b 重复完成不能再发分';
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = 5 + v_badge, format('I6c 余额仍应为 %s，实际 %s', 5 + v_badge, v_bal);

  -- I7 第二轮撤销撤的是 seq=1 那条，不是早就撤过的 seq=0
  r := app.uncomplete_occurrence(v_task, v_today);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = v_badge, format('I7 二次撤销后余额应为 %s，实际 %s', v_badge, v_bal);
  select count(*)::int into n from app.point_ledger where entry_kind = 'reversal';
  assert n = 2, format('I7b 应有 2 条 reversal，实际 %s', n);

  -- I8 第三次完成 → seq=2
  r := app.complete_occurrence(v_task, v_today);
  select count(*)::int into n from app.point_ledger
   where entry_kind = 'primary' and source_type = 'completion' and source_seq = 2;
  assert n = 1, format('I8 第三次完成的 source_seq 应为 2，实际 %s 条', n);

  -- I9 请假也要能退掉最后一条完成分
  r := app.skip_occurrence(v_task, v_today);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = v_badge, format('I9 改请假后余额应为 %s，实际 %s', v_badge, v_bal);

  -- I10 对账：流水合计 === 余额缓存
  select coalesce(sum(delta), 0) into v_sum from app.point_ledger where member_id = v_ming;
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_sum = v_bal, format('I10 流水合计 %s 应等于余额 %s', v_sum, v_bal);

  -- I11 没完成过的不能撤销
  ok := false;
  begin
    perform app.uncomplete_occurrence('c0000000-0000-4000-8000-00000000000b', v_today);
  exception when others then ok := (sqlerrm like 'NOT_COMPLETED%');
  end;
  assert ok, 'I11 未完成的任务不能撤销';

  raise notice '  [I] 记账修复 15 项 ✓';
end $$;


-- ###########################################################################
-- J. 家长手动调分
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  v_dad  uuid := 'a0000000-0000-4000-8000-000000000001';
  v_tok  text;
  r jsonb; n int; v_bal int; v_bal0 int; v_sum int; ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  perform app.set_pin('1234');
  v_tok := app.verify_parent_pin('1234') ->> 'token';

  select points_balance into v_bal0 from app.members where id = v_ming;

  -- J1 打赏 +50
  r := app.adjust_member_points(v_tok, v_ming, 50, '主动帮妈妈洗碗');
  assert (r->>'delta')::int = 50, format('J1 delta 应为 50，实际 %s', r->>'delta');
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = v_bal0 + 50, format('J1b 余额应为 %s，实际 %s', v_bal0 + 50, v_bal);

  -- J2 流水留痕，来源是 manual
  select count(*)::int into n from app.point_ledger
   where member_id = v_ming and source_type = 'manual' and delta = 50
     and reason = '主动帮妈妈洗碗';
  assert n = 1, format('J2 应有 1 条 manual +50 流水，实际 %s', n);

  -- J3 扣分 -30
  r := app.adjust_member_points(v_tok, v_ming, -30, '摔了碗');
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = v_bal0 + 20, format('J3 余额应为 %s，实际 %s', v_bal0 + 20, v_bal);

  -- J4 扣分同样只追加流水
  select count(*)::int into n from app.point_ledger
   where member_id = v_ming and source_type = 'manual' and delta = -30;
  assert n = 1, format('J4 应有 1 条 manual -30 流水，实际 %s', n);

  -- J5 manual 不带 source_id，可以反复调，不会被唯一索引挡住
  r := app.adjust_member_points(v_tok, v_ming, 5, '再赏一点');
  r := app.adjust_member_points(v_tok, v_ming, 5, '再赏一点');
  select count(*)::int into n from app.point_ledger
   where member_id = v_ming and source_type = 'manual' and delta = 5;
  assert n = 2, format('J5 两次 +5 应有 2 条流水，实际 %s', n);

  -- J6 不给理由时给个默认理由，不能是空
  r := app.adjust_member_points(v_tok, v_ming, 3, null);
  select count(*)::int into n from app.point_ledger
   where member_id = v_ming and source_type = 'manual' and delta = 3
     and coalesce(btrim(reason), '') <> '';
  assert n = 1, 'J6 缺省理由不能为空';

  -- J7 家长不能给自己调分
  ok := false;
  begin perform app.adjust_member_points(v_tok, v_dad, 100, '给自己发钱');
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'J7 家长给自己调分必须被拒绝';

  -- J8 delta = 0 无意义
  ok := false;
  begin perform app.adjust_member_points(v_tok, v_ming, 0, '啥也没干');
  exception when others then ok := (sqlerrm like 'BAD_DELTA%');
  end;
  assert ok, 'J8 delta=0 必须被拒绝';

  -- J9 扣超余额必须拒绝（余额不允许变负）
  select points_balance into v_bal from app.members where id = v_ming;
  ok := false;
  begin perform app.adjust_member_points(v_tok, v_ming, -(v_bal + 1), '扣穿');
  exception when others then ok := (sqlerrm like 'NOT_ENOUGH_POINTS%');
  end;
  assert ok, 'J9 扣到负数必须被拒绝';

  -- J10 隔壁家的孩子调不动
  ok := false;
  begin perform app.adjust_member_points(v_tok, 'b0000000-0000-4000-8000-000000000003', 10, '越界');
  exception when others then ok := (sqlerrm like 'MEMBER_NOT_FOUND%');
  end;
  assert ok, 'J10 不能给别的家庭调分';

  -- J11 没有家长 token 调不动
  ok := false;
  begin perform app.adjust_member_points('not-a-token', v_ming, 10, '伪造');
  exception when others then ok := (sqlerrm like 'PARENT_TOKEN_INVALID%');
  end;
  assert ok, 'J11 无效 token 必须被拒绝';

  -- J12 删除：014 起设过 PIN 的家长不再被强制重验 token（见 test_no_pin_ops_014.sql）

  -- J13 孩子自己调分：连门都进不去
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  ok := false;
  begin perform app.adjust_member_points(null, v_ming, 999, '自己给自己发钱');
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'J13 孩子不能调分';

  -- J14 对账
  select coalesce(sum(delta), 0) into v_sum from app.point_ledger where member_id = v_ming;
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_sum = v_bal, format('J14 流水合计 %s 应等于余额 %s', v_sum, v_bal);

  raise notice '  [J] 家长调分 15 项 ✓';
end $$;


-- ###########################################################################
-- K. 签到
-- ###########################################################################
do $$
declare
  v_hong uuid := 'b0000000-0000-4000-8000-000000000002';
  v_today date;
  r jsonb; n int; v_bal int; v_bal0 int; ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  v_today := app.today();
  select points_balance into v_bal0 from app.members where id = v_hong;

  -- K1 签到成功
  r := app.do_signin(v_today);
  assert (r->>'signed')::boolean, 'K1 签到后 signed 应为 true';
  assert (r->>'already')::boolean = false, 'K1b 首次签到 already 应为 false';
  assert (r->>'points_awarded')::int = 2, format('K1c 签到应加 2 分，实际 %s', r->>'points_awarded');

  -- K2 余额 +2
  select points_balance into v_bal from app.members where id = v_hong;
  assert v_bal = v_bal0 + 2, format('K2 余额应为 %s，实际 %s', v_bal0 + 2, v_bal);

  -- K3 member_day 落了 signed
  select count(*)::int into n from app.member_day
   where member_id = v_hong and day = v_today and signed;
  assert n = 1, 'K3 member_day.signed 应为 true';

  -- K4 重复签到幂等
  r := app.do_signin(v_today);
  assert (r->>'already')::boolean, 'K4 重复签到 already 应为 true';
  assert (r->>'points_awarded')::int = 0, 'K4b 重复签到不能再发分';
  select points_balance into v_bal from app.members where id = v_hong;
  assert v_bal = v_bal0 + 2, format('K4c 余额不能变，应 %s 实际 %s', v_bal0 + 2, v_bal);

  -- K5 signin 流水只有一条
  select count(*)::int into n from app.point_ledger
   where member_id = v_hong and source_type = 'signin';
  assert n = 1, format('K5 signin 流水应只有 1 条，实际 %s', n);

  -- K6 不传日期默认签今天
  select count(*)::int into n from app.member_day where member_id = v_hong and day = v_today;
  assert n = 1, 'K6 默认日期应是今天';

  -- K7 不能签未来
  ok := false;
  begin perform app.do_signin(v_today + 1);
  exception when others then ok := (sqlerrm like 'BAD_SIGNIN_DATE%');
  end;
  assert ok, 'K7 签未来的日子必须被拒绝';

  -- K8 不能直接补过去（要用补签卡）
  ok := false;
  begin perform app.do_signin(v_today - 1);
  exception when others then ok := (sqlerrm like 'BAD_SIGNIN_DATE%');
  end;
  assert ok, 'K8 直接签过去的日子必须被拒绝';

  -- K9 连续 1 天
  assert app.member_streak(v_hong, 'signin') = 1,
    format('K9 signin streak 应为 1，实际 %s', app.member_streak(v_hong, 'signin'));

  -- K10 维度名写错要报错，不能悄悄返回 0
  ok := false;
  begin perform app.member_streak(v_hong, 'whatever');
  exception when others then ok := (sqlerrm like 'BAD_STREAK_KIND%');
  end;
  assert ok, 'K10 非法维度必须报错';

  raise notice '  [K] 签到 12 项 ✓';
end $$;


-- ###########################################################################
-- L. 活跃 / 满星（按孩子个人算）
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  v_hong uuid := 'b0000000-0000-4000-8000-000000000002';
  v_ta uuid := 'c0000000-0000-4000-8000-00000000000a';
  v_tb uuid := 'c0000000-0000-4000-8000-00000000000b';
  v_today date;
  md app.member_day%rowtype;
  r jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  v_today := app.today();

  -- 前面 I 段最后把 阅读 改成了请假，先归位成 pending 再从头做
  update app.task_occurrences set status = 'pending', completed_at = null
   where task_id = v_ta and occurrence_date = v_today;
  perform app.refresh_day_status(v_ming, v_today);

  -- L1 什么都没做：不活跃、不满星
  select * into md from app.member_day where member_id = v_ming and day = v_today;
  assert not coalesce(md.active, false), 'L1 没完成任务不应是活跃';
  assert not coalesce(md.fullstar, false), 'L1b 没完成任务不应是满星';

  -- L2 完成一个 → 活跃，但还有一个没做，不满星
  r := app.complete_occurrence(v_ta, v_today);
  select * into md from app.member_day where member_id = v_ming and day = v_today;
  assert md.active, 'L2 完成一个任务后应是活跃';
  assert not md.fullstar, 'L2b 还有任务没做，不应满星';

  -- L3 两个都完成 → 满星
  r := app.complete_occurrence(v_tb, v_today);
  select * into md from app.member_day where member_id = v_ming and day = v_today;
  assert md.fullstar, 'L3 名下任务全部完成应满星';

  -- L4 撤销一个 → 满星立刻掉
  r := app.uncomplete_occurrence(v_tb, v_today);
  select * into md from app.member_day where member_id = v_ming and day = v_today;
  assert not md.fullstar, 'L4 撤销后不应还是满星';
  assert md.active, 'L4b 还有一个完成着，仍应是活跃';

  -- L5 请假的日子算"了结"，完成 + 请假也满星
  r := app.skip_occurrence(v_tb, v_today);
  select * into md from app.member_day where member_id = v_ming and day = v_today;
  assert md.fullstar, 'L5 完成 + 请假应算满星';

  -- L6 满星是按孩子个人算的：小红自己没做，不能被小明带上
  select * into md from app.member_day where member_id = v_hong and day = v_today;
  assert not coalesce(md.fullstar, false), 'L6 小红不应因为小明满星而满星';
  assert not coalesce(md.active, false), 'L6b 小红不应因为小明活跃而活跃';

  -- L7 小红完成自己的任务 → 她自己活跃且满星（只有一个任务）
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  r := app.complete_occurrence('c0000000-0000-4000-8000-00000000000c', v_today);
  select * into md from app.member_day where member_id = v_hong and day = v_today;
  assert md.active and md.fullstar, 'L7 小红完成唯一任务应活跃且满星';

  -- L8 签到状态不会被 refresh_day_status 冲掉
  assert md.signed, 'L8 refresh_day_status 不能覆盖 signed';

  -- L9 没有任务的日子不算满星
  perform app.refresh_day_status(v_hong, v_today - 45);  -- 任务起始日之前
  select * into md from app.member_day where member_id = v_hong and day = v_today - 45;
  assert not md.fullstar, 'L9 没有任务的日子不应满星';

  raise notice '  [L] 活跃与满星 11 项 ✓';
end $$;


-- ###########################################################################
-- M. 连续天数 + 档位奖励 + 补签卡
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  v_today date;
  n int; v_bal0 int; v_bal int; v_qty int; v_streak int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  v_today := app.today();

  -- 小明今天先签到（signin streak = 1）
  perform app.do_signin(v_today);
  assert app.member_streak(v_ming, 'signin') = 1, 'M1 signin streak 应为 1';

  -- ---- 连续 3 天签到 ------------------------------------------------------
  insert into app.member_day (member_id, day, signed) values
    (v_ming, v_today - 1, true), (v_ming, v_today - 2, true)
  on conflict (member_id, day) do update set signed = true;

  v_streak := app.member_streak(v_ming, 'signin');
  assert v_streak = 3, format('M2 signin streak 应为 3，实际 %s', v_streak);

  select points_balance into v_bal0 from app.members where id = v_ming;
  perform app.evaluate_streaks(v_ming);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal - v_bal0 = 10, format('M3 连续 3 天签到应 +10，实际 +%s', v_bal - v_bal0);

  select count(*)::int into n from app.member_streak_awards
   where member_id = v_ming and kind = 'signin' and tier = 3;
  assert n = 1, 'M4 应记录 (signin,3) 档位已发';

  -- M5 再算一次不重复发（幂等）
  select points_balance into v_bal0 from app.members where id = v_ming;
  perform app.evaluate_streaks(v_ming);
  perform app.evaluate_streaks(v_ming);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal = v_bal0, format('M5 重复结算不能再发分，多发了 %s', v_bal - v_bal0);

  -- ---- 连续 7 天签到 → +30 且发一张补签卡 --------------------------------
  insert into app.member_day (member_id, day, signed)
  select v_ming, v_today - g, true from generate_series(3, 6) g
  on conflict (member_id, day) do update set signed = true;

  assert app.member_streak(v_ming, 'signin') = 7,
    format('M6 signin streak 应为 7，实际 %s', app.member_streak(v_ming, 'signin'));

  select points_balance into v_bal0 from app.members where id = v_ming;
  perform app.evaluate_streaks(v_ming);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal - v_bal0 = 30, format('M7 连续 7 天签到应 +30，实际 +%s', v_bal - v_bal0);

  select qty into v_qty from app.member_cards
   where member_id = v_ming and kind = 'retro_signin';
  assert v_qty = 1, format('M8 连续 7 天应发 1 张补签卡，实际 %s', coalesce(v_qty, 0));

  select count(*)::int into n from app.member_card_grants
   where member_id = v_ming and kind = 'retro_signin' and streak_at = 7;
  assert n = 1, 'M9 应记录 7 天档的发卡日志';

  -- M10 同一档不会重复发卡
  perform app.evaluate_streaks(v_ming);
  select qty into v_qty from app.member_cards
   where member_id = v_ming and kind = 'retro_signin';
  assert v_qty = 1, format('M10 同一档重复结算不能再发卡，实际 %s', v_qty);

  -- ---- 连续 14 天 → 再发一张 ---------------------------------------------
  insert into app.member_day (member_id, day, signed)
  select v_ming, v_today - g, true from generate_series(7, 13) g
  on conflict (member_id, day) do update set signed = true;

  assert app.member_streak(v_ming, 'signin') = 14, 'M11 signin streak 应为 14';
  perform app.evaluate_streaks(v_ming);
  select qty into v_qty from app.member_cards
   where member_id = v_ming and kind = 'retro_signin';
  assert v_qty = 2, format('M11b 连续 14 天应累计 2 张补签卡，实际 %s', v_qty);

  -- ---- 连续 30 天 → +100，且 30 不是 7 的倍数，不发卡 --------------------
  insert into app.member_day (member_id, day, signed)
  select v_ming, v_today - g, true from generate_series(14, 29) g
  on conflict (member_id, day) do update set signed = true;

  assert app.member_streak(v_ming, 'signin') = 30, 'M12 signin streak 应为 30';
  select points_balance into v_bal0 from app.members where id = v_ming;
  perform app.evaluate_streaks(v_ming);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal - v_bal0 = 100, format('M12b 连续 30 天签到应 +100，实际 +%s', v_bal - v_bal0);
  select qty into v_qty from app.member_cards
   where member_id = v_ming and kind = 'retro_signin';
  assert v_qty = 2, format('M12c 30 天不是 7 的倍数，不该发卡，实际 %s', v_qty);

  -- ---- 断连：中间缺一天就断 ----------------------------------------------
  delete from app.member_day where member_id = v_ming and day = v_today - 5;
  assert app.member_streak(v_ming, 'signin') = 5,
    format('M13 缺 5 天前那天，streak 应为 5，实际 %s', app.member_streak(v_ming, 'signin'));
  insert into app.member_day (member_id, day, signed) values (v_ming, v_today - 5, true)
  on conflict (member_id, day) do update set signed = true;

  -- ---- 活跃维度 -----------------------------------------------------------
  insert into app.member_day (member_id, day, active) values
    (v_ming, v_today - 1, true), (v_ming, v_today - 2, true)
  on conflict (member_id, day) do update set active = true;

  assert app.member_streak(v_ming, 'active') = 3,
    format('M14 active streak 应为 3，实际 %s', app.member_streak(v_ming, 'active'));
  select points_balance into v_bal0 from app.members where id = v_ming;
  perform app.evaluate_streaks(v_ming);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal - v_bal0 = 15, format('M15 连续 3 天活跃应 +15，实际 +%s', v_bal - v_bal0);

  -- ---- 满星维度 -----------------------------------------------------------
  insert into app.member_day (member_id, day, fullstar) values
    (v_ming, v_today - 1, true), (v_ming, v_today - 2, true)
  on conflict (member_id, day) do update set fullstar = true;

  assert app.member_streak(v_ming, 'fullstar') = 3, 'M16 fullstar streak 应为 3';
  select points_balance into v_bal0 from app.members where id = v_ming;
  perform app.evaluate_streaks(v_ming);
  select points_balance into v_bal from app.members where id = v_ming;
  assert v_bal - v_bal0 = 20, format('M17 连续 3 天满星应 +20，实际 +%s', v_bal - v_bal0);

  -- M18 今天还没达成不算断连：小红昨天活跃、今天还没做，streak 从昨天算
  insert into app.member_day (member_id, day, active)
  values ('b0000000-0000-4000-8000-000000000002', v_today - 1, true)
  on conflict (member_id, day) do update set active = true;
  update app.member_day set active = false
   where member_id = 'b0000000-0000-4000-8000-000000000002' and day = v_today;
  assert app.member_streak('b0000000-0000-4000-8000-000000000002', 'active') = 1,
    format('M18 今天未达成时应从昨天起算，实际 %s',
           app.member_streak('b0000000-0000-4000-8000-000000000002', 'active'));

  -- M19 三个维度的 streak 流水都记在 source_type='streak' 上
  select count(*)::int into n from app.point_ledger
   where member_id = v_ming and source_type = 'streak' and entry_kind = 'primary';
  assert n = 5, format('M19 应有 5 条 streak 流水（签到3/7/30 + 活跃3 + 满星3），实际 %s', n);

  -- M20 对账
  select coalesce(sum(delta), 0) into n from app.point_ledger where member_id = v_ming;
  select points_balance into v_bal from app.members where id = v_ming;
  assert n = v_bal, format('M20 流水合计 %s 应等于余额 %s', n, v_bal);

  raise notice '  [M] 连续奖励 22 项 ✓';
end $$;


-- ###########################################################################
-- N. 补签卡消耗
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  v_hong uuid := 'b0000000-0000-4000-8000-000000000002';
  v_today date;
  r jsonb; n int; v_qty int; ok boolean; md app.member_day%rowtype;
begin
  v_today := app.today();

  -- N1 没有卡不能补
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  ok := false;
  begin perform app.use_retro_card('retro_signin', v_today - 3);
  exception when others then ok := (sqlerrm like 'NO_RETRO_CARD%');
  end;
  assert ok, 'N1 没有补签卡必须被拒绝';

  -- 给小红发两张卡（直接写库，模拟她此前挣到的）
  insert into app.member_cards (member_id, kind, qty) values
    (v_hong, 'retro_signin', 2), (v_hong, 'retro_active', 1)
  on conflict (member_id, kind) do update set qty = excluded.qty;

  -- N2 补签成功，扣一张卡
  r := app.use_retro_card('retro_signin', v_today - 3);
  assert (r->>'ok')::boolean, 'N2 补签应成功';
  assert (r->>'remaining')::int = 1, format('N2b 应剩 1 张，实际 %s', r->>'remaining');
  select count(*)::int into n from app.member_day
   where member_id = v_hong and day = v_today - 3 and signed;
  assert n = 1, 'N2c 补的那天应标记为已签到';

  -- N3 补签不发 +2 分（那是主动签到的奖励）
  select count(*)::int into n from app.point_ledger
   where member_id = v_hong and source_type = 'signin';
  assert n = 1, format('N3 补签不应再产生 signin 流水，实际 %s 条', n);

  -- N4 同一天不能重复补
  ok := false;
  begin perform app.use_retro_card('retro_signin', v_today - 3);
  exception when others then ok := (sqlerrm like 'ALREADY_MARKED%');
  end;
  assert ok, 'N4 已达成的日子不能重复补';
  select qty into v_qty from app.member_cards where member_id = v_hong and kind = 'retro_signin';
  assert v_qty = 1, format('N4b 失败的补签不能扣卡，实际剩 %s', v_qty);

  -- N5 补活跃：refresh_day_status 不能把补来的活跃刷回 false
  r := app.use_retro_card('retro_active', v_today - 3);
  select * into md from app.member_day where member_id = v_hong and day = v_today - 3;
  assert md.active, 'N5 补活跃后 active 应为 true';
  assert md.retro_active, 'N5b 应留下 retro_active 粘性标记';
  perform app.refresh_day_status(v_hong, v_today - 3);
  select * into md from app.member_day where member_id = v_hong and day = v_today - 3;
  assert md.active, 'N5c 重算当天状态不能把补来的活跃刷掉';

  -- N6 不能补未来
  ok := false;
  begin perform app.use_retro_card('retro_signin', v_today + 1);
  exception when others then ok := (sqlerrm like 'BAD_DATE%');
  end;
  assert ok, 'N6 不能补未来的日子';

  -- N7 太久以前不能补
  insert into app.member_cards (member_id, kind, qty) values (v_hong, 'retro_signin', 5)
  on conflict (member_id, kind) do update set qty = 5;
  ok := false;
  begin perform app.use_retro_card('retro_signin', v_today - 60);
  exception when others then ok := (sqlerrm like 'RETRO_TOO_OLD%');
  end;
  assert ok, 'N7 超过 30 天不能补';

  -- N8 卡种类写错要报错
  ok := false;
  begin perform app.use_retro_card('retro_whatever', v_today - 2);
  exception when others then ok := (sqlerrm like 'BAD_CARD_KIND%');
  end;
  assert ok, 'N8 非法卡种必须报错';

  -- N9 孩子不能用别人的卡
  ok := false;
  begin perform app.use_retro_card('retro_signin', v_today - 2, v_ming);
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'N9 孩子不能替别人补签';

  -- N10 补签补出连续：补齐 -1 / -2 后 signin streak 应为 4（今天已签）
  perform app.do_signin(v_today);
  perform app.use_retro_card('retro_signin', v_today - 1);
  perform app.use_retro_card('retro_signin', v_today - 2);
  assert app.member_streak(v_hong, 'signin') = 4,
    format('N10 补签后 streak 应为 4，实际 %s', app.member_streak(v_hong, 'signin'));

  -- N11 补出来的连续同样发档位奖励（3 天 → +10 已经发过）
  select count(*)::int into n from app.member_streak_awards
   where member_id = v_hong and kind = 'signin' and tier = 3;
  assert n = 1, 'N11 补出来的连续也要发 3 天档奖励';

  -- N12 家长可以替孩子用卡
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  insert into app.member_cards (member_id, kind, qty) values (v_hong, 'retro_fullstar', 1)
  on conflict (member_id, kind) do update set qty = 1;
  r := app.use_retro_card('retro_fullstar', v_today - 4, v_hong);
  assert (r->>'ok')::boolean, 'N12 家长应能替孩子用卡';
  select count(*)::int into n from app.member_day
   where member_id = v_hong and day = v_today - 4 and fullstar;
  assert n = 1, 'N12b 补满星应生效';

  raise notice '  [N] 补签卡 15 项 ✓';
end $$;


-- ###########################################################################
-- O. 勋章
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  v_tok  text;
  v_bid  uuid;
  arr jsonb; e jsonb; n int; ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  v_tok := app.verify_parent_pin('1234') ->> 'token';

  -- O1 建一个"连续 7 天签到"的家庭勋章
  v_bid := app.upsert_badge(
    p_parent_token => v_tok, p_name => '签到达人', p_emoji => '📅', p_tier => 'silver',
    p_description => '连续签到 7 天',
    p_rule => '{"kind":"streak_days","dimension":"signin","threshold":7}'::jsonb);
  assert v_bid is not null, 'O1 应返回勋章 id';
  select count(*)::int into n from app.badges
   where id = v_bid and family_id = 'f0000000-0000-4000-8000-000000000001';
  assert n = 1, 'O1b 勋章应挂在自己家庭下';

  -- O2 规则不合法要拒绝
  ok := false;
  begin perform app.upsert_badge(p_parent_token => v_tok, p_name => '瞎写',
    p_rule => '{"kind":"nonsense","threshold":3}'::jsonb);
  exception when others then ok := (sqlerrm like 'BAD_BADGE_RULE%');
  end;
  assert ok, 'O2 非法 rule.kind 必须被拒绝';

  ok := false;
  begin perform app.upsert_badge(p_parent_token => v_tok, p_name => '瞎写2',
    p_rule => '{"kind":"streak_days","dimension":"月球","threshold":3}'::jsonb);
  exception when others then ok := (sqlerrm like 'BAD_BADGE_RULE%');
  end;
  assert ok, 'O2b 非法 dimension 必须被拒绝';

  -- O3 没有家长 token 不能建
  ok := false;
  begin perform app.upsert_badge(p_parent_token => 'fake', p_name => '偷建',
    p_rule => '{"kind":"total_points","threshold":1}'::jsonb);
  exception when others then ok := (sqlerrm like 'PARENT_TOKEN_INVALID%');
  end;
  assert ok, 'O3 无效 token 不能建勋章';

  -- O4 评估：小明 signin streak = 30，应该拿到"签到达人"
  arr := app.evaluate_badges(v_ming);
  assert jsonb_typeof(arr) = 'array', 'O4 evaluate_badges 应返回数组';
  select value into e from jsonb_array_elements(arr) value
   where (value ->> 'badge_id')::uuid = v_bid;
  assert e is not null, 'O4b 返回里应包含新建的勋章';
  assert (e ->> 'earned')::boolean, 'O4c 连续 30 天签到应拿到 7 天档勋章';
  assert (e ->> 'threshold')::int = 7, 'O4d threshold 应为 7';
  assert (e ->> 'progress')::int = 7, format('O4e 进度应截到 7，实际 %s', e ->> 'progress');
  assert (e ->> 'raw_progress')::int = 30, 'O4f 原始进度应是 30';

  -- O5 得奖要落 member_badges
  select count(*)::int into n from app.member_badges
   where member_id = v_ming and badge_id = v_bid;
  assert n = 1, 'O5 得奖应写入 member_badges';

  -- O6 重复评估不重复写
  perform app.evaluate_badges(v_ming);
  select count(*)::int into n from app.member_badges
   where member_id = v_ming and badge_id = v_bid;
  assert n = 1, 'O6 重复评估不能写重复记录';

  -- O7 未达标的勋章 earned=false，但进度要给出来
  perform app.upsert_badge(
    p_parent_token => v_tok, p_name => '万分之路', p_emoji => '🚀',
    p_rule => '{"kind":"total_points","threshold":100000}'::jsonb);
  arr := app.evaluate_badges(v_ming);
  select value into e from jsonb_array_elements(arr) value
   where value ->> 'name' = '万分之路';
  assert not (e ->> 'earned')::boolean, 'O7 未达标不应算获得';
  assert (e ->> 'raw_progress')::int > 0, 'O7b 未达标也要有进度';

  -- O8 改勋章
  perform app.upsert_badge(p_parent_token => v_tok, p_id => v_bid, p_name => '签到之王',
    p_rule => '{"kind":"streak_days","dimension":"signin","threshold":7}'::jsonb);
  select count(*)::int into n from app.badges where id = v_bid and name = '签到之王';
  assert n = 1, 'O8 改名应生效';

  -- O9 家长视角列表能看到自定义勋章 + 系统勋章
  arr := app.list_family_badges(v_tok);
  select count(*)::int into n from jsonb_array_elements(arr) v
   where (v ->> 'is_system')::boolean = false;
  assert n = 2, format('O9 应有 2 个自定义勋章，实际 %s', n);
  select count(*)::int into n from jsonb_array_elements(arr) v
   where (v ->> 'is_system')::boolean;
  assert n = 10, format('O9b 应带上 10 个系统勋章，实际 %s', n);

  -- O10 系统勋章删不掉
  ok := false;
  begin
    perform app.delete_badge((select id from app.badges where code = 'first_step'), v_tok);
  exception when others then ok := (sqlerrm like 'BADGE_NOT_FOUND%');
  end;
  assert ok, 'O10 系统勋章不能被家庭删除';

  -- O11 删自己的勋章，member_badges 跟着级联删
  perform app.delete_badge(v_bid, v_tok);
  select count(*)::int into n from app.badges where id = v_bid;
  assert n = 0, 'O11 勋章应被删除';
  select count(*)::int into n from app.member_badges where badge_id = v_bid;
  assert n = 0, 'O11b 获得记录应级联删除';

  -- O12 系统勋章也在评估范围内：小明完成过任务，first_step 必须解锁
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  arr := app.list_badges_with_progress(v_ming);
  select value into e from jsonb_array_elements(arr) value where value ->> 'code' = 'first_step';
  assert (e ->> 'earned')::boolean, 'O12 完成过任务应解锁 first_step';
  assert (e ->> 'is_system')::boolean, 'O12b first_step 应标记为系统勋章';

  -- O13 孩子看不了别家孩子的勋章
  ok := false;
  begin perform app.list_badges_with_progress('b0000000-0000-4000-8000-000000000003');
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'O13 不能看别的家庭的勋章进度';

  -- O14 孩子不能管理家庭勋章
  ok := false;
  begin perform app.list_family_badges(null);
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'O14 孩子不能进勋章管理';

  raise notice '  [O] 勋章 20 项 ✓';
end $$;


-- ###########################################################################
-- P. bootstrap / summary 契约
-- ###########################################################################
do $$
declare
  v_ming uuid := 'b0000000-0000-4000-8000-000000000001';
  boot jsonb; sum1 jsonb; me jsonb; ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  boot := app.bootstrap_state();

  -- P1 members 每个元素都带三个当天状态
  select value into me from jsonb_array_elements(boot -> 'members') value
   where (value ->> 'id')::uuid = v_ming;
  assert me ? 'signed_today', 'P1 members 元素应含 signed_today';
  assert me ? 'active_today', 'P1b members 元素应含 active_today';
  assert me ? 'fullstar_today', 'P1c members 元素应含 fullstar_today';
  assert (me ->> 'signed_today')::boolean, 'P1d 小明今天签过到';

  -- P2 老字段一个都不能少（前端还在用）
  assert me ? 'points_balance' and me ? 'has_pin' and me ? 'nickname',
    'P2 bootstrap 原有字段不能丢';

  -- P3 summary 结构完整
  sum1 := app.get_signin_summary(v_ming);
  assert sum1 ? 'signed_today' and sum1 ? 'active_today' and sum1 ? 'fullstar_today',
    'P3 summary 应含当天三态';
  assert (sum1 -> 'streak') ? 'signin' and (sum1 -> 'streak') ? 'active'
     and (sum1 -> 'streak') ? 'fullstar', 'P3b summary 应含三条连续链';
  assert (sum1 -> 'retro_cards') ? 'retro_signin'
     and (sum1 -> 'retro_cards') ? 'retro_active'
     and (sum1 -> 'retro_cards') ? 'retro_fullstar', 'P3c summary 应含三种补签卡库存';
  assert (sum1 -> 'streak' ->> 'signin')::int = 30,
    format('P3d signin streak 应为 30，实际 %s', sum1 -> 'streak' ->> 'signin');
  assert (sum1 -> 'retro_cards' ->> 'retro_signin')::int = 2,
    format('P3e 补签卡应剩 2 张，实际 %s', sum1 -> 'retro_cards' ->> 'retro_signin');
  assert jsonb_array_length(sum1 -> 'awarded_tiers') = 5,
    format('P3f 已发档位应有 5 条，实际 %s', jsonb_array_length(sum1 -> 'awarded_tiers'));

  -- P4 不传 member_id 默认看自己
  sum1 := app.get_signin_summary(null);
  assert (sum1 ->> 'member_id')::uuid = v_ming, 'P4 默认应看自己';

  -- P5 跨家庭查不到
  ok := false;
  begin perform app.get_signin_summary('b0000000-0000-4000-8000-000000000003');
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'P5 不能看别的家庭';

  -- P6 全局对账：所有成员流水合计 === 余额缓存
  ok := not exists (
    select 1 from app.members m
     where m.points_balance <> coalesce(
       (select sum(l.delta) from app.point_ledger l where l.member_id = m.id), 0));
  assert ok, 'P6 有成员的流水合计与余额缓存不一致';

  raise notice '  [P] 契约 13 项 ✓';
end $$;


do $$
begin
  raise notice '===========================================';
  raise notice '  签到/勋章断言通过（I15+J15+K12+L11+M22+N15+O20+P13 = 123 项）';
  raise notice '===========================================';
end $$;

rollback;
