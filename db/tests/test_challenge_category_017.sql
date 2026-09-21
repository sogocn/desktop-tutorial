-- =============================================================================
-- test_challenge_category_017.sql —— 挑战「按类互斥、可重复开始」
-- =============================================================================
-- 覆盖：
--   T1 同类互斥：已有 fullstar_21 进行中 → 再开 fullstar_45 被拒（CHALLENGE_ACTIVE）
--   T2 跨类并行：signin 类有一条进行中 → 仍能开满星类（反之亦然）
--   T3 索引兜底：同类硬插第二条 active → 唯一约束冲突（23505）
--   T4 可重复开始：挑战 succeeded 后，同类可以再开
--   T5 可重复开始 2：挑战 failed 后，同 kind 也可以再开
--   T6 读数：currents 每类一条 + specs 带 category/category_label/busy
--   T7 current 兼容字段：= currents 里优先 active 的那条
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- =============================================================================

begin;

insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0170000-0000-4000-8000-000000000001', '分类之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('f0170000-0000-4000-8000-00000000000a', 'f0170000-0000-4000-8000-000000000001',
   'f0170000-0000-4000-8000-00000000000b', '爸', 'parent'),
  ('f0170000-0000-4000-8000-00000000000c', 'f0170000-0000-4000-8000-000000000001',
   'f0170000-0000-4000-8000-00000000000d', '娃', 'child');

select app.seed_reward_items('f0170000-0000-4000-8000-000000000001');
update app.members set points_balance = 500
 where id = 'f0170000-0000-4000-8000-00000000000c';

do $$
declare
  v_family uuid := 'f0170000-0000-4000-8000-000000000001';
  v_child  uuid := 'f0170000-0000-4000-8000-00000000000c';
  v_cuid   text := 'f0170000-0000-4000-8000-00000000000d';
  v_today  date;
  v_state  jsonb;
  v_cid    uuid;
  ok       boolean;
  n        int;
begin
  v_today := app.family_today(v_family);
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  -- T1 同类互斥：21 天进行中 → 45 天（同为 fullstar 类）开不了
  perform app.start_challenge('fullstar_21');
  ok := false;
  begin
    perform app.start_challenge('fullstar_45');
  exception when others then ok := (sqlerrm like 'CHALLENGE_ACTIVE%');
  end;
  assert ok, 'T1 同类（都是连续满星）必须互斥：21 天进行中时 45 天应被拒';
  select count(*)::int into n from app.challenges where member_id = v_child and status = 'active';
  assert n = 1, format('T1 仍应只有 1 条进行中，实际 %s', n);
  raise notice '✓ T1 同类互斥：满星21 vs 满星45';

  -- T2 跨类并行：满星那条先结束（终局后才允许再开），签到类插一条进行中 →
  --    满星类仍能开（同一时间两个类各一条）
  update app.challenges set status = 'failed', decided_at = now()
   where member_id = v_child and category = 'fullstar' and status = 'active';
  insert into app.challenges (family_id, member_id, kind, category, started_on, ends_on, entry_fee)
  values (v_family, v_child, 'signin_7', 'signin', v_today, v_today + 6, 0);
  ok := true;
  begin
    perform app.start_challenge('fullstar_45');
  exception when others then ok := false;
  end;
  assert ok, 'T2 不同类应可并行：签到类进行中也要能开满星类';
  select count(*)::int into n from app.challenges where member_id = v_child and status = 'active';
  assert n = 2, format('T2 应同时进行 2 条（签到 + 满星），实际 %s', n);
  raise notice '✓ T2 跨类并行：签到类 + 满星类各一条进行中';

  -- T3 索引兜底：同类硬插第二条 active → 唯一约束冲突
  ok := false;
  begin
    insert into app.challenges (family_id, member_id, kind, category, started_on, ends_on, entry_fee)
    values (v_family, v_child, 'signin_21', 'signin', v_today, v_today + 20, 0);
  exception when unique_violation then ok := true;
  end;
  assert ok, 'T3 同类第二条 active 必须被唯一索引拦住';
  raise notice '✓ T3 索引兜底：(member_id, category) where active 生效';

  -- T6 读数：signin 类此刻没有规格（还没上线），读路径要优雅跳过而不是整段报错；
  --     规格齐全的类照常返回。并行的事实由上面的行数断言（n=2）保证。
  v_state := app.challenge_state();
  assert jsonb_array_length(v_state->'currents') = 1,
    format('T6 无规格的类应被跳过，只剩 1 条，实际 %s', v_state->'currents');
  assert (v_state->'currents'->0->>'category') = 'fullstar', 'T6 currents 应带 category';
  assert (v_state->'specs'->0->>'category') = 'fullstar', 'T6 specs 应带 category';
  assert (v_state->'specs'->0->>'category_label') = '连续满星', 'T6 specs 应带 category_label';
  assert (v_state->'specs'->0->>'busy')::boolean = true,
    'T6 fullstar 类进行中 → busy=true（前端禁用开启）';
  raise notice '✓ T6 currents 带 category/label，specs 带 busy；无规格的类被优雅跳过';

  -- T7 current 兼容字段指向进行中的那条
  assert (v_state->'current'->>'status') = 'active', 'T7 current 应为进行中那条';
  assert (v_state->'current'->>'category') is not null, 'T7 current 应带 category';
  raise notice '✓ T7 current 兼容字段 = 优先 active 的那条';

  -- T4 可重复开始：成功之后，同类还能再开
  select id into v_cid from app.challenges
   where member_id = v_child and category = 'fullstar' and status = 'active';
  update app.challenges set status = 'succeeded', decided_at = now()
   where id = v_cid;
  ok := true;
  begin
    perform app.start_challenge('fullstar_21');
  exception when others then ok := false;
  end;
  assert ok, 'T4 成功后同类应可再开';
  raise notice '✓ T4 重复开始：succeeded 后同类可再开';

  -- T5 失败之后，同一个 kind 也能再开
  select id into v_cid from app.challenges
   where member_id = v_child and category = 'fullstar' and status = 'active';
  update app.challenges set status = 'failed', decided_at = now()
   where id = v_cid;
  ok := true;
  begin
    perform app.start_challenge('fullstar_21');
  exception when others then ok := false;
  end;
  assert ok, 'T5 失败后同 kind 应可再开';
  ok := false;
  begin
    perform app.start_challenge('fullstar_21');
  exception when others then ok := (sqlerrm like 'CHALLENGE_ACTIVE%');
  end;
  assert ok, 'T5 重开后仍然同类唯一：再开第三次要被拒';
  raise notice '✓ T5 重复开始：failed 后同 kind 可再开，但同类仍唯一';
end $$;

rollback;
