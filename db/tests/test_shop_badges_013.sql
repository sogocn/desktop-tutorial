-- =============================================================================
-- test_shop_badges_013.sql —— 单次完成计分 / 现金比率 / 补卡兑换 / 勋章积分奖励
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在一个事务里，最后 ROLLBACK。所有"今天"从 app.family_today() 取。
-- =============================================================================

begin;

-- 独立家庭，id 带 013 后缀，避免和别的 suite 撞
-- child_daily_points_cap = 0 = 不限，免得日上限把断言搅乱
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0000000-0000-4000-8000-000000000013', '积分之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000013', 'f0000000-0000-4000-8000-000000000013',
   'a1000000-0000-4000-8000-000000000013', '爸', 'parent'),
  ('b0000000-0000-4000-8000-000000000013', 'f0000000-0000-4000-8000-000000000013',
   'b1000000-0000-4000-8000-000000000013', '娃', 'child'),
  ('c0000000-0000-4000-8000-000000000013', 'f0000000-0000-4000-8000-000000000013',
   'c1000000-0000-4000-8000-000000000013', '妹', 'child');

-- 家长令牌：decide_redemption / set_badge_bonus / set_family_settings 要用
insert into app.parent_sessions (token, member_id, expires_at) values
  ('tok-013', 'a0000000-0000-4000-8000-000000000013', now() + interval '2 hours');

-- 商城播种（建家庭时才会调，测试家庭是脚本里临时建的，得自己来一遍）
do $$
begin
  perform app.seed_reward_items('f0000000-0000-4000-8000-000000000013');
end $$;

-- 回归保护（针对存量老家庭）：模拟 013 之前的现金商品(item_kind=NULL, rate=100)，
-- 跑与迁移「九、存量数据回填」一致的逻辑，断言最终只有 1 条 item_kind='cash' 的现金、
-- 不重复、且比率被重算为家庭 cash_rate_points。此 bug 只在有老家庭的线上库触发，单测必须兜住。
do $$
declare
  v_fid uuid := 'f0000000-0000-4000-8000-000000000013';
  n int;
begin
  delete from app.reward_items where family_id = v_fid and item_kind = 'cash';
  insert into app.reward_items
    (family_id, name, emoji, pricing_mode, rate_points, unit_label, item_kind)
  values
    (v_fid, '现金', '💰', 'rate', 100, '元', 'goods');

  update app.reward_items r
     set item_kind   = 'cash',
         rate_points = coalesce(f.cash_rate_points, 10)
    from app.families f
   where f.id = r.family_id
     and r.item_kind = 'goods'
     and r.pricing_mode = 'rate';

  perform app.seed_reward_items(v_fid);

  select count(*) into n from app.reward_items
   where family_id = v_fid and item_kind = 'cash';
  assert n = 1,
    format('I 存量老现金回填后应恰好 1 条 item_kind=cash，实际 %s', n);
  assert (select rate_points from app.reward_items
           where family_id = v_fid and item_kind = 'cash')
         = (select cash_rate_points from app.families where id = v_fid),
    'I 老现金比率应被重算为家庭 cash_rate_points';
  raise notice '  [I] 存量老现金回填不重复 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- A：循环任务「完成当日」发单次分（打卡分 3），不是完成分（10）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000013';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000013';
  v_task  uuid := 'd0000000-0000-4000-8000-000000000013';
  v_today date;
  r jsonb; n int; v_bal int; v_badge int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    (v_task, v_fid, v_kid, 'a0000000-0000-4000-8000-000000000013',
     '跳绳', 'recurring', '{"freq":"daily"}',
     v_today - 60, 10, 3, 1, true);

  select coalesce(sum(delta), 0) into v_badge
    from app.point_ledger
   where member_id = v_kid and source_type = 'badge' and entry_kind = 'primary';

  v_bal := (select points_balance from app.members where id = v_kid);
  r := app.complete_occurrence(v_task, v_today);

  assert (r->>'points_awarded')::int = 3,
    format('A1 单次完成应发单次分 3，实际 %s', r->>'points_awarded');
  -- 首次完成任务会解锁「第一步」勋章并发额外奖励分（参考值 5），单独计入基线
  select coalesce(sum(delta), 0) - v_badge into v_badge
    from app.point_ledger
   where member_id = v_kid and source_type = 'badge' and entry_kind = 'primary';
  assert (select points_balance from app.members where id = v_kid) = v_bal + 3 + v_badge,
    format('A1b 余额应 +3(+勋章%s)，实际 %s', v_badge,
      (select points_balance from app.members where id = v_kid));

  select count(*) into n from app.point_ledger
   where member_id = v_kid and source_type = 'completion' and entry_kind = 'primary'
     and delta = 10;
  assert n = 0, format('A1c 单次完成不应出现 10 分的完成流水，实际 %s 条', n);

  -- 打卡仍然发打卡分，两条路径互不影响
  v_bal := (select points_balance from app.members where id = v_kid);
  r := app.complete_occurrence(v_task, v_today + 1);
  assert (r->>'points_awarded')::int = 3,
    format('A2 第二天单次完成同样 3 分，实际 %s', r->>'points_awarded');

  raise notice '  [A] 单次完成发单次分 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- B：完成全部 = 各日单次分之和 + 一笔完成分（3 天 → 3×3 + 10 = 19）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000013';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000013';
  v_task  uuid := 'd0000000-0000-4000-8000-000000000013';
  v_today date;
  r jsonb; v_bal int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  -- A 里已完成 2 天（today / today+1）。缩到 today+2 收尾，剩 1 天未做。
  update app.tasks set ends_on = v_today + 2 where id = v_task;

  v_bal := (select points_balance from app.members where id = v_kid);
  r := app.complete_all_occurrences(v_task);

  assert (r->>'completed_occurrences')::int = 1,
    format('B1 只剩 1 天未做，实际完成 %s 天', r->>'completed_occurrences');
  assert (r->>'points_awarded')::int = 13,
    format('B2 补齐应发 3(单次) + 10(结清) = 13，实际 %s', r->>'points_awarded');

  -- 已完成的天不重发：再跑一次 0 / 0
  r := app.complete_all_occurrences(v_task);
  assert (r->>'completed_occurrences')::int = 0 and (r->>'points_awarded')::int = 0,
    format('B3 幂等重跑应为 0/0，实际 %s/%s',
           r->>'completed_occurrences', r->>'points_awarded');

  raise notice '  [B] 完成全部 = 补齐各日单次分 + 一笔完成分 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- C：一次性任务 —— 完成当日就是完成全部，发完成分（+ 打卡分）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000013';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000013';
  v_task  uuid := 'd0000000-0000-4000-8000-000000000013';
  v_once  uuid := 'd0000000-0000-4000-8000-000000000014';
  v_today date;
  r jsonb; n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    (v_once, v_fid, v_kid, 'a0000000-0000-4000-8000-000000000013',
     '倒垃圾', 'once', format('{"freq":"once","date":"%s"}', v_today)::jsonb,
     v_today, 10, 3, 1, true);

  r := app.complete_occurrence(v_once, v_today);
  assert (r->>'points_awarded')::int = 10,
    format('C1 once 完成当日应发完成分 10，实际 %s', r->>'points_awarded');

  -- 011 的"完成即打卡"还在：打卡分 3 另算一笔 checkin 流水
  select count(*) into n from app.point_ledger
   where member_id = v_kid and source_type = 'checkin' and entry_kind = 'primary';
  assert n = 1, format('C2 once 完成应补一次打卡并发分，实际 %s 条 checkin 流水', n);

  -- 完成全部：已经完成 → 0/0，once 不会再叠一笔完成分
  r := app.complete_all_occurrences(v_once);
  assert (r->>'completed_occurrences')::int = 0 and (r->>'points_awarded')::int = 0,
    format('C3 once 完成全部不应重复发分，实际 %s/%s',
           r->>'completed_occurrences', r->>'points_awarded');

  -- 换一个没做过的 once，用「完成全部」走一遍：应等于完成当日（10 + 打卡 3）
  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    ('d0000000-0000-4000-8000-000000000015', v_fid, v_kid,
     'a0000000-0000-4000-8000-000000000013',
     '洗碗', 'once', format('{"freq":"once","date":"%s"}', v_today + 1)::jsonb,
     v_today + 1, 10, 3, 1, true);

  r := app.complete_all_occurrences('d0000000-0000-4000-8000-000000000015');
  assert (r->>'completed_occurrences')::int = 1,
    format('C4 once 完成全部应完成 1 天，实际 %s', r->>'completed_occurrences');
  assert (r->>'points_awarded')::int = 10,
    format('C5 once 完成全部只发完成分 10（打卡分另计），实际 %s', r->>'points_awarded');

  raise notice '  [C] 一次性任务口径 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- D：兑换补签卡 → 发卡 + 扣分
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000013';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000013';
  v_item  uuid;
  r jsonb; n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);

  -- 播种检查：现金 10 分/元 + 三张卡
  select count(*) into n from app.reward_items
   where family_id = v_fid and item_kind = 'cash' and rate_points = 10;
  assert n = 1, format('D0 现金商品应是 10 分/元，实际 %s 条', n);

  select count(*) into n from app.reward_items
   where family_id = v_fid and item_kind = 'card';
  assert n = 3, format('D0b 应有 3 张补卡商品，实际 %s 条', n);

  update app.members set points_balance = 500 where id = v_kid;
  select id into v_item from app.reward_items
   where family_id = v_fid and card_kind = 'retro_signin';

  r := app.redeem(v_item, 1);
  assert (r->>'points_spent')::int = 30,
    format('D1 补签卡应 30 分，实际 %s', r->>'points_spent');
  assert r->>'granted_card' = 'retro_signin',
    format('D2 应发补签卡，实际 %s', r->>'granted_card');
  assert (select qty from app.member_cards
           where member_id = v_kid and kind = 'retro_signin') = 1,
    'D3 补签卡库存应为 1';
  assert (select points_balance from app.members where id = v_kid) = 470,
    format('D4 余额应剩 470，实际 %s',
           (select points_balance from app.members where id = v_kid));

  -- 再兑 2 张：库存累加，不是覆盖
  perform app.redeem(v_item, 2);
  assert (select qty from app.member_cards
           where member_id = v_kid and kind = 'retro_signin') = 3,
    'D5 再兑 2 张后库存应累加到 3';

  raise notice '  [D] 兑换补卡发卡 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- E：家长驳回 → 卡和分一起退
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000013';
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000013';
  v_item  uuid;
  r jsonb; v_rid uuid; v_bal int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);

  update app.members set points_balance = 500 where id = v_kid;
  select id into v_item from app.reward_items
   where family_id = v_fid and card_kind = 'retro_fullstar';
  v_bal := (select points_balance from app.members where id = v_kid);

  r := app.redeem(v_item, 1);
  v_rid := (r->>'redemption_id')::uuid;
  assert (select qty from app.member_cards
           where member_id = v_kid and kind = 'retro_fullstar') = 1,
    'E1 兑换后应有 1 张补满星卡';
  assert (select points_balance from app.members where id = v_kid) = v_bal - 120,
    'E2 应先扣 120 分';

  perform app.decide_redemption(v_rid, 'rejected', 'tok-013');

  assert (select qty from app.member_cards
           where member_id = v_kid and kind = 'retro_fullstar') = 0,
    'E3 驳回后卡片应收回';
  assert (select points_balance from app.members where id = v_kid) = v_bal,
    format('E4 驳回后积分应退回 %s，实际 %s', v_bal,
           (select points_balance from app.members where id = v_kid));

  raise notice '  [E] 驳回退卡退分 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- F：勋章额外积分奖励 —— 首次获得发一笔，重复评估不再发
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid    uuid := 'f0000000-0000-4000-8000-000000000013';
  v_kid    uuid := 'c0000000-0000-4000-8000-000000000013';
  v_task   uuid := 'd0000000-0000-4000-8000-000000000020';
  v_badge  uuid;
  v_today  date;
  n int; v_sum int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"c1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);
  v_today := app.family_today(v_fid);

  select id into v_badge from app.badges where code = 'first_step' and family_id is null;
  assert v_badge is not null, 'F0 系统勋章 first_step 应存在';

  -- 参考值：013 回填给 first_step 的 5 分
  assert (select points_bonus from app.badges where id = v_badge) = 5,
    format('F0b first_step 参考值应为 5，实际 %s',
           (select points_bonus from app.badges where id = v_badge));

  insert into app.tasks
    (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
     starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
  values
    (v_task, v_fid, v_kid, 'a0000000-0000-4000-8000-000000000013',
     '练字', 'recurring', '{"freq":"daily"}', v_today - 60, 10, 3, 1, true);

  perform app.complete_occurrence(v_task, v_today);

  select count(*), coalesce(sum(l.delta), 0) into n, v_sum
    from app.point_ledger l
    join app.member_badges mb on mb.id = l.source_id
   where l.member_id = v_kid and l.source_type = 'badge'
     and l.entry_kind = 'primary' and mb.badge_id = v_badge;
  assert n = 1, format('F1 首次获得勋章应发 1 笔奖励，实际 %s 笔', n);
  assert v_sum = 5, format('F2 奖励应为 5 分，实际 %s', v_sum);

  -- 重复评估：member_badges 撞唯一约束 → 不返回行 → 不再发分
  perform app.evaluate_badges(v_kid);
  perform app.evaluate_badges(v_kid);
  select count(*) into n
    from app.point_ledger l
    join app.member_badges mb on mb.id = l.source_id
   where l.member_id = v_kid and l.source_type = 'badge'
     and l.entry_kind = 'primary' and mb.badge_id = v_badge;
  assert n = 1, format('F3 重复评估不应重复发分，实际 %s 笔', n);

  raise notice '  [F] 勋章积分奖励（幂等）✓';
end $$;

-- ---------------------------------------------------------------------------
-- G：家长覆盖系统勋章的奖励分（系统勋章本体不能被改）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid   uuid := 'f0000000-0000-4000-8000-000000000013';
  v_badge uuid;
  r jsonb; n int; v_sum int; v_today date; v_t uuid; i int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);

  select id into v_badge from app.badges where code = 'complete_10' and family_id is null;

  -- 覆盖前 = 勋章自带参考值 20
  assert app.badge_points_bonus(v_fid, v_badge) = 20,
    format('G1 覆盖前应取自带值 20，实际 %s', app.badge_points_bonus(v_fid, v_badge));

  r := app.set_badge_bonus('tok-013', v_badge, 77);
  assert (r->>'effective_bonus')::int = 77,
    format('G2 覆盖后有效值应为 77，实际 %s', r->>'effective_bonus');

  -- 系统勋章本体没被动过（别的家庭不受影响）
  assert (select points_bonus from app.badges where id = v_badge) = 20,
    'G3 系统勋章本体不应被改动';

  -- 覆盖已设好（77）。娃当前完成数 = 5（A 2 天 + B 1 天 + C 2 个 once），
  -- 还差 5 个才够 complete_10（阈值 10）。再补 6 个 once 任务凑到 11，
  -- 第 10 个完成时触发解锁，且用的是覆盖后的 77（覆盖先于达成设置）。
  v_today := app.family_today(v_fid);
  for i in 1..6 loop
    v_t := ('d0000000-0000-4000-8000-0000000000' || lpad(i::text, 2, '0'))::uuid;
    insert into app.tasks
      (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
       starts_on, completion_points, checkin_points, checkin_daily_limit, checkin_auto_approve)
    values
      (v_t, v_fid, 'b0000000-0000-4000-8000-000000000013',
       'a0000000-0000-4000-8000-000000000013', '补任务' || i, 'once',
       format('{"freq":"once","date":"%s"}', v_today + 2 + i)::jsonb,
       v_today + 2 + i, 10, 0, 1, true);
    perform set_config('request.jwt.claims',
      '{"sub":"b1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);
    perform app.complete_occurrence(v_t, v_today + 2 + i);
  end loop;

  select count(*), coalesce(sum(l.delta), 0) into n, v_sum
    from app.point_ledger l
    join app.member_badges mb on mb.id = l.source_id
   where l.member_id = 'b0000000-0000-4000-8000-000000000013'
     and l.source_type = 'badge' and l.entry_kind = 'primary'
     and mb.badge_id = v_badge;
  assert n = 1, format('G4 覆盖后应发 1 笔奖励，实际 %s 笔', n);
  assert v_sum = 77, format('G5 覆盖后应发 77 分，实际 %s', v_sum);

  raise notice '  [G] 家长覆盖系统勋章奖励分 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- H：家长调节现金兑换比率（同步到 cash 商品，不影响补卡）
-- ---------------------------------------------------------------------------
do $$
declare
  v_fid uuid := 'f0000000-0000-4000-8000-000000000013';
  r jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-4000-8000-000000000013","role":"authenticated"}', true);

  r := app.set_family_settings('tok-013', 20);
  assert (r->>'cash_rate_points')::int = 20,
    format('H1 比率应改为 20，实际 %s', r->>'cash_rate_points');

  assert (select cash_rate_points from app.families where id = v_fid) = 20, 'H2 家庭设置应落库';

  assert (select rate_points from app.reward_items
           where family_id = v_fid and item_kind = 'cash') = 20,
    'H3 现金商品比率应同步';

  assert (select price_points from app.reward_items
           where family_id = v_fid and card_kind = 'retro_signin') = 30,
    'H4 补卡定价不应被比率影响';

  -- 非法值要被拦
  begin
    perform app.set_family_settings('tok-013', 0);
    assert false, 'H5 比率 0 应报错';
  exception when others then
    null;
  end;

  raise notice '  [H] 兑换比率调节 ✓';
end $$;

rollback;
