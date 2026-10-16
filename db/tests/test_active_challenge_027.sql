-- =============================================================================
-- test_active_challenge_027.sql —— 连续活跃挑战（027）
-- =============================================================================
-- 覆盖：
--   V1 规格：活跃21 入场7/奖励33/窗口21/达标20/容错1/奖励卡retro_active/类active
--           活跃45 入场10/奖励100/窗口45/达标42/容错3
--   V2 判定维度=active：凑满 20 天活跃 → succeeded +33 分 + 补活跃卡×1
--   V3 失败补救：漏 2 天（>容错1）→ failing；买补活跃卡补掉那天 → 挑战恢复
--   V4 补救卡选型：活跃类的 retro_card_item.kind = retro_active（不是 retro_signin/fullstar）
--   V5 同类互斥：活跃类进行中 → 再开活跃类被拒（CHALLENGE_ACTIVE）
--   V6 跨类并行：活跃类进行中 + 签到类进行中 → currents 两条
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- =============================================================================

begin;

-- fullstar_points 显式设 0：025 起"当天满星"会额外发一笔奖励，本文件只测活跃挑战，
-- 关掉它免得余额断言被那 30 分顶偏（满星奖励本身由 test_fullstar_points_025 覆盖）
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap,
                          fullstar_points) values
  ('f0270000-0000-4000-8000-000000000001', '活跃之家', 'Asia/Shanghai', 0, 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('f0270000-0000-4000-8000-00000000000a', 'f0270000-0000-4000-8000-000000000001',
   'f0270000-0000-4000-8000-00000000000b', '爸', 'parent'),
  ('f0270000-0000-4000-8000-00000000000c', 'f0270000-0000-4000-8000-000000000001',
   'f0270000-0000-4000-8000-00000000000d', '娃', 'child');

select app.seed_reward_items('f0270000-0000-4000-8000-000000000001');
update app.members set points_balance = 500
 where id = 'f0270000-0000-4000-8000-00000000000c';

do $$
declare
  v_family uuid := 'f0270000-0000-4000-8000-000000000001';
  v_child  uuid := 'f0270000-0000-4000-8000-00000000000c';
  v_cuid   text := 'f0270000-0000-4000-8000-00000000000d';
  v_today  date;
  v_state  jsonb;
  v_bal    int;
  v_n      int;
  ok       boolean;
begin
  v_today := app.family_today(v_family);
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  -- V1 规格数值：活跃在 specs 数组尾巴（index 4/5）
  v_state := app.challenge_state();
  assert (v_state->'specs'->4->>'kind') = 'active_21', 'V1 应有活跃21规格';
  assert (v_state->'specs'->4->>'entry_fee')::int = 7, format('V1 活跃21入场应为7，实际 %s', v_state->'specs'->4->>'entry_fee');
  assert (v_state->'specs'->4->>'reward_points')::int = 33, format('V1 活跃21奖励应为33，实际 %s', v_state->'specs'->4->>'reward_points');
  assert (v_state->'specs'->4->>'reward_card') = 'retro_active', 'V1 活跃21奖励卡应为补活跃卡';
  assert (v_state->'specs'->4->>'category') = 'active', 'V1 活跃21类应为active';
  assert (v_state->'specs'->4->>'category_label') = '连续活跃', 'V1 活跃21类文案应为连续活跃';
  assert (v_state->'specs'->5->>'entry_fee')::int = 10, 'V1 活跃45入场应为10';
  assert (v_state->'specs'->5->>'reward_points')::int = 100, 'V1 活跃45奖励应为100';
  raise notice '✓ V1 规格：活跃21(7/33) 活跃45(10/100)，类=active，奖励卡=retro_active';

  -- V2 判定走 active：开活跃21 → 凑满 20 天活跃 → 成功 +33 + 补活跃卡
  v_state := app.start_challenge('active_21');          -- 500 - 7 = 493
  assert (v_state->>'balance')::int = 493, format('V2 应扣到493，实际 %s', v_state->>'balance');
  update app.challenges
     set started_on = v_today - 20, ends_on = v_today
   where member_id = v_child and status = 'active';
  insert into app.member_day (member_id, day, active)
  select v_child, v_today - i, true from generate_series(0, 19) i
  on conflict (member_id, day) do update set active = true, updated_at = now();
  v_state := app.challenge_state();
  assert (v_state->'currents'->0->>'status') = 'succeeded',
    format('V2 应 succeeded，实际 %s', v_state->'currents'->0->>'status');
  assert (v_state->'currents'->0->>'fullstar_days')::int = 20, 'V2 应活跃20天';
  select points_balance into v_bal from app.members where id = v_child;
  assert v_bal = 526, format('V2 成功后应526（493+33），实际 %s', v_bal);
  select coalesce(qty, 0)::int into v_n from app.member_cards
   where member_id = v_child and kind = 'retro_active';
  assert v_n = 1, format('V2 应得补活跃卡1张，实际 %s', v_n);
  raise notice '✓ V2 活跃判定=active：凑满20天 → succeeded +33 +补活跃卡';

  -- V3 失败补救：漏 2 天 → failing；补活跃卡补掉那天 → 恢复
  -- （清掉 V2 留下的活跃记录，否则近 20 天全已活跃，漏天数算不出来）
  delete from app.member_day where member_id = v_child;
  perform app.start_challenge('active_21');             -- 526 - 7 = 519
  update app.challenges
     set started_on = v_today - 4, ends_on = v_today + 16
   where member_id = v_child and category = 'active' and status = 'active';
  insert into app.member_day (member_id, day, active) values
    (v_child, v_today - 4, true), (v_child, v_today - 3, true)
  on conflict (member_id, day) do update set active = true, updated_at = now();
  v_state := app.challenge_state();
  assert (v_state->'currents'->0->>'status') = 'active', 'V3 应 active';
  assert (v_state->'currents'->0->>'missed_days')::int = 2,
    format('V3 应漏2天，实际 %s', v_state->'currents'->0->>'missed_days');
  assert (v_state->'currents'->0->>'failing')::boolean = true, 'V3 漏2>容错1 应 failing';
  -- V4 补救卡选型：活跃类应是 retro_active
  assert (v_state->'currents'->0->'retro_card_item'->>'kind') = 'retro_active',
    'V4 活跃类补救卡应为 retro_active';
  assert (v_state->'currents'->0->'retro_card_item'->>'price')::int = 60,
    'V4 商城补活跃卡默认60分';
  raise notice '✓ V4 补救卡选型：活跃类 retro_card_item.kind=retro_active（60分）';

  -- 给一张补活跃卡 → 补掉昨天 → 漏 2 → 1，failing 解除（已有可能存在的补活跃卡，用 upsert）
  insert into app.member_cards (member_id, kind, qty) values (v_child, 'retro_active', 1)
  on conflict (member_id, kind) do update set qty = member_cards.qty + 1, updated_at = now();
  perform app.use_retro_card('retro_active', v_today - 1);
  v_state := app.challenge_state();
  assert (v_state->'currents'->0->>'missed_days')::int = 1,
    format('V3 补救后应漏1天，实际 %s', v_state->'currents'->0->>'missed_days');
  assert (v_state->'currents'->0->>'failing')::boolean = false, 'V3 补救后应不再 failing';
  raise notice '✓ V3 买补活跃卡补昨天 → 活跃挑战恢复（missed 2→1，failing=false）';

  -- V5 同类互斥：活跃类进行中 → 再开活跃类被拒
  ok := false;
  begin
    perform app.start_challenge('active_45');
  exception when others then ok := (sqlerrm like 'CHALLENGE_ACTIVE%');
  end;
  assert ok, 'V5 活跃类进行中再开活跃类必须 CHALLENGE_ACTIVE';
  select count(*)::int into v_n from app.challenges where member_id = v_child and status = 'active';
  assert v_n = 1, format('V5 活跃类仍应只有 1 条进行中，实际 %s', v_n);
  raise notice '✓ V5 同类互斥：活跃21 vs 活跃45';

  -- V6 跨类并行：再开签到类（不同类）→ currents 两条
  perform app.start_challenge('signin_21');             -- 519 - 7 = 512
  v_state := app.challenge_state();
  assert jsonb_array_length(v_state->'currents') = 2,
    format('V6 应有2类各一条，实际 %s', v_state->'currents');
  raise notice '✓ V6 跨类并行：活跃类 + 签到类各一条进行中';
end $$;

rollback;
