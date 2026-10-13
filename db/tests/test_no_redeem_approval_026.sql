-- =============================================================================
-- test_no_redeem_approval_026.sql —— 取消积分兑换审批、兑换即时生效（026）
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在一个事务里，最后 ROLLBACK。
-- =============================================================================

begin;

insert into app.families (id, name, timezone, day_cutoff_hour) values
  ('f0000000-0000-4000-8000-000000000026', '免审批之家', 'Asia/Shanghai', 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000026', 'f0000000-0000-4000-8000-000000000026',
   'a1000000-0000-4000-8000-000000000026', '爸026', 'parent'),
  ('b0000000-0000-4000-8000-000000000026', 'f0000000-0000-4000-8000-000000000026',
   'b1000000-0000-4000-8000-000000000026', '娃026', 'child');

do $$
begin
  perform app.seed_reward_items('f0000000-0000-4000-8000-000000000026');
end $$;

-- ---------------------------------------------------------------------------
-- N1 默认免审批：新建商品不写 requires_approval 时应当是 false
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select column_default into v_def
    from information_schema.columns
   where table_schema = 'app' and table_name = 'reward_items'
     and column_name = 'requires_approval';
  assert v_def = 'false', format('N1 requires_approval 默认应为 false，实际 %s', v_def);
  raise notice '✓ N1 商品默认免审批';
end $$;

-- ---------------------------------------------------------------------------
-- N2 播种出来的 4 个商品（现金 + 3 张补卡）全部免审批
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid uuid := 'f0000000-0000-4000-8000-000000000026';
  n int;
begin
  select count(*) into n from app.reward_items
   where family_id = v_fid and requires_approval;
  assert n = 0, format('N2 播种商品应全部免审批，实际仍有 %s 条需审批', n);

  select count(*) into n from app.reward_items where family_id = v_fid;
  assert n = 4, format('N2b 应播种 4 个商品，实际 %s', n);
  raise notice '✓ N2 播种商品全部免审批（现金 + 3 张补卡）';
end $$;

-- ---------------------------------------------------------------------------
-- N3 兑换即时生效：状态直接是 approved，不再进待批队列
-- N4 扣分 / 发卡行为不变（只是不再 pending）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000026';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000026';
  v_cash  uuid;
  v_card  uuid;
  r       jsonb;
  v_rid   uuid;
  v_bal   int := 500;
  v_st    text;
  n       int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000026","role":"authenticated"}', true);
  update app.members set points_balance = v_bal where id = v_kid;

  select id into v_cash from app.reward_items
   where family_id = v_fid and item_kind = 'cash';
  select id into v_card from app.reward_items
   where family_id = v_fid and card_kind = 'retro_signin';

  -- N3 现金（10 分 = 1 元）兑 2 元 = 20 分
  r := app.redeem(v_cash, 2);
  v_rid := (r->>'redemption_id')::uuid;
  select status into v_st from app.redemptions where id = v_rid;
  assert v_st = 'approved', format('N3 免审批兑换应直接 approved，实际 %s', v_st);
  assert (r->>'pending')::boolean = false, 'N3b 返回值 pending 应为 false';
  assert r->>'message' = '兑换成功', format('N3c 文案应为兑换成功，实际 %s', r->>'message');
  assert (r->>'points_spent')::int = 20, format('N3d 应扣 20 分，实际 %s', r->>'points_spent');

  -- N4 待批队列里不该有它
  select count(*) into n from app.redemptions
   where family_id = v_fid and status = 'pending';
  assert n = 0, format('N4 不该再有 pending 兑换，实际 %s 条', n);

  -- N5 补卡兑换后立刻到手（30 分）
  r := app.redeem(v_card, 1);
  assert (select qty from app.member_cards
           where member_id = v_kid and kind = 'retro_signin') = 1,
    'N5 补签卡应立刻到账 1 张';
  assert (select points_balance from app.members where id = v_kid) = v_bal - 20 - 30,
    format('N5b 余额应为 %s，实际 %s', v_bal - 50,
           (select points_balance from app.members where id = v_kid));

  raise notice '✓ N3 兑换即时生效（approved，不再 pending）';
  raise notice '✓ N5 扣分与发卡行为不变';
end $$;

-- ---------------------------------------------------------------------------
-- N6 事后撤销：家长仍能把已生效的兑换作废，分和卡一起退
-- N7 撤销是终态，不能重复撤销
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000026';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000026';
  v_rid   uuid;
  v_st    text;
  ok      boolean;
begin
  -- 孩子刚兑的那张补签卡。
  -- ⚠️ 不能按 requested_at desc 取"最后一笔"：同一事务里 now() 对所有行都相同，
  -- 排序会并列、取到哪条全看运气（016 的挑战查询踩过同一个坑）。按商品类型定位才稳。
  select r.id into v_rid
    from app.redemptions r
    join app.reward_items i on i.id = r.item_id
   where r.member_id = v_kid and i.card_kind = 'retro_signin'
   limit 1;

  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000026","role":"authenticated"}', true);

  perform app.decide_redemption(v_rid, 'cancelled', null);

  select status into v_st from app.redemptions where id = v_rid;
  assert v_st = 'cancelled', format('N6 撤销后状态应为 cancelled，实际 %s', v_st);
  assert (select qty from app.member_cards
           where member_id = v_kid and kind = 'retro_signin') = 0,
    'N6b 撤销后补卡应收回到 0';
  -- 500 - 20（现金）- 30（补签卡）+ 30（撤销退回）= 480
  assert (select points_balance from app.members where id = v_kid) = 480,
    format('N6c 撤销后应退回 30 分（480），实际 %s',
           (select points_balance from app.members where id = v_kid));

  -- N7 终态不能再动
  ok := false;
  begin
    perform app.decide_redemption(v_rid, 'cancelled', null);
  exception when others then ok := (sqlerrm like 'ALREADY_DECIDED%');
  end;
  assert ok, 'N7 已撤销的兑换不能再撤销';

  raise notice '✓ N6 家长可撤销已生效的兑换（退分 + 收卡）';
  raise notice '✓ N7 撤销为终态，不可重复';
end $$;

-- ---------------------------------------------------------------------------
-- N8 能力保留：显式 requires_approval = true 的商品仍走 pending（无 UI 可设，
--    仅作兼容与回归保护，别让 026 把这条路径悄悄删掉）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000026';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000026';
  v_item  uuid := 'e1000000-0000-4000-8000-000000000026';
  r       jsonb;
  v_rid   uuid;
  v_st    text;
begin
  insert into app.reward_items
    (id, family_id, name, emoji, pricing_mode, price_points,
     min_quantity, step_quantity, requires_approval, active)
  values
    (v_item, v_fid, '大件玩具', '🧸', 'fixed', 50, 1, 1, true, true);

  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000026","role":"authenticated"}', true);
  r := app.redeem(v_item, 1);
  v_rid := (r->>'redemption_id')::uuid;
  select status into v_st from app.redemptions where id = v_rid;
  assert v_st = 'pending', format('N8 显式需审批的商品仍应 pending，实际 %s', v_st);
  assert r->>'message' = '已提交，等家长确认',
    format('N8b 文案应提示等待确认，实际 %s', r->>'message');

  -- 审批通过仍照旧
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000026","role":"authenticated"}', true);
  perform app.decide_redemption(v_rid, 'approved', null);
  select status into v_st from app.redemptions where id = v_rid;
  assert v_st = 'approved', format('N8c 审批通过应为 approved，实际 %s', v_st);

  raise notice '✓ N8 显式需审批的商品仍走原审批路径（能力保留）';
end $$;

rollback;
