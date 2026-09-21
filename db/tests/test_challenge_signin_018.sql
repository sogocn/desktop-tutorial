-- =============================================================================
-- test_challenge_signin_018.sql —— 连续签到挑战（018）
-- =============================================================================
-- 覆盖：
--   U1 规格：签到21 入场7/奖励33/窗口21/达标20/容错1/奖励卡retro_signin/类signin
--           签到45 入场10/奖励100/窗口45/达标42/容错3
--   U2 判定维度=signed：凑满 20 天签到 → succeeded +33 分 + 补签卡×1
--   U3 失败补救：漏 2 天（>容错1）→ failing；买补签卡补掉那天 → 挑战恢复
--   U4 补救卡选型：签到类的 retro_card_item.kind = retro_signin（不是 retro_fullstar）
--   U5 跨类并行：签到类进行中 + 满星类进行中 → currents 两条
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- =============================================================================

begin;

insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0180000-0000-4000-8000-000000000001', '签到之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('f0180000-0000-4000-8000-00000000000a', 'f0180000-0000-4000-8000-000000000001',
   'f0180000-0000-4000-8000-00000000000b', '爸', 'parent'),
  ('f0180000-0000-4000-8000-00000000000c', 'f0180000-0000-4000-8000-000000000001',
   'f0180000-0000-4000-8000-00000000000d', '娃', 'child');

select app.seed_reward_items('f0180000-0000-4000-8000-000000000001');
update app.members set points_balance = 500
 where id = 'f0180000-0000-4000-8000-00000000000c';

do $$
declare
  v_family uuid := 'f0180000-0000-4000-8000-000000000001';
  v_child  uuid := 'f0180000-0000-4000-8000-00000000000c';
  v_cuid   text := 'f0180000-0000-4000-8000-00000000000d';
  v_today  date;
  v_state  jsonb;
  v_bal    int;
  v_n      int;
  ok       boolean;
begin
  v_today := app.family_today(v_family);
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  -- U1 规格数值
  v_state := app.challenge_state();
  assert (v_state->'specs'->2->>'kind') = 'signin_21', 'U1 应有签到21规格';
  assert (v_state->'specs'->2->>'entry_fee')::int = 7, format('U1 签到21入场应为7，实际 %s', v_state->'specs'->2->>'entry_fee');
  assert (v_state->'specs'->2->>'reward_points')::int = 33, format('U1 签到21奖励应为33，实际 %s', v_state->'specs'->2->>'reward_points');
  assert (v_state->'specs'->2->>'reward_card') = 'retro_signin', 'U1 签到21奖励卡应为补签卡';
  assert (v_state->'specs'->2->>'category') = 'signin', 'U1 签到21类应为signin';
  assert (v_state->'specs'->3->>'entry_fee')::int = 10, 'U1 签到45入场应为10';
  assert (v_state->'specs'->3->>'reward_points')::int = 100, 'U1 签到45奖励应为100';
  -- 入场分与奖励约为满星的 1/3（21: 7/33 vs 满星 20/100；45: 10/100 vs 满星 30/300）
  raise notice '✓ U1 规格：签到21(7/33) 签到45(10/100)，约为满星1/3';

  -- U2 判定走 signed：开签到21 → 凑满 20 天签到 → 成功 +33 + 补签卡
  v_state := app.start_challenge('signin_21');          -- 500 - 7 = 493
  assert (v_state->>'balance')::int = 493, format('U2 应扣到493，实际 %s', v_state->>'balance');
  update app.challenges
     set started_on = v_today - 20, ends_on = v_today
   where member_id = v_child and status = 'active';
  insert into app.member_day (member_id, day, signed)
  select v_child, v_today - i, true from generate_series(0, 19) i
  on conflict (member_id, day) do update set signed = true, updated_at = now();
  v_state := app.challenge_state();
  assert (v_state->'currents'->0->>'status') = 'succeeded',
    format('U2 应 succeeded，实际 %s', v_state->'currents'->0->>'status');
  assert (v_state->'currents'->0->>'fullstar_days')::int = 20, 'U2 应签到20天';
  select points_balance into v_bal from app.members where id = v_child;
  assert v_bal = 526, format('U2 成功后应526（493+33），实际 %s', v_bal);
  select coalesce(qty, 0)::int into v_n from app.member_cards
   where member_id = v_child and kind = 'retro_signin';
  assert v_n = 1, format('U2 应得补签卡1张，实际 %s', v_n);
  raise notice '✓ U2 签到判定=signed：凑满20天 → succeeded +33 +补签卡';

  -- U3 失败补救：漏 2 天 → failing；补签卡补掉那天 → 恢复
  -- （清掉 U2 留下的签到记录，否则近 20 天全已签到，漏天数算不出来）
  delete from app.member_day where member_id = v_child;
  perform app.start_challenge('signin_21');             -- 526 - 7 = 519
  update app.challenges
     set started_on = v_today - 4, ends_on = v_today + 16
   where member_id = v_child and category = 'signin' and status = 'active';
  insert into app.member_day (member_id, day, signed) values
    (v_child, v_today - 4, true), (v_child, v_today - 3, true)
  on conflict (member_id, day) do update set signed = true, updated_at = now();
  v_state := app.challenge_state();
  assert (v_state->'currents'->0->>'status') = 'active', 'U3 应 active';
  assert (v_state->'currents'->0->>'missed_days')::int = 2,
    format('U3 应漏2天，实际 %s', v_state->'currents'->0->>'missed_days');
  assert (v_state->'currents'->0->>'failing')::boolean = true, 'U3 漏2>容错1 应 failing';
  -- U4 补救卡选型：签到类应是 retro_signin
  assert (v_state->'currents'->0->'retro_card_item'->>'kind') = 'retro_signin',
    'U4 签到类补救卡应为 retro_signin';
  assert (v_state->'currents'->0->'retro_card_item'->>'price')::int = 30,
    'U4 商城补签卡默认30分';
  raise notice '✓ U4 补救卡选型：签到类 retro_card_item.kind=retro_signin（30分）';

  -- 给一张补签卡 → 补掉昨天 → 漏 2 → 1，failing 解除（已有可能存在的补签卡，用 upsert）
  insert into app.member_cards (member_id, kind, qty) values (v_child, 'retro_signin', 1)
  on conflict (member_id, kind) do update set qty = member_cards.qty + 1, updated_at = now();
  perform app.use_retro_card('retro_signin', v_today - 1);
  v_state := app.challenge_state();
  assert (v_state->'currents'->0->>'missed_days')::int = 1,
    format('U3 补救后应漏1天，实际 %s', v_state->'currents'->0->>'missed_days');
  assert (v_state->'currents'->0->>'failing')::boolean = false, 'U3 补救后应不再 failing';
  raise notice '✓ U3 买补签卡补昨天 → 签到挑战恢复（missed 2→1，failing=false）';

  -- U5 跨类并行：再开满星类（不同类）→ currents 两条
  perform app.start_challenge('fullstar_21');            -- 519 - 20 = 499
  v_state := app.challenge_state();
  assert jsonb_array_length(v_state->'currents') = 2,
    format('U5 应有2类各一条，实际 %s', v_state->'currents');
  raise notice '✓ U5 跨类并行：签到类 + 满星类各一条进行中';
end $$;

rollback;
