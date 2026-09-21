-- =============================================================================
-- 017_challenge_category.sql —— 挑战按「类」互斥（连续签到 / 连续满星）
-- =============================================================================
-- 规则变更（用户 2026-09-21 口径）：
--   * 挑战可以重复开始（成功/失败后再开新的），但**同一类同一时间只能有一个进行中**。
--   * 「类」= fullstar（连续满星）/ signin（连续签到）。21 天和 45 天都属 fullstar 类，
--     所以它们互相仍然互斥；将来加的签到类挑战与满星类可以同时进行。
--
-- 实现：
--   * 新增 challenge 行的 category 列（由 kind 前缀派生，写入时算好并落库，不依赖触发器）。
--   * 部分唯一索引从 (member_id) 改成 (member_id, category) where status='active' ——
--     终局（succeeded/failed）的行不受约束，因此"重复开始"天然被允许。
--   * start_challenge 的互斥检查从"有任何进行中"改成"本类有进行中"。
--   * challenge_state 由「一条 current」升级为「每类一条 currents」，供前端按类渲染；
--     保留 current 字段作兼容（= currents 里优先 active 的那条），旧断言不受影响。
--   * kind 的 check 放宽为前缀+天数模式，将来新增 signin_* 只需改 _challenge_spec，
--     不必再动表结构。
-- =============================================================================


-- ###########################################################################
-- 一、kind → category（前缀映射，单一真相源）
-- ###########################################################################
create or replace function app._challenge_category(p_kind text)
returns text
language plpgsql immutable security definer set search_path = app, public as $$
begin
  if p_kind like 'fullstar\_%' then return 'fullstar'; end if;
  if p_kind like 'signin\_%'  then return 'signin';   end if;
  raise exception 'BAD_CHALLENGE_KIND: % 不是有效的挑战类型', p_kind;
end $$;

create or replace function app._challenge_category_label(p_cat text)
returns text
language plpgsql immutable security definer set search_path = app, public as $$
begin
  return case p_cat
    when 'fullstar' then '连续满星'
    when 'signin'   then '连续签到'
    else p_cat
  end;
end $$;


-- ###########################################################################
-- 二、表结构：加 category + 索引改按类
-- ###########################################################################
-- kind 放宽成「前缀_天数」，为签到类预留空位
alter table app.challenges drop constraint if exists challenges_kind_check;
alter table app.challenges add constraint challenges_kind_check
  check (kind ~ '^(fullstar|signin)_[0-9]+$');

alter table app.challenges add column if not exists category text;
-- 回填历史行（016 上线后到 017 之间产生的数据）
update app.challenges
   set category = app._challenge_category(kind)
 where category is null or category <> app._challenge_category(kind);
alter table app.challenges alter column category set not null;

-- 一人一类一个进行中；结束的挑战不参与，所以可以重复开始
drop index if exists app.challenge_one_active_uq;
create unique index if not exists challenge_active_per_category_uq
  on app.challenges (member_id, category) where status = 'active';


-- ###########################################################################
-- 三、开启挑战（按类互斥）
-- ###########################################################################
create or replace function app.start_challenge(p_kind text)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  spec    jsonb;
  v_cat   text;
  v_today date;
  v_fee   int;
  v_bal   int;
  v_id    uuid;
begin
  me    := app.require_member();
  spec  := app._challenge_spec(p_kind);
  v_cat := app._challenge_category(p_kind);
  v_fee := (spec->>'entry_fee')::int;
  v_today := app.family_today(me.family_id);

  if exists (select 1 from app.challenges
              where member_id = me.id and category = v_cat and status = 'active') then
    raise exception 'CHALLENGE_ACTIVE: 已有进行中的%s挑战，先完成或等它结束',
      app._challenge_category_label(v_cat);
  end if;

  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < v_fee then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', v_fee - v_bal;
  end if;

  insert into app.challenges (family_id, member_id, kind, category, started_on, ends_on, entry_fee)
  values (me.family_id, me.id, p_kind, v_cat, v_today,
          v_today + ((spec->>'window_days')::int - 1), v_fee)
  returning id into v_id;

  perform app._post_ledger(me.id, -v_fee, 'challenge', v_id, 0,
                           '开启' || (spec->>'title'), null, me.id);

  return jsonb_build_object(
    'challenge_id', v_id,
    'kind', p_kind,
    'category', v_cat,
    'status', 'active',
    'started_on', v_today,
    'ends_on', v_today + ((spec->>'window_days')::int - 1),
    'entry_fee', v_fee,
    'balance', (select points_balance from app.members where id = me.id));
end $$;


-- ###########################################################################
-- 四、单条挑战的实时评估（从 challenge_state 里抽出来，按类循环调用）
-- ###########################################################################
-- 负责：派生进度 / 惰性判成功并发奖 / 窗口结束判终局失败 / 计算补救目标日。
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

  if c.status = 'active' then
    -- 窗口内到今天为止的满星数（今天达成当场就能触发成功）
    select count(*) into v_full_all from app.member_day
     where member_id = me.id
       and day >= c.started_on and day <= least(v_today, c.ends_on)
       and fullstar;
    -- "漏"只算今天之前已尘埃落定的日子：今天还没做完不算漏。
    -- 上界取 min(昨天, 窗口末)，窗口结束后不会再越界累加成 30/50 这种数。
    v_days_done := greatest(least(v_today - 1, c.ends_on) - c.started_on + 1, 0);
    select count(*) into v_full_done from app.member_day
     where member_id = me.id
       and day >= c.started_on and day <= least(v_today - 1, c.ends_on)
       and fullstar;
    v_missed := greatest(v_days_done - v_full_done, 0);

    if v_full_all >= v_req then
      -- 成功：惰性落库 + 发奖（update 条件保证只结一次，账本唯一约束兜底）
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
      -- 窗口结束仍未达标 → 终局失败
      update app.challenges
         set status = 'failed', fullstar_days = v_full_all,
             missed_days = v_missed, decided_at = now()
       where id = c.id and status = 'active';
      select * into c from app.challenges where id = c.id;
    end if;
  end if;

  -- 补救目标日：窗口内今天之前最近的一个非满星日（买卡后补它；
  -- 取最近的而非最早的，因为 use_retro_card 只能补最近 30 天）
  select max(d) into v_rescue
    from generate_series(c.started_on, least(v_today - 1, c.ends_on), '1 day') d
   where not exists (select 1 from app.member_day md
                      where md.member_id = me.id and md.day = d and md.fullstar);

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
    'just_succeeded', v_just);
end $$;


-- ###########################################################################
-- 五、挑战状态：每类一条 current
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

  -- 每个类各取一条「当前」：优先进行中的那条，没有才回落到最近一条已结束的。
  -- 显式把 active 排前面而不是只按 created_at：now() 在事务里是事务开始时间，
  -- 同一事务内开两条挑战会撞出完全相同的 created_at，纯按时间排序结果不确定。
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

  -- current：兼容字段（单类场景 = currents 里优先 active 的那条）
  if jsonb_array_length(v_currents) > 0 then
    select c into v_current
      from jsonb_array_elements(v_currents) c
     order by (c->>'status' = 'active') desc
     limit 1;
  end if;

  -- 可开的规格（带该类是否已在进行中，前端据此禁用按钮）
  foreach v_kind in array array['fullstar_21', 'fullstar_45'] loop
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

  -- 商城在售的补满星卡（价格家长可调；没有则前端隐藏"购买补救"入口）
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
