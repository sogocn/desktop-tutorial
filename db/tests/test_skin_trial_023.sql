-- =============================================================================
-- test_skin_trial_023.sql —— 皮肤试用 1 天（023）
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在事务里，最后 ROLLBACK。
-- =============================================================================

begin;

insert into app.families (id, name, timezone, day_cutoff_hour) values
  ('f0000000-0000-4000-8000-000000000023', '试用之家', 'Asia/Shanghai', 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('a0000000-0000-4000-8000-000000000023', 'f0000000-0000-4000-8000-000000000023',
   'a1000000-0000-4000-8000-000000000023', '爸023', 'parent'),
  ('b0000000-0000-4000-8000-000000000023', 'f0000000-0000-4000-8000-000000000023',
   'b1000000-0000-4000-8000-000000000023', '娃023', 'child');

update app.members set points_balance = 500
 where id = 'b0000000-0000-4000-8000-000000000023';

-- ---------------------------------------------------------------------------
-- R1 付费且未拥有的皮肤可以试用：立即生效、不扣分、不算拥有
-- ---------------------------------------------------------------------------
do $$
declare
  v_kid   uuid := 'b0000000-0000-4000-8000-000000000023';
  v_cuid  text := 'b1000000-0000-4000-8000-000000000023';
  v_poke  uuid;
  v_list  jsonb;
  v_cur   boolean;
  v_owned boolean;
  v_trial boolean;
  v_hours int;
  v_bal   int;
  e       jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_cuid || '","role":"authenticated"}', true);

  select id into v_poke from app.skins where key = 'pokemon';
  e := app.start_skin_trial(v_poke);
  assert (e ->> 'skin_id') = v_poke::text, 'R1a 返回值应带回试用的皮肤 id';

  v_list := app.list_skins(v_kid);
  select (x ->> 'current')::boolean,
         (x ->> 'owned')::boolean,
         (x ->> 'trial_active')::boolean,
         (x ->> 'trial_hours_left')::int
    into v_cur, v_owned, v_trial, v_hours
    from jsonb_array_elements(v_list) x
   where x ->> 'key' = 'pokemon';

  assert v_cur, 'R1b 试用中该皮肤应成为 current（生效皮肤）';
  assert v_trial, 'R1c trial_active 应为 true';
  assert not v_owned, 'R1d 试用不等于拥有，owned 应仍为 false';
  assert v_hours between 23 and 24, format('R1e 试用时长应约 24 小时，实际 %s', v_hours);

  -- 试用不扣积分、也不写 member_skins
  select points_balance into v_bal from app.members where id = v_kid;
  assert v_bal = 500, format('R1f 试用不扣积分，实际余额 %s', v_bal);
  assert not exists (
    select 1 from app.member_skins where member_id = v_kid and skin_id = v_poke),
    'R1g 试用不应写入 member_skins';

  raise notice '✓ R1 付费皮肤可试用：立即生效 / 不扣分 / 不算拥有';
end $$;

-- ---------------------------------------------------------------------------
-- R2 默认皮肤不需要试用
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid text := 'b1000000-0000-4000-8000-000000000023';
  v_def  uuid;
  ok     boolean := false;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_cuid || '","role":"authenticated"}', true);
  select id into v_def from app.skins where key = 'default';

  begin
    perform app.start_skin_trial(v_def);
  exception when others then ok := (sqlerrm like 'SKIN_DEFAULT_FREE%');
  end;
  assert ok, 'R2 默认皮肤试用必须被拒（SKIN_DEFAULT_FREE）';

  raise notice '✓ R2 默认皮肤不可试用（SKIN_DEFAULT_FREE）';
end $$;

-- ---------------------------------------------------------------------------
-- R3~R7 拥有 / 手动切换 / 到期回退 / 重复试用 / 提前结束
-- ---------------------------------------------------------------------------
do $$
declare
  v_kid     uuid := 'b0000000-0000-4000-8000-000000000023';
  v_cuid    text := 'b1000000-0000-4000-8000-000000000023';
  v_dog     uuid;
  v_hp      uuid;
  v_cur_key text;
  ok        boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_cuid || '","role":"authenticated"}', true);
  select id into v_dog from app.skins where key = 'line_dog';
  select id into v_hp  from app.skins where key = 'hp_hermione';

  -- 先拥有线条小狗并切过去；按规则这会主动结束宝可梦的试用
  insert into app.member_skins (member_id, skin_id) values (v_kid, v_dog);
  perform app.set_member_skin(v_dog);

  -- R6 手动切换到已拥有的皮肤 = 主动结束试用
  select x ->> 'key' into v_cur_key
    from jsonb_array_elements(app.list_skins(v_kid)) x
   where (x ->> 'current')::boolean;
  assert v_cur_key = 'line_dog', format('R6a 切换后生效皮肤应为 line_dog，实际 %s', v_cur_key);
  assert not exists (
    select 1 from jsonb_array_elements(app.list_skins(v_kid)) x
     where (x ->> 'trial_active')::boolean),
    'R6b 切换后不应再有处于试用中的皮肤';

  -- R3 已拥有的皮肤不能试用
  ok := false;
  begin
    perform app.start_skin_trial(v_dog);
  exception when others then ok := (sqlerrm like 'SKIN_OWNED%');
  end;
  assert ok, 'R3 已拥有的皮肤试用必须被拒（SKIN_OWNED）';

  -- 改用哈利波特做后续验证
  perform app.start_skin_trial(v_hp);
  select x ->> 'key' into v_cur_key
    from jsonb_array_elements(app.list_skins(v_kid)) x
   where (x ->> 'current')::boolean;
  assert v_cur_key = 'hp_hermione',
    format('R5a 试用中生效皮肤应为 hp_hermione，实际 %s', v_cur_key);

  -- R5 到期自动回退：把到期时间拨到过去，无需任何定时任务
  update app.members set trial_until = now() - interval '2 hours' where id = v_kid;
  select x ->> 'key' into v_cur_key
    from jsonb_array_elements(app.list_skins(v_kid)) x
   where (x ->> 'current')::boolean;
  assert v_cur_key = 'line_dog',
    format('R5b 到期后应自动回退到已拥有的 line_dog，实际 %s', v_cur_key);
  assert not exists (
    select 1 from jsonb_array_elements(app.list_skins(v_kid)) x
     where (x ->> 'trial_active')::boolean),
    'R5c 到期后不应再有 trial_active 的皮肤';

  -- R4 同一皮肤不能重复试用
  ok := false;
  begin
    perform app.start_skin_trial(v_hp);
  exception when others then ok := (sqlerrm like 'SKIN_TRIAL_USED%');
  end;
  assert ok, 'R4 同一皮肤重复试用必须被拒（SKIN_TRIAL_USED）';

  raise notice '✓ R3 已拥有不可试用（SKIN_OWNED）';
  raise notice '✓ R4 重复试用被拒（SKIN_TRIAL_USED）';
  raise notice '✓ R5 到期自动回退，无需定时任务';
  raise notice '✓ R6 手动切换已拥有皮肤会结束试用';
end $$;

-- ---------------------------------------------------------------------------
-- R8 一次只能试用一张：想换一张必须先结束当前的，否则会把前一张的试用名额白白吃掉
-- ---------------------------------------------------------------------------
do $$
declare
  v_kid     uuid := 'b0000000-0000-4000-8000-000000000023';
  v_cuid    text := 'b1000000-0000-4000-8000-000000000023';
  v_eye     uuid;
  v_hp      uuid;
  v_cur_key text;
  ok        boolean;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_cuid || '","role":"authenticated"}', true);
  select id into v_eye from app.skins where key = 'eye_care';
  select id into v_hp  from app.skins where key = 'hp_hermione';

  -- hp 的试用名额在 R4 里已消耗，这里清掉只为造出"还有未试用的皮肤"这个条件
  delete from app.skin_trials where member_id = v_kid and skin_id = v_hp;

  perform app.start_skin_trial(v_eye);
  ok := false;
  begin
    perform app.start_skin_trial(v_hp);
  exception when others then ok := (sqlerrm like 'SKIN_TRIAL_ACTIVE%');
  end;
  assert ok, 'R8a 试用期间再开另一张必须被拒（SKIN_TRIAL_ACTIVE）';

  select x ->> 'key' into v_cur_key
    from jsonb_array_elements(app.list_skins(v_kid)) x
   where (x ->> 'current')::boolean;
  assert v_cur_key = 'eye_care',
    format('R8b 被拒后当前试用的仍应是 eye_care，实际 %s', v_cur_key);

  -- 结束后才允许开新的：验证"先结束再换"这条路走得通
  perform app.end_skin_trial();
  perform app.start_skin_trial(v_hp);
  select x ->> 'key' into v_cur_key
    from jsonb_array_elements(app.list_skins(v_kid)) x
   where (x ->> 'current')::boolean;
  assert v_cur_key = 'hp_hermione',
    format('R8c 结束旧试用后应能开新的，实际 %s', v_cur_key);
  perform app.end_skin_trial();

  raise notice '✓ R8 一次只能试用一张（SKIN_TRIAL_ACTIVE），结束后可换新的';
end $$;

-- ---------------------------------------------------------------------------
-- R7 end_skin_trial() 可提前结束试用
-- ---------------------------------------------------------------------------
do $$
declare
  v_kid     uuid := 'b0000000-0000-4000-8000-000000000023';
  v_cuid    text := 'b1000000-0000-4000-8000-000000000023';
  v_poke    uuid;
  v_cur_key text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_cuid || '","role":"authenticated"}', true);
  select id into v_poke from app.skins where key = 'pokemon';

  -- 前面 R1 已用过宝可梦的试用名额，这里清掉历史只为验证"提前结束"这条路径
  delete from app.skin_trials where member_id = v_kid and skin_id = v_poke;
  perform app.start_skin_trial(v_poke);
  perform app.end_skin_trial();

  select x ->> 'key' into v_cur_key
    from jsonb_array_elements(app.list_skins(v_kid)) x
   where (x ->> 'current')::boolean;
  assert v_cur_key = 'line_dog',
    format('R7 提前结束后应回到 line_dog，实际 %s', v_cur_key);

  raise notice '✓ R7 end_skin_trial() 可提前结束并回退';
end $$;

rollback;
