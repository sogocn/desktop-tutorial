-- =============================================================================
-- test_challenge_016.sql —— 016 满星挑战
-- =============================================================================
-- 覆盖：
--   S0 家长视角：无挑战 → current=null，specs 两条
--   S1 孩子开 21 天挑战 → active，扣 20 分，流水落 challenge/seq=0
--   S2 进行中再开（任意类型）→ CHALLENGE_ACTIVE
--   S3 余额不足（家长 0 分）→ NOT_ENOUGH_POINTS
--   S4 进度：漏 2 天（>容错1）→ failing=true，商城补满星卡可见(120分)，能给出补救日
--   S5 补救链：use_retro_card 补满星 → missed 降回 1 → failing=false（买卡补漏挑战继续）
--   S6 成功：凑满 20 天满星 → succeeded，+100 分，补签卡 +1；再查一次不重复发奖（幂等）
--   S7 窗口结束仍未达标 → failed（终局）
--   S8 45 天挑战规格：窗口45 / 要求42 / 容错3 / 入场30
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- 日期一律相对 app.family_today() 推算，避免测试机时区错位。
-- =============================================================================

begin;

insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0160000-0000-4000-8000-000000000001', '挑战之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('f0160000-0000-4000-8000-00000000000a', 'f0160000-0000-4000-8000-000000000001',
   'f0160000-0000-4000-8000-00000000000b', '爸', 'parent'),
  ('f0160000-0000-4000-8000-00000000000c', 'f0160000-0000-4000-8000-000000000001',
   'f0160000-0000-4000-8000-00000000000d', '娃', 'child');

-- 商城播种（挑战页的"购买满星卡"要能找到在售的补满星卡）
-- 注意：PERFORM 只在 PL/pgSQL 里合法，顶层要用 SELECT
select app.seed_reward_items('f0160000-0000-4000-8000-000000000001');
-- 娃的启动资金
update app.members set points_balance = 100
 where id = 'f0160000-0000-4000-8000-00000000000c';

do $$
declare
  v_family uuid := 'f0160000-0000-4000-8000-000000000001';
  v_child  uuid := 'f0160000-0000-4000-8000-00000000000c';
  v_cuid   text := 'f0160000-0000-4000-8000-00000000000d'; -- 娃的 user_id
  v_puid   text := 'f0160000-0000-4000-8000-00000000000b'; -- 爸的 user_id
  v_today  date;
  v_state  jsonb;
  v_bal    int;
  v_n      int;
  ok       boolean;
begin
  v_today := app.family_today(v_family);

  -- S0 家长：无挑战
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_puid), true);
  v_state := app.challenge_state();
  -- 注意：JSON 的 null 不是 SQL 的 NULL，`-> 'current' is null` 恒为 false，
  -- 必须用 jsonb_typeof 判类型（或 ->> 转文本再判）
  assert jsonb_typeof(v_state->'current') = 'null',
    format('S0 家长应无挑战，实际 current=%s', v_state->'current');
  assert jsonb_array_length(v_state->'specs') = 4, 'S0 specs 应有四条（满星21/45 + 签到21/45）';
  raise notice '✓ S0 家长视角 current=null，specs=4';

  -- S1 孩子开 21 天挑战 → 扣 20 分
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);
  v_state := app.start_challenge('fullstar_21');
  assert (v_state->>'status') = 'active', format('S1 应 active，实际 %s', v_state->>'status');
  assert (v_state->>'balance')::int = 80, format('S1 应扣到 80，实际 %s', v_state->>'balance');
  select count(*)::int into v_n from app.point_ledger
   where source_type = 'challenge' and source_seq = 0 and delta = -20;
  assert v_n = 1, format('S1 流水应落 1 笔 -20，实际 %s', v_n);
  raise notice '✓ S1 开启 21 天挑战：active，扣 20 分，流水落账';

  -- S2 进行中再开 → CHALLENGE_ACTIVE
  ok := false;
  begin
    perform app.start_challenge('fullstar_45');
  exception when others then ok := (sqlerrm like 'CHALLENGE_ACTIVE%');
  end;
  assert ok, 'S2 进行中再开必须 CHALLENGE_ACTIVE';
  raise notice '✓ S2 进行中不能再开（21/45 互斥）';

  -- S3 余额不足（家长 0 分）→ NOT_ENOUGH_POINTS
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_puid), true);
  ok := false;
  begin
    perform app.start_challenge('fullstar_21');
  exception when others then ok := (sqlerrm like 'NOT_ENOUGH_POINTS%');
  end;
  assert ok, 'S3 余额不足必须 NOT_ENOUGH_POINTS';
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);
  raise notice '✓ S3 余额不足被拒';

  -- S4 进度：回溯 4 天开跑，2 天满星 2 天漏 → failing
  update app.challenges
     set started_on = v_today - 4, ends_on = v_today - 4 + 20
   where member_id = v_child and status = 'active';
  insert into app.member_day (member_id, day, fullstar) values
    (v_child, v_today - 4, true),
    (v_child, v_today - 3, true);
  v_state := app.challenge_state();
  assert (v_state->'current'->>'status') = 'active', 'S4 应 active';
  assert (v_state->'current'->>'missed_days')::int = 2, format('S4 应漏 2 天，实际 %s', v_state->'current'->>'missed_days');
  assert (v_state->'current'->>'failing')::boolean = true, 'S4 漏2>容错1 应 failing';
  assert (v_state->'current'->>'latest_missed_day') = (v_today - 1)::text,
    format('S4 补救日应是昨天，实际 %s', v_state->'current'->>'latest_missed_day');
  assert (v_state->'fullstar_card_item'->>'price')::int = 120,
    format('S4 商城补满星卡应 120 分，实际 %s', v_state->'fullstar_card_item');
  raise notice '✓ S4 进度正确：满星2 漏2 → failing，补救日=昨天，满星卡 120 分在售';

  -- S5 补救链：发一张补满星卡 → use_retro_card 补昨天 → failing 解除
  insert into app.member_cards (member_id, kind, qty) values (v_child, 'retro_fullstar', 1);
  perform app.use_retro_card('retro_fullstar', v_today - 1);
  v_state := app.challenge_state();
  assert (v_state->'current'->>'missed_days')::int = 1, format('S5 补救后应漏 1 天，实际 %s', v_state->'current'->>'missed_days');
  assert (v_state->'current'->>'failing')::boolean = false, 'S5 补救后应不再 failing';
  raise notice '✓ S5 买卡补漏 → 挑战恢复（missed 2→1，failing=false）';

  -- S6 成功：回溯到 20 天前，凑满 20 天满星 → +100 分 + 补签卡
  update app.challenges
     set started_on = v_today - 20, ends_on = v_today
   where member_id = v_child and status = 'active';
  -- 现有满星：today-4/-3/-1（3 天）；再补 today-20..today-5（16 天）+ today-2（1 天）= 20
  insert into app.member_day (member_id, day, fullstar)
  select v_child, v_today - i, true from generate_series(5, 20) i
  on conflict (member_id, day) do update set fullstar = true, updated_at = now();
  insert into app.member_day (member_id, day, fullstar) values (v_child, v_today - 2, true)
  on conflict (member_id, day) do update set fullstar = true, updated_at = now();

  v_state := app.challenge_state();
  assert (v_state->'current'->>'status') = 'succeeded', format('S6 应 succeeded，实际 %s', v_state->'current'->>'status');
  assert (v_state->'current'->>'just_succeeded')::boolean = true, 'S6 本次调用应 just_succeeded';
  assert (v_state->'current'->>'fullstar_days')::int = 20, format('S6 应满星 20 天，实际 %s', v_state->'current'->>'fullstar_days');
  select points_balance into v_bal from app.members where id = v_child;
  assert v_bal = 180, format('S6 成功后应 180（80+100），实际 %s', v_bal);
  select coalesce(qty, 0)::int into v_n from app.member_cards
   where member_id = v_child and kind = 'retro_signin';
  assert v_n = 1, format('S6 应得 1 张补签卡，实际 %s', v_n);
  raise notice '✓ S6 挑战成功：+100 分，补签卡 ×1';

  -- 幂等：再查一次不重复发奖
  v_state := app.challenge_state();
  assert (v_state->'current'->>'just_succeeded')::boolean = false, '幂等：第二次不应 just_succeeded';
  select points_balance into v_bal from app.members where id = v_child;
  assert v_bal = 180, format('幂等：余额不应再变，实际 %s', v_bal);
  raise notice '✓ S6b 重复读取不重复发奖';

  -- S7 窗口结束仍未达标 → failed 终局
  perform app.start_challenge('fullstar_21');  -- 180 - 20 = 160
  -- S6 已经把 today-20..today-1 全刷成满星了，不清掉会污染新窗口（窗口内反成 21 天全满星）
  delete from app.member_day where member_id = v_child;
  update app.challenges
     set started_on = v_today - 30, ends_on = v_today - 10
   where member_id = v_child and status = 'active';
  insert into app.member_day (member_id, day, fullstar)
  select v_child, v_today - i, true from generate_series(16, 30) i
  on conflict (member_id, day) do update set fullstar = true, updated_at = now();
  v_state := app.challenge_state();
  assert (v_state->'current'->>'status') = 'failed', format('S7 应 failed，实际 %s', v_state->'current'->>'status');
  assert (v_state->'current'->>'failing')::boolean = false, 'S7 终局失败不再标 failing';
  assert (v_state->'current'->>'missed_days')::int = 6,
    format('S7 窗口内应漏 6 天(21-15)，实际 %s', v_state->'current'->>'missed_days');
  select points_balance into v_bal from app.members where id = v_child;
  assert v_bal = 160, format('S7 失败不退入场费，应 160，实际 %s', v_bal);
  raise notice '✓ S7 窗口结束未达标 → failed（终局，入场费不退）';

  -- S8 45 天挑战规格
  v_state := app.start_challenge('fullstar_45');  -- 160 - 30 = 130
  v_state := app.challenge_state();
  assert (v_state->'current'->>'kind') = 'fullstar_45', 'S8 应为 45 天挑战';
  assert (v_state->'current'->>'window_days')::int = 45, 'S8 窗口 45';
  assert (v_state->'current'->>'required_fullstar')::int = 42, 'S8 要求 42 天满星';
  assert (v_state->'current'->>'allowed_miss')::int = 3, 'S8 容错 3 天';
  select points_balance into v_bal from app.members where id = v_child;
  assert v_bal = 130, format('S8 应扣 30 到 130，实际 %s', v_bal);
  raise notice '✓ S8 45 天挑战：窗口45 / 要求42 / 容错3 / 入场30';
end $$;

rollback;
