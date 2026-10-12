-- =============================================================================
-- test_no_daily_cap_020.sql —— 每日积分不再设上限（020）
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在一个事务里，最后 ROLLBACK。
-- =============================================================================

begin;

-- 这个家庭故意不写 child_daily_points_cap，走的就是 020 改出来的默认值
insert into app.families (id, name, timezone, day_cutoff_hour) values
  ('f0000000-0000-4000-8000-000000000020', '不限分之家', 'Asia/Shanghai', 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000020', 'f0000000-0000-4000-8000-000000000020',
   'a1000000-0000-4000-8000-000000000020', '爸020', 'parent'),
  ('b0000000-0000-4000-8000-000000000020', 'f0000000-0000-4000-8000-000000000020',
   'b1000000-0000-4000-8000-000000000020', '娃020', 'child');

-- ---------------------------------------------------------------------------
-- N1~N3：默认不设上限，一天挣多少都能全额入账
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid  uuid := 'f0000000-0000-4000-8000-000000000020';
  v_kid  uuid := 'b0000000-0000-4000-8000-000000000020';
  v_cap  int;
  v_bal  int;
  e      app.point_ledger%rowtype;
  v_today date;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000020","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  -- N1 默认值应为 0（旧版是 200）
  select child_daily_points_cap into v_cap from app.families where id = v_fid;
  assert v_cap = 0, 'N1 新建家庭 child_daily_points_cap 默认应为 0，实际 ' || v_cap;
  raise notice '✓ N1 默认不设上限（cap=0，旧默认 200 已改）';

  -- N2 一笔 500 分全额入账（旧默认 200 会被砍到 200）
  e := app._post_ledger(
    v_kid, 500, 'completion',
    'd0000000-0000-4000-8000-000000000021', 1, '测试完成一个大任务',
    v_today, null);
  assert e.delta = 500, 'N2 500 分应全额入账，实际 ' || e.delta;
  assert e.capped_from is null, 'N2 不应出现截断标记，实际 ' || e.capped_from;
  raise notice '✓ N2 一笔 500 分全额入账，未被截断';

  -- N3 再挣 300 也不截断（当日累计 800）
  e := app._post_ledger(
    v_kid, 300, 'badge',
    'd0000000-0000-4000-8000-000000000022', 1, '测试勋章加分',
    v_today, null);
  v_bal := (select points_balance from app.members where id = v_kid);
  assert e.delta = 300, 'N3 300 分应全额入账，实际 ' || e.delta;
  assert v_bal = 800, 'N3 余额应为 800，实际 ' || v_bal;
  raise notice '✓ N3 当日累计 800 分，日上限完全不生效';
end $$;

-- ---------------------------------------------------------------------------
-- N4：机制本身没被删 —— 某个家庭显式设上限时依然照旧生效
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000020';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000020';
  v_today date;
  e       app.point_ledger%rowtype;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000020","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  update app.families set child_daily_points_cap = 100 where id = v_fid;

  -- 当日已挣 800 > 100，额度已耗尽 → 只入 0，但要记录原本应发 250
  e := app._post_ledger(
    v_kid, 250, 'completion',
    'd0000000-0000-4000-8000-000000000023', 1, '测试上限仍生效',
    v_today, null);
  assert e.delta = 0, 'N4 额度耗尽时应只入 0，实际 ' || e.delta;
  assert e.capped_from = 250, 'N4 capped_from 应记录原额 250，实际 ' || e.capped_from;
  raise notice '✓ N4 显式设上限时依然生效（能力保留，未被破坏）';
end $$;

rollback;
