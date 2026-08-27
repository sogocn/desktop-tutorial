-- =============================================================================
-- test_cross_account.sql —— 跨账号端到端联调（严过关 / QA）
-- -----------------------------------------------------------------------------
-- 三个身份（爸爸 / 小明 / 小红）依次驱动真实 SQL 业务函数，证明核心闭环成立：
--   家长派任务 → 孩子查看并完成并打卡 → 孩子领取奖励 →
--   家长 PIN 审批通过/驳回 → 跨账号数据隔离 → 积分流水与余额对账
--
-- 整个脚本包在一个事务里，最后 ROLLBACK，不会留下任何数据（每次运行都是全新内存库）。
-- 运行：node scripts/run-e2e.mjs
--
-- 身份固件（family '11111111-1111-1111-1111-111111111111'）：
--   爸爸(parent)：user_id='2a222222-...'  member_id='22222222-...'
--   小明(child)：user_id='3a333333-...'  member_id='33333333-...'
--   小红(child)：user_id='4a444444-...'  member_id='44444444-...'
-- 身份切换套路：perform set_config('request.jwt.claims',
--   '{"sub":"<user_id>","role":"authenticated"}', true);
-- 注意：跨 DO 块不共享变量；本文件用"按条件回查"恢复 id（任务/兑换各只有一条可辨认）。
-- =============================================================================

begin;


-- ###########################################################################
-- SETUP：固定家庭 / 成员 / 商城物品 / 隔壁家庭，并由爸爸派一个给小明的任务
-- ###########################################################################
do $$
declare
  r jsonb;
  v_tid uuid;
begin
  -- 家庭 1（测试之家）
  insert into app.families (id, name, timezone, day_cutoff_hour)
  values ('11111111-1111-1111-1111-111111111111', '测试之家', 'Asia/Shanghai', 0);

  -- 爸爸(parent) / 小明(child) / 小红(child)
  insert into app.members (id, family_id, user_id, nickname, role) values
    ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
     '2a222222-2222-2222-2222-222222222222', '爸爸', 'parent'),
    ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
     '3a333333-3333-3333-3333-333333333333', '小明', 'child'),
    ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111',
     '4a444444-4444-4444-4444-444444444444', '小红', 'child');

  -- 商城物品（家长维护）：现金(rate, 100分=1元, 需审批) + 冰淇淋(fixed 30分, 需审批)
  insert into app.reward_items
    (id, family_id, name, emoji, pricing_mode, rate_points, unit_label,
     min_quantity, step_quantity, requires_approval, active)
  values
    ('77777777-7777-7777-7777-777777777701', '11111111-1111-1111-1111-111111111111',
     '现金', '💰', 'rate', 100, '元', 1, 1, true, true);
  insert into app.reward_items
    (id, family_id, name, emoji, pricing_mode, price_points,
     min_quantity, step_quantity, requires_approval, active)
  values
    ('77777777-7777-7777-7777-777777777702', '11111111-1111-1111-1111-111111111111',
     '冰淇淋', '🍦', 'fixed', 30, 1, 1, true, true);

  -- 隔壁家庭（跨账号隔离目标）：一个完全不同 family_id 的任务/成员
  insert into app.families (id, name, timezone)
  values ('f2000000-0000-0000-0000-000000000002', '隔壁之家', 'Asia/Shanghai');
  insert into app.members (id, family_id, user_id, nickname, role) values
    ('f2b00000-0000-0000-0000-000000000002', 'f2000000-0000-0000-0000-000000000002',
     'f2a00000-0000-0000-0000-000000000002', '隔壁爸爸', 'parent'),
    ('f2d00000-0000-0000-0000-000000000003', 'f2000000-0000-0000-0000-000000000002',
     'f2c00000-0000-0000-0000-000000000003', '隔壁小红', 'child');
  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence, starts_on,
     completion_points, checkin_points, checkin_daily_limit)
  values
    ('f2e00000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000002',
     'f2d00000-0000-0000-0000-000000000003', 'f2b00000-0000-0000-0000-000000000002',
     '隔壁每日阅读', 'recurring', '{"freq":"daily"}', '2026-03-02', 5, 0, 1);

  -- 爸爸（parent）身份：派一个给小明的每日任务
  -- 完成 5 分 / 打卡每次 2 分 / 每日上限 3 次
  perform set_config('request.jwt.claims',
    '{"sub":"2a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  r := app.create_task(
    p_assignee_id        => '33333333-3333-3333-3333-333333333333',
    p_title              => '每日阅读打卡',
    p_schedule_kind      => 'recurring',
    p_recurrence         => '{"freq":"daily"}'::jsonb,
    p_starts_on          => '2026-03-02',
    p_completion_points  => 5,
    p_checkin_points     => 2,
    p_checkin_limit      => 3);

  assert (r->>'task_id') is not null, 'SETUP 爸爸派任务应返回 task_id';
  raise notice '✓ SETUP 家庭/成员/商城/隔壁家庭 + 爸爸派任务';
end $$;


-- ###########################################################################
-- FLOW B（孩子）：小明查看 → 完成 → 打卡（受每日上限约束）→ 余额对账
-- ###########################################################################
do $$
declare
  r jsonb; n int; v_tid uuid; v_bal int; ok boolean;
begin
  -- 回查爸爸刚派给小明的任务
  select id into v_tid from app.tasks
   where assignee_id = '33333333-3333-3333-3333-333333333333'
     and created_by  = '22222222-2222-2222-2222-222222222222'
     and title       = '每日阅读打卡';
  assert v_tid is not null, 'B0 应能回查到派给小明的任务';

  -- 切到小明
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

  -- B1 日历能查到该任务
  select count(*) into n from app.get_calendar('2026-03-01','2026-03-31') where task_id = v_tid;
  assert n >= 1, format('B1 小明日历应能看到任务，实际 %s 行', n);

  -- B2 完成任务：+5 分，余额更新
  r := app.complete_occurrence(v_tid, '2026-03-10');
  assert (r->>'points_awarded')::int = 5,
         format('B2 完成应加 5 分，实际 %s', r->>'points_awarded');
  assert (r->>'balance')::int = 5,
         format('B2b 余额应为 5，实际 %s', r->>'balance');

  -- B3 打卡 +2 分（每日上限 3 次）
  r := app.record_checkin(v_tid, '2026-03-10');
  assert (r->>'points_awarded')::int = 2,
         format('B3 首次打卡应加 2 分，实际 %s', r->>'points_awarded');
  r := app.record_checkin(v_tid, '2026-03-10');
  r := app.record_checkin(v_tid, '2026-03-10');

  -- B4 第 4 次打卡应被拒（超出每日上限 3 次）
  ok := false;
  begin
    perform app.record_checkin(v_tid, '2026-03-10');
  exception when others then ok := (sqlerrm like 'CHECKIN_LIMIT_REACHED%');
  end;
  assert ok, 'B4 超出每日打卡上限(3)必须被拒绝';

  -- B5 余额 = 完成 5 + 打卡 2×3 = 11
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_bal = 11, format('B5 余额应为 11，实际 %s', v_bal);

  -- B6 流水账：完成 1 条 + 打卡 3 条（每条 +2）
  select count(*) into n from app.point_ledger
   where source_type = 'completion'
     and member_id   = '33333333-3333-3333-3333-333333333333';
  assert n = 1, format('B6 完成流水应 1 条，实际 %s', n);
  select count(*) into n from app.point_ledger
   where source_type = 'checkin' and delta = 2
     and member_id   = '33333333-3333-3333-3333-333333333333';
  assert n = 3, format('B6b 打卡流水应 3 条，实际 %s', n);

  raise notice '✓ FLOW B 孩子查看/完成/打卡(限上限)/余额';
end $$;


-- ###########################################################################
-- FLOW C（孩子领奖）：小明兑换需审批的现金 → pending，余额预扣
-- ###########################################################################
do $$
declare
  r jsonb; n int; v_bal int;
begin
  -- 垫分：给小明足够积分（manual 来源不受每日上限约束）
  perform app._post_ledger(
    '33333333-3333-3333-3333-333333333333', 300, 'manual',
    'bbbb0000-0000-0000-0000-000000000001', 0, '测试垫分', null,
    '22222222-2222-2222-2222-222222222222');
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_bal = 311, format('C0 垫分后余额应为 311（11+300），实际 %s', v_bal);

  -- 切到小明
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

  -- C1 兑换现金 2 元 = 200 分，需审批 → pending
  r := app.redeem('77777777-7777-7777-7777-777777777701', 2);
  assert (r->>'pending')::boolean = true, 'C1 现金需审批，应为 pending';
  assert (r->>'points_spent')::int = 200,
         format('C2 应扣 200 分，实际 %s', r->>'points_spent');

  -- C3 余额已预扣（避免同一笔分兑两样东西）
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_bal = 111, format('C3 预扣后余额应为 111，实际 %s', v_bal);

  -- C4 redemptions 表有 pending 行
  select count(*) into n from app.redemptions
   where member_id = '33333333-3333-3333-3333-333333333333'
     and item_id   = '77777777-7777-7777-7777-777777777701'
     and status    = 'pending';
  assert n = 1, format('C4 redemptions 应有 1 条 pending 行，实际 %s', n);

  -- C5 扣分留下流水账（余额只是缓存，流水才是事实）
  select count(*) into n from app.point_ledger
   where source_type = 'redemption'
     and member_id   = '33333333-3333-3333-3333-333333333333'
     and source_id   = (select id from app.redemptions
                         where member_id = '33333333-3333-3333-3333-333333333333'
                           and item_id   = '77777777-7777-7777-7777-777777777701')
     and delta       = -200;
  assert n = 1, format('C5 应有一条 -200 流水，实际 %s 条', n);

  raise notice '✓ FLOW C 孩子领奖(需审批→pending，余额预扣)';
end $$;


-- ###########################################################################
-- FLOW D（家长审批）：PIN 验证 → 通过(现金) / 驳回(冰淇淋) → 流水对账
-- ###########################################################################
do $$
declare
  r jsonb; n int; v_token text;
  v_rid_cash uuid; v_rid_ice uuid; v_bal int; v_sum int;
begin
  -- 小明再兑一个冰淇淋 1 个 = 30 分（另一个物品，用于驳回分支）
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  r := app.redeem('77777777-7777-7777-7777-777777777702', 1);
  assert (r->>'pending')::boolean = true, 'D0a 冰淇淋需审批应为 pending';
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_bal = 81, format('D0b 再兑 30 分后余额应为 81，实际 %s', v_bal);

  -- 切到爸爸：设 PIN → 验证 → 拿 token
  perform set_config('request.jwt.claims',
    '{"sub":"2a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  perform app.set_pin('4321');
  r := app.verify_parent_pin('4321');
  assert (r->>'token') is not null, 'D1 应返回家长会话 token';
  v_token := r->>'token';

  -- 回查两笔兑换
  select id into v_rid_cash from app.redemptions
   where member_id = '33333333-3333-3333-3333-333333333333'
     and item_id   = '77777777-7777-7777-7777-777777777701';
  select id into v_rid_ice from app.redemptions
   where member_id = '33333333-3333-3333-3333-333333333333'
     and item_id   = '77777777-7777-7777-7777-777777777702';
  assert v_rid_cash is not null and v_rid_ice is not null, 'D2 应能回查两笔兑换';

  -- 通过分支：现金 approved → 积分保持扣除（余额不变，仍 81）
  r := app.decide_redemption(v_rid_cash, 'approved', v_token);
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_bal = 81, format('D3 批准后积分应保持扣除(81)，实际 %s', v_bal);

  -- 驳回分支：冰淇淋 rejected → 反向记账 +30，余额退回 111
  r := app.decide_redemption(v_rid_ice, 'rejected', v_token);
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_bal = 111, format('D4 驳回退还后余额应为 111，实际 %s', v_bal);

  -- D5 驳回用反向记账（+30）。注意：反向记账行的 source_type 是 'reversal'，
  -- 其 reverses_id 指向原扣分流水；原扣分记录（source_type='redemption'）保留。
  select count(*) into n from app.point_ledger
   where entry_kind = 'reversal' and delta = 30
     and member_id  = '33333333-3333-3333-3333-333333333333';
  assert n = 1, format('D5 应有一条 +30 反向记录，实际 %s 条', n);
  select count(*) into n from app.point_ledger
   where source_type = 'redemption' and source_id = v_rid_ice and delta = -30;
  assert n = 1, format('D5b 原始扣分记录必须保留，实际 %s 条', n);

  -- D6 对账：sum(point_ledger delta) == members.points_balance（全系统收口）
  -- 流水：完成+5 / 打卡+6 / 垫分+300 / 现金-200 / 冰淇淋-30 / 冰淇淋reversal+30 = 111
  select coalesce(sum(delta), 0) into v_sum from app.point_ledger
   where member_id = '33333333-3333-3333-3333-333333333333';
  select points_balance into v_bal
    from app.members where id = '33333333-3333-3333-3333-333333333333';
  assert v_sum = v_bal,
         format('D6 流水合计 %s 应等于余额缓存 %s', v_sum, v_bal);

  raise notice '✓ FLOW D 家长 PIN 审批(通过/驳回) + 流水对账';
end $$;


-- ###########################################################################
-- FLOW E（隔离）：孩子不能给其他成员派任务；看不到隔壁家庭数据
-- ###########################################################################
do $$
declare
  n int; ok boolean; v_tid uuid;
begin
  select id into v_tid from app.tasks
   where assignee_id = '33333333-3333-3333-3333-333333333333'
     and created_by  = '22222222-2222-2222-2222-222222222222'
     and title       = '每日阅读打卡';

  -- 切到小明
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

  -- E1 孩子给其他成员（爸爸）派任务 → 必须抛 FORBIDDEN
  ok := false;
  begin
    perform app.create_task(
      p_assignee_id       => '22222222-2222-2222-2222-222222222222',
      p_title             => '替爸爸干活',
      p_completion_points => 1);
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'E1 孩子不能给其他成员（爸爸）派任务';

  -- E2 跨账号隔离：小明(家庭1)以隔壁孩子 member_id 查询，仍看不到隔壁家庭的任务
  select count(*) into n from app.get_calendar('2026-03-01','2026-03-31',
    'f2d00000-0000-0000-0000-000000000003');
  assert n = 0, format('E2 小明不应看到隔壁家庭任务，实际 %s 行', n);

  -- E2b 小明自己家庭的任务仍然可见（隔离不等于盲）
  select count(*) into n from app.get_calendar('2026-03-01','2026-03-31') where task_id = v_tid;
  assert n >= 1, 'E2b 小明应能看到自己家庭的任务';

  raise notice '✓ FLOW E 跨账号数据隔离';
end $$;


do $$
begin
  raise notice '===========================================';
  raise notice '  跨账号 E2E 联调全部断言通过';
  raise notice '===========================================';
end $$;

rollback;
