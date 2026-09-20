-- =============================================================================
-- 016_challenge.sql —— 满星挑战（21天 / 45天）
-- =============================================================================
-- 需求（2026-09-20 与用户确认的口径）：
--   * 孩子付积分开启挑战：21天满星挑战 −20 分；45天满星挑战 −30 分。
--   * 21天：窗口 21 天，累计 ≥20 天满星即成功；漏满星 ≥2 天 → 数学上不可能 → 失败预警。
--   * 45天：窗口 45 天，累计 ≥42 天满星即成功；漏满星 ≥4 天 → 失败预警（允许漏 3 天）。
--   * 成功奖励：21天 +100 分 + 补签卡 1 张；45天 +300 分 + 补满星卡 1 张。
--   * 失败预警时询问是否购买满星卡：直接复用 013 商城的补满星卡商品（redeem）
--     + 010 的 use_retro_card 把漏掉那天补成满星 → 挑战恢复可行，零新增购买逻辑。
--   * 孩子可以看到挑战进度。
--
-- 关键设计：
--   * 判定全部从 app.member_day.fullstar 派生；挑战表只存窗口和最终结论，不逐日记账
--     —— 买卡补漏后满星数自然回升，无需任何"复活"逻辑。
--   * 失败分两级：failing（派生预警，可买卡补救）→ 窗口结束仍未达标才落 status='failed'
--     （终局，可重新付积分再开）。今天还没过完不算"漏"，避免当天下午就被误判。
--   * 成功在 challenge_state 读取时惰性落库发奖；uq_ledger_source 唯一约束
--     + update ... where status='active' 双保险，并发读也不会重复发奖发卡。
-- =============================================================================


-- ###########################################################################
-- 一、流水来源枚举扩容（沿用 010 的 drop/add 幂等写法）
-- ###########################################################################
alter table app.point_ledger drop constraint if exists point_ledger_source_type_check;
alter table app.point_ledger add constraint point_ledger_source_type_check
  check (source_type in ('checkin', 'completion', 'milestone', 'manual', 'redemption',
                         'badge', 'reversal', 'signin', 'streak', 'challenge'));


-- ###########################################################################
-- 二、表
-- ###########################################################################
create table app.challenges (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app.families(id) on delete cascade,
  member_id    uuid not null references app.members(id) on delete cascade,
  kind         text not null check (kind in ('fullstar_21', 'fullstar_45')),
  status       text not null default 'active'
                 check (status in ('active', 'succeeded', 'failed')),
  started_on   date not null,
  ends_on      date not null,
  entry_fee    int  not null,
  -- 终局时定格的统计（active 期间以 challenge_state 现算为准）
  fullstar_days int,
  missed_days   int,
  decided_at    timestamptz,
  created_at    timestamptz not null default now()
);
-- 同一成员同一时间只能有一个进行中的挑战（成功/失败后可再开新的）
create unique index challenge_one_active_uq on app.challenges (member_id) where status = 'active';
create index challenge_member_idx on app.challenges (member_id, created_at desc);


-- ###########################################################################
-- 三、权限 + RLS（照 010 的模式）
-- ###########################################################################
grant select on app.challenges to authenticated;
grant all   on app.challenges to service_role;

alter table app.challenges enable row level security;

drop policy if exists challenges_select on app.challenges;
create policy challenges_select on app.challenges for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = challenges.member_id
                    and m.family_id = app.current_family_id()));


-- ###########################################################################
-- 四、挑战规格（单一真相源，前端展示与后端判定共用）
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
  end if;
  raise exception 'BAD_CHALLENGE_KIND: % 不是有效的挑战类型', p_kind;
end $$;


-- ###########################################################################
-- 五、开启挑战（扣入场分）
-- ###########################################################################
create or replace function app.start_challenge(p_kind text)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  spec    jsonb;
  v_today date;
  v_fee   int;
  v_bal   int;
  v_id    uuid;
begin
  me   := app.require_member();
  spec := app._challenge_spec(p_kind);
  v_fee := (spec->>'entry_fee')::int;
  v_today := app.family_today(me.family_id);

  if exists (select 1 from app.challenges where member_id = me.id and status = 'active') then
    raise exception 'CHALLENGE_ACTIVE: 已有进行中的挑战，先完成或等它结束';
  end if;

  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < v_fee then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', v_fee - v_bal;
  end if;

  insert into app.challenges (family_id, member_id, kind, started_on, ends_on, entry_fee)
  values (me.family_id, me.id, p_kind, v_today,
          v_today + ((spec->>'window_days')::int - 1), v_fee)
  returning id into v_id;

  perform app._post_ledger(me.id, -v_fee, 'challenge', v_id, 0,
                           '开启' || (spec->>'title'), null, me.id);

  return jsonb_build_object(
    'challenge_id', v_id,
    'kind', p_kind,
    'status', 'active',
    'started_on', v_today,
    'ends_on', v_today + ((spec->>'window_days')::int - 1),
    'entry_fee', v_fee,
    'balance', (select points_balance from app.members where id = me.id));
end $$;


-- ###########################################################################
-- 六、挑战状态（进度 + 惰性判定发奖）
-- ###########################################################################
-- 一次调用拿全：可开的挑战规格 / 当前（或最近一次）挑战的实时进度 /
-- 商城里在售的补满星卡（失败预警时"购买满星卡"直接兑它，价格家长可调）。
create or replace function app.challenge_state()
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me        app.members%rowtype;
  c         app.challenges%rowtype;
  spec      jsonb;
  v_today   date;
  v_win     int; v_req int; v_allow int;
  v_elapsed int; v_full_all int; v_full_done int; v_days_done int; v_missed int;
  v_rescue  date;
  v_just    boolean := false;
  v_item    record;
  v_current jsonb;
begin
  me := app.require_member();
  v_today := app.family_today(me.family_id);

  -- 「当前」= 优先进行中的那条；没有才回落到最近一条已结束的。
  -- 显式把 active 排前面而不是只按 created_at：now() 在事务里是事务开始时间，
  -- 同一事务内开两条挑战会撞出完全相同的 created_at，纯按时间排序结果不确定。
  select * into c from app.challenges
   where member_id = me.id
   order by (status = 'active') desc, created_at desc
   limit 1;

  if found then
    spec   := app._challenge_spec(c.kind);
    v_win   := (spec->>'window_days')::int;
    v_req   := (spec->>'required_fullstar')::int;
    v_allow := (spec->>'allowed_miss')::int;
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

    v_current := jsonb_build_object(
      'id', c.id, 'kind', c.kind, 'status', c.status,
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
  else
    v_current := null;
  end if;

  -- 商城在售的补满星卡（价格家长可调；没有则前端隐藏"购买补救"入口）
  select id, name, price_points into v_item
    from app.reward_items
   where family_id = me.family_id and item_kind = 'card'
     and card_kind = 'retro_fullstar' and active
   order by sort_order
   limit 1;

  return jsonb_build_object(
    'specs', jsonb_build_array(app._challenge_spec('fullstar_21'),
                               app._challenge_spec('fullstar_45')),
    'current', v_current,
    'fullstar_card_item', case when v_item.id is null then null else
      jsonb_build_object('id', v_item.id, 'name', v_item.name,
                         'price', v_item.price_points) end);
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
