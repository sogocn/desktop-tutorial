-- =============================================================================
-- test_no_pin_ops_014.sql —— 014 家长操作免 PIN/token 直通
-- =============================================================================
-- 014 把 _parent_guard 的"没传 token + 设过 PIN 就抛 PARENT_TOKEN_INVALID"
-- 分支去掉了。本文件断言：
--   A1 设过 PIN 的家长不打 token 直接 adjust_member_points 成功
--   A2 设过 PIN 的家长不打 token 直接 decide_redemption 成功
--   A3 孩子不打 token 调分一律 FORBIDDEN（角色闸门仍在）
--   A4 家长带无效 token 仍被 PARENT_TOKEN_INVALID 拒绝（token 严格分支未改）
--   A5 家长带有效 token 仍成功（regression：PIN 登录链路完整保留）
--   A6 孩子免 token 审批兑换 → FORBIDDEN（require_parent 直调者的角色闸门）
--   A7 家长免 token add_member 成功（require_parent 直调者放行）
--
-- A6/A7 针对的是 014 的另一半改动：require_parent 本身。decide_redemption /
-- revoke_ledger_entry / add_member 是直调 require_parent 的，光改 _parent_guard
-- 管不到，这两个断言就是守这条链路的。
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- =============================================================================

begin;

-- 固定数据：一家两成员 + 一个需审批的奖励物品
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('e0000000-0000-4000-8000-000000000001', '免PIN之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('e0000000-0000-4000-8000-00000000000a', 'e0000000-0000-4000-8000-000000000001',
   'e0000000-0000-4000-8000-00000000000b', '爸', 'parent'),
  ('e0000000-0000-4000-8000-00000000000c', 'e0000000-0000-4000-8000-000000000001',
   'e0000000-0000-4000-8000-00000000000d', '娃', 'child');

insert into app.reward_items
  (id, family_id, name, emoji, pricing_mode, price_points,
   min_quantity, step_quantity, requires_approval, active)
values
  ('e0000000-0000-4000-8000-00000000000e', 'e0000000-0000-4000-8000-000000000001',
   '玩具', '🧸', 'fixed', 50, 1, 1, true, true);

-- 切到家长：免 token 给娃 +500 分（014 新行为，这就是后续 redemptions 的本钱）
-- 再设上 PIN（让 pin_hash 非空），最后让娃兑一件需审批的玩具 → pending
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  perform app.adjust_member_points(
    p_parent_token => null,
    p_member_id    => 'e0000000-0000-4000-8000-00000000000c',
    p_delta        => 500,
    p_reason       => '初始预存');

  perform app.set_pin('0001');

  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  perform app.redeem('e0000000-0000-4000-8000-00000000000e', 1);
end $$;


-- A1 设过 PIN 的家长不打 token → adjust_member_points 成功
do $$
declare v_before int; v_after int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  select points_balance into v_before from app.members
    where id = 'e0000000-0000-4000-8000-00000000000c';
  perform app.adjust_member_points(
    p_parent_token => null,
    p_member_id    => 'e0000000-0000-4000-8000-00000000000c',
    p_delta        => 30,
    p_reason       => '免 token 赏');
  select points_balance into v_after from app.members
    where id = 'e0000000-0000-4000-8000-00000000000c';
  assert v_after = v_before + 30,
         format('A1 免 token 调分应成功，余额 %s → %s', v_before, v_after);
  raise notice '✓ A1 设过 PIN 的家长免 token adjust_member_points 成功';
end $$;


-- A2 设过 PIN 的家长不打 token → decide_redemption 成功
do $$
declare v_rid uuid; v_status text;
begin
  select id into v_rid from app.redemptions
    where member_id = 'e0000000-0000-4000-8000-00000000000c';
  assert v_rid is not null, 'A2 应能查到 pending 兑换';
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  perform app.decide_redemption(v_rid, 'approved', null);
  select status into v_status from app.redemptions where id = v_rid;
  assert v_status = 'approved',
         format('A2 免 token 审批应通过，实际 status=%s', v_status);
  raise notice '✓ A2 设过 PIN 的家长免 token decide_redemption 成功';
end $$;


-- A3 孩子不打 token 调分一律 FORBIDDEN（角色闸门仍在）
do $$
declare ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  ok := false;
  begin perform app.adjust_member_points(
    p_parent_token => null,
    p_member_id    => 'e0000000-0000-4000-8000-00000000000c',
    p_delta        => 999,
    p_reason       => '娃给自己发钱');
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'A3 娃免 token 调分必须 FORBIDDEN';
  raise notice '✓ A3 孩子免 token 调分被拒（角色闸门仍在）';
end $$;


-- A4 家长带无效 token 仍被 PARENT_TOKEN_INVALID 拒绝（token 严格分支未改）
do $$
declare ok boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  ok := false;
  begin perform app.adjust_member_points(
    p_parent_token => 'not-a-token',
    p_member_id    => 'e0000000-0000-4000-8000-00000000000c',
    p_delta        => 10,
    p_reason       => '伪造 token');
  exception when others then ok := (sqlerrm like 'PARENT_TOKEN_INVALID%');
  end;
  assert ok, 'A4 无效 token 必须 PARENT_TOKEN_INVALID';
  raise notice '✓ A4 无效 token 仍被拒（token 严格分支未改）';
end $$;


-- A5 家长带有效 token 仍成功（regression：PIN 登录链路完整保留）
do $$
declare v_tok text; v_before int; v_after int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  v_tok := app.verify_parent_pin('0001') ->> 'token';
  assert v_tok is not null, 'A5 应能拿到家长 token';
  select points_balance into v_before from app.members
    where id = 'e0000000-0000-4000-8000-00000000000c';
  perform app.adjust_member_points(
    p_parent_token => v_tok,
    p_member_id    => 'e0000000-0000-4000-8000-00000000000c',
    p_delta        => 20,
    p_reason       => '持 token 调分');
  select points_balance into v_after from app.members
    where id = 'e0000000-0000-4000-8000-00000000000c';
  assert v_after = v_before + 20,
         format('A5 持 token 调分应成功，余额 %s → %s', v_before, v_after);
  raise notice '✓ A5 家长带有效 token 仍可调分（regression 通过）';
end $$;


-- A6 孩子免 token 审批兑换 → FORBIDDEN（require_parent 直调者的角色闸门仍在）
do $$
declare v_rid uuid; ok boolean;
begin
  select id into v_rid from app.redemptions
    where member_id = 'e0000000-0000-4000-8000-00000000000c';
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  ok := false;
  begin perform app.decide_redemption(v_rid, 'approved', null);
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'A6 娃免 token 审批必须 FORBIDDEN';
  raise notice '✓ A6 孩子免 token 审批被拒（require_parent 角色闸门仍在）';
end $$;


-- A7 家长免 token add_member 成功（require_parent 直调者放行）
do $$
declare v_n int; v_before int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e0000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  select count(*)::int into v_before from app.members
    where family_id = 'e0000000-0000-4000-8000-000000000001';
  perform app.add_member('二宝', '🐣', 'child', null);
  select count(*)::int into v_n from app.members
    where family_id = 'e0000000-0000-4000-8000-000000000001';
  assert v_n = v_before + 1,
         format('A7 免 token add_member 应新增 1 人，%s → %s', v_before, v_n);
  raise notice '✓ A7 家长免 token add_member 成功（require_parent 直调者放行）';
end $$;


rollback;