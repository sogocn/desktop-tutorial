-- =============================================================================
-- test_skins_019.sql —— 019 皮肤系统
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
-- 整个脚本包在一个事务里，最后 ROLLBACK。所有"今天"从 app.family_today() 取。
--
-- 覆盖：
--   T1  seed_skins 幂等预置 5 个（default/eye_care/pokemon/line_dog/hp_hermione）
--   T2  list_skins 对孩子：默认皮肤 owned=true + current=true，未拥有皮肤 owned=false
--   T3  redeem_skin 兑换宝可梦（200）→ 扣 200、落 member_skins、落 redemption 流水
--   T4  重复兑换 → SKIN_OWNED
--   T5  兑换默认皮肤 → SKIN_DEFAULT_FREE
--   T6  余额不足 → NOT_ENOUGH_POINTS
--   T7  set_member_skin 切到已拥有皮肤 → current；默认皮肤人人可直接"使用"（is_default 免拥有）
--   T8  切到未拥有皮肤 → SKIN_NOT_OWNED
--   T9  list_skins_for_family 带 base_price + 生效 price
--   T10 set_skin_price 家长覆盖家庭价 → skin_price 取新值、本体 base_price 不变
--   T11 bootstrap_state 的 members 带 selected_skin_id，且等于实际所选
-- =============================================================================

begin;

-- 独立家庭，id 带 019 后缀避免撞库
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0000000-0000-4000-8000-000000000019', '皮肤之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role, points_balance) values
  ('a0000000-0000-4000-8000-000000000019', 'f0000000-0000-4000-8000-000000000019',
   'a1000000-0000-4000-8000-000000000019', '爸', 'parent', 0),
  ('b0000000-0000-4000-8000-000000000019', 'f0000000-0000-4000-8000-000000000019',
   'b1000000-0000-4000-8000-000000000019', '娃', 'child', 500);

-- 家长令牌（set_skin_price 用）
insert into app.parent_sessions (token, member_id, expires_at) values
  ('tok-019', 'a0000000-0000-4000-8000-000000000019', now() + interval '2 hours');

-- ---------------------------------------------------------------------------
-- T1 seed_skins 幂等预置 5 个
-- ---------------------------------------------------------------------------
do $$
declare
  n int;
  keys text[];
begin
  -- 末尾的 select app.seed_skins() 在迁移里已跑过；再跑一次验证幂等
  perform app.seed_skins();

  select count(*) into n from app.skins where active;
  assert n = 5, format('T1 应预置 5 个活跃皮肤，实际 %s', n);

  select array_agg(key order by key) into keys from app.skins where active;
  assert keys = array['default','eye_care','hp_hermione','line_dog','pokemon']::text[],
    format('T1 五个 key 应齐全，实际 %s', keys);

  raise notice '  [T1] seed_skins 幂等预置 5 个皮肤 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- T2 list_skins：默认 owned+current，未拥有 owned=false
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_list   jsonb;
  v_def    jsonb;
  v_poke   jsonb;
  v_n      int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  v_list := app.list_skins();
  select jsonb_array_length(v_list) into v_n;
  assert v_n = 5, format('T2 列表应 5 条，实际 %s', v_n);

  select e into v_def
    from jsonb_array_elements(v_list) with ordinality t(e, idx)
   where e->>'key' = 'default';
  assert (v_def->>'owned')::boolean = true, 'T2 默认皮肤应 owned=true';
  assert (v_def->>'current')::boolean = true, 'T2 新用户默认皮肤应 current=true（未选即默认）';

  select e into v_poke
    from jsonb_array_elements(v_list) with ordinality t(e, idx)
   where e->>'key' = 'pokemon';
  assert (v_poke->>'owned')::boolean = false, 'T2 宝可梦未兑换应 owned=false';
  assert (v_poke->>'price')::int = 200, format('T2 宝可梦价应为 200，实际 %s', v_poke->>'price');

  raise notice '  [T2] list_skins 默认owned+current，未拥有owned=false ✓';
end $$;

-- ---------------------------------------------------------------------------
-- T3 redeem_skin 兑换宝可梦 → 扣 200、落拥有、落 redemption 流水
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_cid    uuid := 'b0000000-0000-4000-8000-000000000019';
  v_skin   uuid;
  r        jsonb;
  n        int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  select id into v_skin from app.skins where key = 'pokemon';

  r := app.redeem_skin(v_skin);
  assert (r->>'points_spent')::int = 200, format('T3 应扣 200 分，实际 %s', r->>'points_spent');
  assert (r->>'balance')::int = 300, format('T3 余额应剩 300，实际 %s', r->>'balance');

  select count(*) into n from app.member_skins
   where member_id = v_cid and skin_id = v_skin;
  assert n = 1, format('T3 应落 1 条拥有记录，实际 %s', n);

  select count(*) into n from app.point_ledger
   where member_id = v_cid and source_type = 'redemption'
     and source_id = v_skin and delta = -200;
  assert n = 1, format('T3 应落 1 笔 -200 兑换流水，实际 %s', n);

  raise notice '  [T3] 兑换宝可梦：扣200 + 落拥有 + 流水 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- T4 重复兑换 → SKIN_OWNED
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_skin   uuid;
  ok       boolean := false;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  select id into v_skin from app.skins where key = 'pokemon';
  begin
    perform app.redeem_skin(v_skin);
  exception when others then ok := (sqlerrm like 'SKIN_OWNED%');
  end;
  assert ok, 'T4 重复兑换必须 SKIN_OWNED';

  raise notice '  [T4] 重复兑换被拒（SKIN_OWNED）✓';
end $$;

-- ---------------------------------------------------------------------------
-- T5 兑换默认皮肤 → SKIN_DEFAULT_FREE
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_skin   uuid;
  ok       boolean := false;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  select id into v_skin from app.skins where key = 'default';
  begin
    perform app.redeem_skin(v_skin);
  exception when others then ok := (sqlerrm like 'SKIN_DEFAULT_FREE%');
  end;
  assert ok, 'T5 兑换默认皮肤必须 SKIN_DEFAULT_FREE';

  raise notice '  [T5] 默认皮肤无需兑换（SKIN_DEFAULT_FREE）✓';
end $$;

-- ---------------------------------------------------------------------------
-- T6 余额不足 → NOT_ENOUGH_POINTS
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_cid    uuid := 'b0000000-0000-4000-8000-000000000019';
  v_skin   uuid;
  ok       boolean := false;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  update app.members set points_balance = 10 where id = v_cid;
  select id into v_skin from app.skins where key = 'hp_hermione';
  begin
    perform app.redeem_skin(v_skin);
  exception when others then ok := (sqlerrm like 'NOT_ENOUGH_POINTS%');
  end;
  assert ok, 'T6 余额不足必须 NOT_ENOUGH_POINTS';

  raise notice '  [T6] 余额不足被拒（NOT_ENOUGH_POINTS）✓';
end $$;

-- ---------------------------------------------------------------------------
-- T7 set_member_skin：切到已拥有皮肤 → current；默认皮肤人人可直接"使用"
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_cid    uuid := 'b0000000-0000-4000-8000-000000000019';
  v_poke   uuid;
  v_def    uuid;
  v_list   jsonb;
  v_entry  jsonb;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  -- 余额先恢复到可"使用"已拥有皮肤（切换不扣费，仅校验拥有）
  update app.members set points_balance = 300 where id = v_cid;

  select id into v_poke from app.skins where key = 'pokemon';
  select id into v_def  from app.skins where key = 'default';

  -- 切到已拥有的宝可梦
  perform app.set_member_skin(v_poke);
  assert (select selected_skin_id from app.members where id = v_cid) = v_poke,
    'T7 切到宝可梦后 selected_skin_id 应等于宝可梦';

  v_list := app.list_skins();
  select e into v_entry
    from jsonb_array_elements(v_list) with ordinality t(e, idx)
   where e->>'key' = 'pokemon';
  assert (v_entry->>'current')::boolean = true, 'T7 宝可梦应 current=true';
  select e into v_entry
    from jsonb_array_elements(v_list) with ordinality t(e, idx)
   where e->>'key' = 'default';
  assert (v_entry->>'current')::boolean = false, 'T7 切走后默认皮肤 current 应转 false';

  -- 默认皮肤人人可直接"使用"（is_default，无需拥有）
  perform app.set_member_skin(v_def);
  assert (select selected_skin_id from app.members where id = v_cid) = v_def,
    'T7b 默认皮肤应可直接切回（无需拥有）';

  raise notice '  [T7] 切换皮肤：已拥有可切 + 默认免拥有可直接用 ✓';
end $$;

-- ---------------------------------------------------------------------------
-- T8 切到未拥有皮肤 → SKIN_NOT_OWNED
-- ---------------------------------------------------------------------------
do $$
declare
  v_cuid   text := 'b1000000-0000-4000-8000-000000000019';
  v_skin   uuid;
  ok       boolean := false;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_cuid), true);

  select id into v_skin from app.skins where key = 'hp_hermione'; -- 娃没拥有
  begin
    perform app.set_member_skin(v_skin);
  exception when others then ok := (sqlerrm like 'SKIN_NOT_OWNED%');
  end;
  assert ok, 'T8 切到未拥有皮肤必须 SKIN_NOT_OWNED';

  raise notice '  [T8] 切未拥有皮肤被拒（SKIN_NOT_OWNED）✓';
end $$;

-- ---------------------------------------------------------------------------
-- T9 list_skins_for_family 带 base_price + 生效 price
-- ---------------------------------------------------------------------------
do $$
declare
  v_puid   text := 'a1000000-0000-4000-8000-000000000019';
  v_list   jsonb;
  v_entry  jsonb;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_puid), true);

  v_list := app.list_skins_for_family();
  select e into v_entry
    from jsonb_array_elements(v_list) with ordinality t(e, idx)
   where e->>'key' = 'pokemon';
  assert (v_entry->>'base_price')::int = 200, format('T9 base_price 应为 200，实际 %s', v_entry->>'base_price');
  assert (v_entry->>'price')::int = 200, format('T9 未覆盖时 price=base=200，实际 %s', v_entry->>'price');

  raise notice '  [T9] list_skins_for_family 带 base_price + price ✓';
end $$;

-- ---------------------------------------------------------------------------
-- T10 set_skin_price 家长覆盖家庭价 → skin_price 取新值、本体不变
-- ---------------------------------------------------------------------------
do $$
declare
  v_puid   text := 'a1000000-0000-4000-8000-000000000019';
  v_fid    uuid := 'f0000000-0000-4000-8000-000000000019';
  v_skin   uuid;
  r        jsonb;
  v_list   jsonb;
  v_entry  jsonb;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_puid), true);

  select id into v_skin from app.skins where key = 'pokemon';

  r := app.set_skin_price(v_skin, 999, 'tok-019');
  assert (r->>'price')::int = 999, format('T10 覆盖后应返回 999，实际 %s', r->>'price');

  assert app.skin_price(v_fid, v_skin) = 999, 'T10 skin_price 应取家庭覆盖价 999';
  assert (select price_points from app.skins where id = v_skin) = 200,
    'T10 皮肤本体 base_price 不应被改动';

  -- 余额覆盖后，孩子用 999 计价
  update app.members set points_balance = 300 where id = 'b0000000-0000-4000-8000-000000000019';
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', 'b1000000-0000-4000-8000-000000000019'), true);
  v_list := app.list_skins();
  select e into v_entry
    from jsonb_array_elements(v_list) with ordinality t(e, idx)
   where e->>'key' = 'pokemon';
  assert (v_entry->>'price')::int = 999, format('T10 孩子侧价格应变为 999，实际 %s', v_entry->>'price');

  raise notice '  [T10] 家长定价覆盖家庭价（本体不变）✓';
end $$;

-- ---------------------------------------------------------------------------
-- T11 bootstrap_state 带 selected_skin_id
-- ---------------------------------------------------------------------------
do $$
declare
  v_puid   text := 'a1000000-0000-4000-8000-000000000019';
  v_cid    uuid := 'b0000000-0000-4000-8000-000000000019';
  v_def    uuid;
  v_state  jsonb;
  v_m      jsonb;
begin
  -- T7b 已把娃切回默认皮肤
  select id into v_def from app.skins where key = 'default';

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_puid), true);
  v_state := app.bootstrap_state();

  select e into v_m
    from jsonb_array_elements(v_state->'members') with ordinality t(e, idx)
   where (e->>'id')::uuid = v_cid;

  assert v_m ? 'selected_skin_id', 'T11 bootstrap 的 member 应带 selected_skin_id 字段';
  assert (v_m->>'selected_skin_id')::uuid = v_def,
    format('T11 娃的实际所选应是默认皮肤，实际 %s', v_m->>'selected_skin_id');

  raise notice '  [T11] bootstrap_state 带 selected_skin_id ✓';
end $$;

rollback;
