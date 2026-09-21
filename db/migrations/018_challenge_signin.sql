-- =============================================================================
-- 018_challenge_signin.sql —— 新增「连续签到」类挑战
-- =============================================================================
-- 用户 2026-09-21 口径：连续签到与满星类似，但只有约 1/3 的入场分与奖励。
--   满星 21 天 → 入场 20 / 奖励 100；满星 45 天 → 入场 30 / 奖励 300
--   签到 21 天 → 入场 7  / 奖励 33 ；签到 45 天 → 入场 10 / 奖励 100
--   窗口 / 达标 / 容错沿用满星口径（21: ≥20/容错1；45: ≥42/容错3）。
--   奖励卡：签到21 → 补签卡(retro_signin)；签到45 → 补满星卡(retro_fullstar)。
--
-- 与满星对称的设计：
--   * 判定维度从 member_day.fullstar 换成 member_day.signed（补签卡 retro_signin
--     同样把那天 signed 点亮，所以"漏"的算法天然兼容）。
--   * 失败补救卡：签到类买 retro_signin、满星类买 retro_fullstar（都用既有能力）。
--   * 仍走 017 的按类互斥：signin / fullstar 各算一类，可并行、可重复开始。
-- =============================================================================


-- ###########################################################################
-- 一、规格（单一真相源，前端展示 + 后端判定共用）
-- ###########################################################################
create or replace function app._challenge_spec(p_kind text)
returns jsonb
language plpgsql immutable security definer set search_path = app, public as $$
begin
  if p_kind = 'fullstar_21' then
    return jsonb_build_object(
      'kind', 'fullstar_21', 'title', '21天满星挑战',
      'window_days', 21, 'required_fullstar', 20, 'allowed_miss', 1,
      'entry_fee', 20, 'reward_points', 100,
      'reward_card', 'retro_signin', 'reward_card_label', '补签卡');
  elsif p_kind = 'fullstar_45' then
    return jsonb_build_object(
      'kind', 'fullstar_45', 'title', '45天满星挑战',
      'window_days', 45, 'required_fullstar', 42, 'allowed_miss', 3,
      'entry_fee', 30, 'reward_points', 300,
      'reward_card', 'retro_fullstar', 'reward_card_label', '补满星卡');
  elsif p_kind = 'signin_21' then
    return jsonb_build_object(
      'kind', 'signin_21', 'title', '21天签到挑战',
      'window_days', 21, 'required_fullstar', 20, 'allowed_miss', 1,
      'entry_fee', 7, 'reward_points', 33,
      'reward_card', 'retro_signin', 'reward_card_label', '补签卡');
  elsif p_kind = 'signin_45' then
    return jsonb_build_object(
      'kind', 'signin_45', 'title', '45天签到挑战',
      'window_days', 45, 'required_fullstar', 42, 'allowed_miss', 3,
      'entry_fee', 10, 'reward_points', 100,
      'reward_card', 'retro_fullstar', 'reward_card_label', '补满星卡');
  end if;
  raise exception 'BAD_CHALLENGE_KIND: % 不是有效的挑战类型', p_kind;
end $$;


-- ###########################################################################
-- 二、单条挑战的实时评估（按类选维度 + 每类专属补救卡）
-- ###########################################################################
create or replace function app._challenge_eval(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me       app.members%rowtype;
  c        app.challenges%rowtype;
  spec     jsonb;
  v_today  date;
  v_win    int; v_req int; v_allow int;
  v_elapsed int; v_full_all int; v_full_done int; v_days_done int; v_missed int;
  v_rescue date;
  v_just   boolean := false;
  v_metric text;     -- 该类统计的 member_day 维度：signed / fullstar
  v_retro  text;     -- 该类失败补救要买的卡：retro_signin / retro_fullstar
  v_card   record;
begin
  me := app.require_member();
  select * into c from app.challenges where id = p_id and member_id = me.id;
  if not found then return null; end if;

  -- 没有对应规格的行（例如规格还没上线的类）直接跳过：读路径不能因为一条
  -- 认不出的历史行就整个报错。开启侧 start_challenge 仍然严格校验 kind。
  begin
    spec := app._challenge_spec(c.kind);
  exception when others then
    if sqlerrm like 'BAD_CHALLENGE_KIND%' then return null; end if;
    raise;
  end;

  v_win   := (spec->>'window_days')::int;
  v_req   := (spec->>'required_fullstar')::int;
  v_allow := (spec->>'allowed_miss')::int;
  v_today := app.family_today(me.family_id);
  v_elapsed := least(v_today - c.started_on + 1, v_win);
  -- 签到类统计 signed，满星类统计 fullstar
  v_metric := case c.category when 'signin' then 'signed' else 'fullstar' end;
  v_retro  := case c.category when 'signin' then 'retro_signin' else 'retro_fullstar' end;

  if c.status = 'active' then
    -- 窗口内到今天为止的"达标"天数（今天达成当场就能触发成功）
    select count(*) into v_full_all from app.member_day
     where member_id = me.id
       and day >= c.started_on and day <= least(v_today, c.ends_on)
       and (case v_metric when 'signed' then signed else fullstar end);
    -- "漏"只算今天之前已尘埃落定的日子：今天还没做完不算漏。
    -- 上界取 min(昨天, 窗口末)，窗口结束后不会再越界累加成 30/50 这种数。
    v_days_done := greatest(least(v_today - 1, c.ends_on) - c.started_on + 1, 0);
    select count(*) into v_full_done from app.member_day
     where member_id = me.id
       and day >= c.started_on and day <= least(v_today - 1, c.ends_on)
       and (case v_metric when 'signed' then signed else fullstar end);
    v_missed := greatest(v_days_done - v_full_done, 0);

    if v_full_all >= v_req then
      update app.challenges
         set status = 'succeeded', fullstar_days = v_full_all,
             missed_days = v_missed, decided_at = now()
       where id = c.id and status = 'active';
      if found then
        perform app._post_ledger(me.id, (spec->>'reward_points')::int,
                                 'challenge', c.id, 1,
                                 '挑战成功：' || (spec->>'title'), null, me.id);
        insert into app.member_cards (member_id, kind, qty)
        values (me.id, spec->>'reward_card', 1)
        on conflict (member_id, kind) do update
           set qty = member_cards.qty + 1, updated_at = now();
        v_just := true;
        select * into c from app.challenges where id = c.id;
      end if;
    elsif v_today > c.ends_on then
      update app.challenges
         set status = 'failed', fullstar_days = v_full_all,
             missed_days = v_missed, decided_at = now()
       where id = c.id and status = 'active';
      select * into c from app.challenges where id = c.id;
    end if;
  end if;

  -- 补救目标日：窗口内今天之前最近的一个未达标日（买卡后补它；
  -- 取最近的而非最早的，因为 use_retro_card 只能补最近 30 天）
  select max(d) into v_rescue
    from generate_series(c.started_on, least(v_today - 1, c.ends_on), '1 day') d
   where not exists (select 1 from app.member_day md
                      where md.member_id = me.id and md.day = d
                        and (case v_metric when 'signed' then md.signed else md.fullstar end));

  -- 该类失败补救要买的卡（价格家长可调；没有则前端隐藏"购买补救"入口）
  select id, name, price_points into v_card
    from app.reward_items
   where family_id = me.family_id and item_kind = 'card'
     and card_kind = v_retro and active
   order by sort_order
   limit 1;

  return jsonb_build_object(
    'id', c.id, 'kind', c.kind, 'category', c.category,
    'category_label', app._challenge_category_label(c.category),
    'status', c.status,
    'started_on', c.started_on, 'ends_on', c.ends_on,
    'window_days', v_win, 'required_fullstar', v_req, 'allowed_miss', v_allow,
    'elapsed', v_elapsed,
    'fullstar_days', coalesce(c.fullstar_days, v_full_all),
    'missed_days', coalesce(c.missed_days, v_missed),
    'remaining_days', greatest(v_win - v_elapsed, 0),
    'failing', c.status = 'active' and v_missed > v_allow,
    'latest_missed_day', v_rescue,
    'entry_fee', c.entry_fee,
    'reward_points', (spec->>'reward_points')::int,
    'reward_card_label', spec->>'reward_card_label',
    'retro_card_item', case when v_card.id is null then null else
      jsonb_build_object('id', v_card.id, 'name', v_card.name,
                         'price', v_card.price_points, 'kind', v_retro) end,
    'just_succeeded', v_just);
end $$;


-- ###########################################################################
-- 三、挑战状态：可开规格 + 每类一条 current
-- ###########################################################################
create or replace function app.challenge_state()
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me         app.members%rowtype;
  v_cat      text;
  v_cid      uuid;
  v_cur      jsonb;
  v_currents jsonb := '[]'::jsonb;
  v_specs    jsonb := '[]'::jsonb;
  v_spec     jsonb;
  v_kind     text;
  v_item     record;
  v_current  jsonb := null;
begin
  me := app.require_member();

  for v_cat in
    select distinct category from app.challenges where member_id = me.id
  loop
    select id into v_cid from app.challenges
     where member_id = me.id and category = v_cat
     order by (status = 'active') desc, created_at desc
     limit 1;
    v_cur := app._challenge_eval(v_cid);
    if v_cur is not null then
      v_currents := v_currents || v_cur;
    end if;
  end loop;

  if jsonb_array_length(v_currents) > 0 then
    select c into v_current
      from jsonb_array_elements(v_currents) c
     order by (c->>'status' = 'active') desc
     limit 1;
  end if;

  foreach v_kind in array array['fullstar_21', 'fullstar_45', 'signin_21', 'signin_45'] loop
    v_spec := app._challenge_spec(v_kind);
    v_cat  := app._challenge_category(v_kind);
    v_spec := v_spec || jsonb_build_object(
      'category', v_cat,
      'category_label', app._challenge_category_label(v_cat),
      'busy', exists (select 1 from app.challenges ch
                       where ch.member_id = me.id
                         and ch.category = v_cat
                         and ch.status = 'active'));
    v_specs := v_specs || v_spec;
  end loop;

  -- 商城在售的补满星卡（兼容字段，满星类补救；无规格/未上架则 null）
  select id, name, price_points into v_item
    from app.reward_items
   where family_id = me.family_id and item_kind = 'card'
     and card_kind = 'retro_fullstar' and active
   order by sort_order
   limit 1;

  return jsonb_build_object(
    'specs', v_specs,
    'currents', v_currents,
    'current', v_current,
    'fullstar_card_item', case when v_item.id is null then null else
      jsonb_build_object('id', v_item.id, 'name', v_item.name,
                         'price', v_item.price_points) end);
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
