-- 复现「创建家庭 → 拿邀请码 → 另一身份加入」真实链路（前端 E2E 覆盖盲区）。
-- 包在 begin; ... rollback; 里，每次全新内存库。
begin;

do $$
declare
  v_dad   jsonb;
  v_code  text;
  v_join  jsonb;
  v_cnt   int;
begin
  -- ① 爸爸身份创建家庭（user_id 用与 test_expand 一致的固件）
  perform set_config('request.jwt.claims',
    '{"sub":"2a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  select app.create_family('复现测试家庭', '爸爸', '🙂', null) into v_dad;
  v_code := v_dad ->> 'child_invite_code';
  raise notice '✓ create_family 成功，child_invite_code=% parent_invite_code=%',
    v_code, v_dad ->> 'parent_invite_code';
  assert v_code is not null and length(v_code) = 6, '邀请码应生成 6 位';

  -- ② 邀请码是否真的落库（直接查 invites 表）
  select count(*) into v_cnt from app.invites where code = v_code;
  assert v_cnt = 1, '邀请码应写入 invites 表，实际 ' || v_cnt;
  raise notice '✓ invites 表中该码存在（count=%）', v_cnt;

  -- ③ 小明身份（另一 user_id）用 child 邀请码加入
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  select app.join_family(v_code, '小明', '👦') into v_join;
  raise notice '✓ join_family 成功，role=% member_id=%',
    v_join ->> 'role', v_join ->> 'member_id';
  assert v_join ->> 'role' = 'child', '加入的应是孩子身份';

  -- ④ 小明确实在 members 表
  select count(*) into v_cnt
    from app.members where user_id = '3a333333-3333-3333-3333-333333333333';
  assert v_cnt = 1, '小明应已入家庭成员，实际 ' || v_cnt;
  raise notice '✓ 断言通过：小明已在家庭成员表';

  -- ⑤ 反例：用 parent 邀请码 + 同一小明身份再加入应报 ALREADY_IN_FAMILY（已属于家庭）
  begin
    perform app.join_family(v_dad ->> 'parent_invite_code', '小明2', '👧');
    assert false, '已入家庭不应能再次 join';
  exception when others then
    raise notice '✓ 已入家庭重复 join 被正确拒绝：%', sqlerrm;
  end;
end $$;

rollback;
