-- =============================================================================
-- test_badge_total_points_028.sql —— 028：total_points 类勋章改为"累计获取"
-- =============================================================================
-- 覆盖：
--   T1 娃A：入账 +2500、消费 -2000 → 余额 500，但累计获取应为 2500
--        → 大富翁(2000)/小金库(500)应达成（旧口径按余额 500 会漏发，即修复点）
--   T2 娃B：+100 后 -100 撤销 → 余额 0，但累计获取仍计 +100（gross，撤销不扣减）
--        → 累计仅 100，小金库(500)不应达成
--
-- 说明：系统勋章(大富翁/小金库)本身带奖励分，首次获得会额外入账，这笔奖励分
--   也计入"累计获取"（它本来就是赚到的分）。为避免奖励分干扰断言，T1 在调用
--   evaluate_badges 之前先量一次 gross；T2 用独立成员（累计未达阈值、不触发奖励分）。
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- =============================================================================

begin;

-- child_daily_points_cap=0，且用 manual 来源调用 _post_ledger，避开每日上限与唯一约束
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap)
 values ('f0280000-0000-4000-8000-000000000001', '累计之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('f0280000-0000-4000-8000-00000000000c', 'f0280000-0000-4000-8000-000000000001',
   'f0280000-0000-4000-8000-00000000000d', '娃A', 'child'),
  ('f0280000-0000-4000-8000-00000000000e', 'f0280000-0000-4000-8000-000000000001',
   'f0280000-0000-4000-8000-00000000000f', '娃B', 'child');

do $$
declare
  v_a     uuid := 'f0280000-0000-4000-8000-00000000000c';
  v_b     uuid := 'f0280000-0000-4000-8000-00000000000e';
  v_bal   int;
  v_gross int;
  v_out   jsonb;
begin
  -- T1 娃A：入账 +2500、消费 -2000
  perform app._post_ledger(v_a, 2500, 'manual',
           'f0280000-0000-4000-8000-000000000010', 0, '测试入账', null, v_a);
  perform app._post_ledger(v_a, -2000, 'manual',
           'f0280000-0000-4000-8000-000000000011', 0, '测试消费', null, v_a);

  select points_balance into v_bal from app.members where id = v_a;
  assert v_bal = 500, format('T1 余额应为 500（2500-2000），实际 %s', v_bal);

  -- 累计获取（正向流水之和）：评估发勋章前先量一次，排除勋章奖励分干扰
  select coalesce(sum(delta), 0)::int into v_gross
    from app.point_ledger where member_id = v_a and delta > 0;
  assert v_gross = 2500, format('T1 累计获取应为 2500，实际 %s', v_gross);

  -- 关键修复点：余额只有 500，但累计获取 2500 → 大富翁(2000)/小金库(500)应达成
  v_out := app.evaluate_badges(v_a);
  assert exists (select 1 from jsonb_array_elements(v_out) e
                  where e->>'kind' = 'total_points' and (e->>'threshold')::int = 2000
                    and (e->>'earned')::boolean),
    'T1 大富翁(2000)应达成（旧口径按余额500会漏发）';
  assert exists (select 1 from jsonb_array_elements(v_out) e
                  where e->>'kind' = 'total_points' and (e->>'threshold')::int = 500
                    and (e->>'earned')::boolean),
    'T1 小金库(500)应达成';

  -- T2 娃B：+100 后 -100 撤销 → 余额 0，但累计获取仍计 +100（gross，撤销不扣减）
  perform app._post_ledger(v_b, 100, 'manual',
           'f0280000-0000-4000-8000-000000000012', 0, '测试再入账', null, v_b);
  perform app._post_ledger(v_b, -100, 'manual',
           'f0280000-0000-4000-8000-000000000013', 0, '测试撤销', null, v_b);
  select points_balance into v_bal from app.members where id = v_b;
  assert v_bal = 0, format('T2 余额应为 0，实际 %s', v_bal);
  select coalesce(sum(delta), 0)::int into v_gross
    from app.point_ledger where member_id = v_b and delta > 0;
  assert v_gross = 100, format('T2 累计获取应为 100（撤销不扣减），实际 %s', v_gross);
  v_out := app.evaluate_badges(v_b);
  assert exists (select 1 from jsonb_array_elements(v_out) e
                  where e->>'kind' = 'total_points' and (e->>'threshold')::int = 500
                    and not (e->>'earned')::boolean),
    'T2 累计仅 100，小金库(500)不应达成';

  raise notice '✓ 028 累计获取口径：余额500 仍达成大富翁；撤销不扣减累计';
end $$;

rollback;
