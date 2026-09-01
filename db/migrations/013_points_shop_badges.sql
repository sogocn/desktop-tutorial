-- =============================================================================
-- 013_points_shop_badges.sql —— 单次完成计分 / 现金比率 / 补卡兑换 / 勋章积分奖励
-- =============================================================================
-- 五条需求，全部落在这一层：
--
--   1) 单次完成发「单次分」，不再是整任务的完成分。
--      once（一次性任务）完成当日 = 完成全部 → 完成分
--      循环 / 期限任务             → 单次分（= 一次打卡的分）
--      完成分（completion_points）只在「完成全部」时额外发一笔结清奖励。
--      完成全部 = 各日单次分之和 + 一笔完成分 → 永远不比逐日做吃亏。
--
--   2) 现金兑换比率 10 积分 = 1 元（原 100 分/元），落到 families.cash_rate_points，
--      家长可调，改的时候同步所有 cash 商品的 rate_points。
--
--   3) 商城新增补签卡 / 补活跃卡 / 补满星卡（reward_items.item_kind='card'），
--      兑换后直接发到 member_cards；家长驳回时卡和分一起退。
--
--   4) 勋章可以有额外积分奖励（badges.points_bonus），首次获得时发一笔
--      source_type='badge' 的流水，幂等（member_badges 唯一约束兜底）。
--
--   5) 家长可调节：现金比率 + 每一枚勋章的奖励分。
--      系统勋章所有家庭共享不能改 → 用 badge_family_settings 覆盖。
--      所有奖励按获取难度预置了参考值（见文件末尾回填段）。
-- =============================================================================


-- ###########################################################################
-- 一、表 / 列
-- ###########################################################################

-- 家庭级现金比率：多少积分换 1 元
alter table app.families add column if not exists cash_rate_points int not null default 10;
alter table app.families drop constraint if exists families_cash_rate_points_check;
alter table app.families add constraint families_cash_rate_points_check
  check (cash_rate_points > 0);

-- 商品类型：goods 普通 / cash 现金 / card 补卡
alter table app.reward_items add column if not exists item_kind text not null default 'goods';
alter table app.reward_items add column if not exists card_kind text;

alter table app.reward_items drop constraint if exists reward_items_item_kind_check;
alter table app.reward_items add constraint reward_items_item_kind_check
  check (item_kind in ('goods', 'cash', 'card'));

alter table app.reward_items drop constraint if exists reward_items_card_kind_check;
alter table app.reward_items add constraint reward_items_card_kind_check
  check (card_kind is null
         or card_kind in ('retro_signin', 'retro_active', 'retro_fullstar'));

-- 是 card 就一定要有 card_kind，不是就一定不能有
alter table app.reward_items drop constraint if exists reward_items_card_shape;
alter table app.reward_items add constraint reward_items_card_shape
  check ((item_kind = 'card') = (card_kind is not null));

-- 勋章积分奖励。系统勋章给参考值，家庭勋章家长自己定
alter table app.badges add column if not exists points_bonus int not null default 0;
alter table app.badges drop constraint if exists badges_points_bonus_check;
alter table app.badges add constraint badges_points_bonus_check
  check (points_bonus >= 0);

-- 家庭对系统勋章的覆盖。系统勋章（family_id is null）是全局共享的，
-- 任何家庭都不能直接改它的 points_bonus，只能在这里盖一层自己的值。
create table if not exists app.badge_family_settings (
  family_id    uuid not null references app.families(id) on delete cascade,
  badge_id     uuid not null references app.badges(id) on delete cascade,
  points_bonus int  not null default 0 check (points_bonus >= 0),
  updated_at   timestamptz not null default now(),
  constraint pk_badge_family_settings primary key (family_id, badge_id)
);

grant select on app.badge_family_settings to authenticated;
grant all    on app.badge_family_settings to service_role;
alter table app.badge_family_settings enable row level security;
drop policy if exists badge_family_settings_select on app.badge_family_settings;
create policy badge_family_settings_select on app.badge_family_settings
  for select to authenticated
  using (family_id = app.current_family_id());


-- ###########################################################################
-- 二、单次分口径（完成当日 / 完成全部 共用，避免两边算得不一样）
-- ###########################################################################
--   once           → 完成分（一次性任务，完成当日就是完成全部）
--   开了打卡的循环/期限 → 打卡分（一次完成 = 一次打卡）
--   没开打卡的循环/期限 → 完成分（这类任务没有"单次"概念，沿用旧口径）
create or replace function app.task_single_points(
  p_schedule_kind     text,
  p_checkin_points    int,
  p_completion_points int
)
returns int
language sql immutable set search_path = app, public as $$
  select case
    when p_schedule_kind = 'once'                then coalesce(p_completion_points, 0)
    when coalesce(p_checkin_points, 0) > 0       then p_checkin_points
    else                                              coalesce(p_completion_points, 0)
  end
$$;


-- ###########################################################################
-- 三、勋章奖励
-- ###########################################################################

-- 有效奖励 = 家庭覆盖值 > 勋章自带值
create or replace function app.badge_points_bonus(p_family_id uuid, p_badge_id uuid)
returns int
language sql stable security definer set search_path = app, public as $$
  select coalesce(s.points_bonus, b.points_bonus, 0)
    from app.badges b
    left join app.badge_family_settings s
           on s.badge_id = b.id and s.family_id = p_family_id
   where b.id = p_badge_id
$$;

-- 家长调节：比率 / 勋章奖励
create or replace function app.set_family_settings(
  p_parent_token     text default null,
  p_cash_rate_points int  default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  f      app.families%rowtype;
begin
  parent := app._parent_guard(p_parent_token);

  if p_cash_rate_points is not null then
    if p_cash_rate_points <= 0 or p_cash_rate_points > 100000 then
      raise exception 'BAD_RATE: 兑换比率要在 1 ~ 100000 之间';
    end if;
    update app.families
       set cash_rate_points = p_cash_rate_points
     where id = parent.family_id;

    -- 比率是家庭级的，同步到本家庭所有现金商品，免得两处对不上
    update app.reward_items
       set rate_points = p_cash_rate_points
     where family_id = parent.family_id and item_kind = 'cash';
  end if;

  select * into f from app.families where id = parent.family_id;

  return jsonb_build_object(
    'family_id', f.id,
    'cash_rate_points', f.cash_rate_points);
end $$;


create or replace function app.set_badge_bonus(
  p_parent_token text default null,
  p_badge_id     uuid default null,
  p_points_bonus int  default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  b      app.badges%rowtype;
begin
  parent := app._parent_guard(p_parent_token);

  if p_badge_id is null then raise exception 'BAD_BADGE_ID: 缺少勋章'; end if;
  if p_points_bonus is null or p_points_bonus < 0 or p_points_bonus > 100000 then
    raise exception 'BAD_BONUS: 奖励积分要在 0 ~ 100000 之间';
  end if;

  select * into b from app.badges
   where id = p_badge_id and (family_id is null or family_id = parent.family_id);
  if not found then raise exception 'BADGE_NOT_FOUND'; end if;

  if b.family_id is null then
    -- 系统勋章共享，只能覆盖
    insert into app.badge_family_settings (family_id, badge_id, points_bonus)
    values (parent.family_id, p_badge_id, p_points_bonus)
    on conflict (family_id, badge_id) do update
       set points_bonus = excluded.points_bonus, updated_at = now();
  else
    update app.badges set points_bonus = p_points_bonus where id = p_badge_id;
  end if;

  return jsonb_build_object(
    'badge_id', p_badge_id,
    'points_bonus', p_points_bonus,
    'effective_bonus', app.badge_points_bonus(parent.family_id, p_badge_id));
end $$;


-- 评估 + 发奖励分
create or replace function app.evaluate_badges(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  m         app.members%rowtype;
  b         app.badges%rowtype;
  v_kind    text;
  v_dim     text;
  v_thr     int;
  v_prog    int;
  v_earned  boolean;
  v_at      timestamptz;
  v_mb_id   uuid;
  v_bonus   int;
  v_out     jsonb := '[]'::jsonb;
begin
  select * into m from app.members where id = p_member_id;
  if not found then return v_out; end if;

  for b in
    select * from app.badges
     where family_id = m.family_id or family_id is null
     order by (family_id is null), sort_order, name
  loop
    if not app.badge_rule_is_valid(b.rule) then continue; end if;

    v_kind := b.rule ->> 'kind';
    v_thr  := (b.rule ->> 'threshold')::int;
    v_prog := 0;
    v_dim  := null;
    v_mb_id := null;

    if v_kind = 'total_completions' then
      select count(*)::int into v_prog from app.task_occurrences o
       where o.assignee_id = m.id and o.status = 'completed';

    elsif v_kind = 'first_task' then
      -- 早起鸟：按家庭时区算，早上 8 点前完成的任务
      select count(*)::int into v_prog
        from app.task_occurrences o
        join app.families f on f.id = o.family_id
       where o.assignee_id = m.id and o.status = 'completed'
         and o.completed_at is not null
         and extract(hour from (o.completed_at at time zone f.timezone)) < 8;

    elsif v_kind = 'total_checkins' then
      select count(*)::int into v_prog from app.checkins c where c.member_id = m.id;

    elsif v_kind = 'total_points' then
      v_prog := m.points_balance;

    elsif v_kind = 'total_signin' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.signed;

    elsif v_kind = 'total_active' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.active;

    elsif v_kind = 'total_fullstar' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.fullstar;

    elsif v_kind = 'streak_days' then
      v_dim := coalesce(b.rule ->> 'dimension', 'active');
      v_prog := app.member_streak(m.id, v_dim);
    end if;

    v_earned := v_prog >= v_thr;

    if v_earned then
      -- returning id + on conflict do nothing：重复评估时拿不到行 → v_mb_id 为空。
      -- 奖励分因此天然只发一次，不用额外维护发放日志。
      insert into app.member_badges (member_id, badge_id, source_type, source_id)
      values (m.id, b.id, 'rule', b.id)
      on conflict (member_id, badge_id) do nothing
      returning id into v_mb_id;

      if v_mb_id is not null then
        v_bonus := app.badge_points_bonus(m.family_id, b.id);
        if v_bonus > 0 then
          perform app._post_ledger(m.id, v_bonus, 'badge', v_mb_id, 0,
                                   '勋章 · ' || b.name, null, m.id);
        end if;
      end if;
    end if;

    select mb.awarded_at into v_at from app.member_badges mb
     where mb.member_id = m.id and mb.badge_id = b.id;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id',          b.id,
      'badge_id',    b.id,
      'code',        b.code,
      'name',        b.name,
      'emoji',       b.emoji,
      'tier',        b.tier,
      'description', b.description,
      'rule',        b.rule,
      'kind',        v_kind,
      'dimension',   v_dim,
      'progress',    least(v_prog, v_thr),
      'raw_progress', v_prog,
      'threshold',   v_thr,
      'earned',      (v_at is not null),
      'earned_at',   v_at,
      'is_system',   (b.family_id is null),
      'points_bonus', app.badge_points_bonus(m.family_id, b.id)));
  end loop;

  return v_out;
end $$;


-- 家长勋章管理列表：带上奖励分（系统勋章显示的是覆盖后的有效值）
create or replace function app.list_family_badges(p_parent_token text default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  me := app.require_member();
  if p_parent_token is not null then
    perform app.require_parent(p_parent_token);
  elsif me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只有家长能管理勋章';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', b.id,
             'code', b.code,
             'name', b.name,
             'emoji', b.emoji,
             'tier', b.tier,
             'description', b.description,
             'rule', b.rule,
             'sort_order', b.sort_order,
             'is_system', (b.family_id is null),
             'base_bonus', coalesce(b.points_bonus, 0),
             'points_bonus', app.badge_points_bonus(me.family_id, b.id),
             'earned_count', (select count(*)::int from app.member_badges mb
                               join app.members m2 on m2.id = mb.member_id
                              where mb.badge_id = b.id and m2.family_id = me.family_id))
             order by (b.family_id is null), b.sort_order, b.name)
      from app.badges b
     where b.family_id = me.family_id or b.family_id is null), '[]'::jsonb);
end $$;


-- 新增了尾参 p_points_bonus，旧签名的默认参数会让调用产生歧义，先 drop。
drop function if exists app.upsert_badge(text, jsonb, text, uuid, text, text, text, text, int);

-- 家庭自定义勋章：家长可以直接设奖励分（系统勋章走 set_badge_bonus 覆盖）
create or replace function app.upsert_badge(
  p_name         text,
  p_rule         jsonb,
  p_parent_token text default null,
  p_id           uuid default null,
  p_emoji        text default '🏅',
  p_tier         text default 'bronze',
  p_description  text default null,
  p_code         text default null,
  p_sort_order   int  default 0,
  p_points_bonus int  default null
)
returns uuid
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  b      app.badges%rowtype;
  v_code text;
  v_id   uuid;
begin
  parent := app._parent_guard(p_parent_token);

  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'BAD_BADGE_NAME: 勋章要有名字';
  end if;
  if length(btrim(p_name)) > 20 then
    raise exception 'BAD_BADGE_NAME: 名字最多 20 个字';
  end if;
  if coalesce(p_tier, 'bronze') not in ('bronze', 'silver', 'gold', 'special') then
    raise exception 'BAD_BADGE_TIER: 等级只能是 bronze/silver/gold/special';
  end if;
  if not app.badge_rule_is_valid(p_rule) then
    raise exception 'BAD_BADGE_RULE: 解锁规则不合法';
  end if;
  if p_points_bonus is not null and (p_points_bonus < 0 or p_points_bonus > 100000) then
    raise exception 'BAD_BONUS: 奖励积分要在 0 ~ 100000 之间';
  end if;

  if p_id is not null then
    select * into b from app.badges where id = p_id;
    if not found then raise exception 'BADGE_NOT_FOUND'; end if;
    if b.family_id is distinct from parent.family_id then
      raise exception 'FORBIDDEN: 只能改自己家庭的勋章';
    end if;

    update app.badges
       set name         = btrim(p_name),
           emoji        = coalesce(nullif(btrim(p_emoji), ''), '🏅'),
           tier         = coalesce(p_tier, 'bronze'),
           description  = nullif(btrim(coalesce(p_description, '')), ''),
           rule         = p_rule,
           sort_order   = coalesce(p_sort_order, 0),
           points_bonus = coalesce(p_points_bonus, points_bonus)
     where id = b.id
     returning id into v_id;
    return v_id;
  end if;

  v_code := nullif(btrim(coalesce(p_code, '')), '');
  if v_code is null then
    v_code := 'custom_' || substr(md5(gen_random_uuid()::text), 1, 10);
  end if;

  insert into app.badges (family_id, code, name, description, emoji, tier, rule, sort_order,
                          points_bonus)
  values (parent.family_id, v_code, btrim(p_name),
          nullif(btrim(coalesce(p_description, '')), ''),
          coalesce(nullif(btrim(p_emoji), ''), '🏅'),
          coalesce(p_tier, 'bronze'), p_rule, coalesce(p_sort_order, 0),
          coalesce(p_points_bonus, 0))
  returning id into v_id;

  return v_id;
end $$;


-- ###########################################################################
-- 四、打卡（加一个"只记不发分"的开关）
-- ###########################################################################
-- 011 让"单次/到期任务完成即打卡"。013 改成单次完成按单次分发分之后，
-- 到期任务那一次自动打卡就不能再发一遍分了 —— p_award_points=false 只补痕迹。
-- once 任务例外：它的单次分走的是完成分，打卡分该给的还是要给（传 true）。
-- 同样因为新增了尾参，先 drop 掉 012 的三参版本，避免调用歧义。
drop function if exists app.record_checkin(uuid, date, text);

create or replace function app.record_checkin(
  p_task_id      uuid,
  p_date         date,
  p_note         text    default null,
  p_award_points boolean default true
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  ck app.checkins%rowtype;
  e  app.point_ledger%rowtype;
  v_seq int;
  v_awarded int := 0;
  v_capped int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能给自己的任务打卡';
  end if;

  o := app.materialize(p_task_id, p_date);

  select coalesce(max(seq), 0) + 1 into v_seq from app.checkins where occurrence_id = o.id;
  if v_seq > t.checkin_daily_limit then
    raise exception 'CHECKIN_LIMIT_REACHED: 今天这个任务最多打卡 % 次', t.checkin_daily_limit;
  end if;

  insert into app.checkins (occurrence_id, member_id, seq, points_awarded, note)
  values (o.id, t.assignee_id, v_seq, 0, p_note)
  returning * into ck;

  if p_award_points and o.snap_checkin_points > 0 and t.checkin_auto_approve then
    e := app._post_ledger(t.assignee_id, o.snap_checkin_points, 'checkin', ck.id, 0,
                          '打卡 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
    update app.checkins set points_awarded = v_awarded where id = ck.id;
  end if;

  perform app.evaluate_milestones(p_task_id);
  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'checkin_id', ck.id,
    'seq', v_seq,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- ###########################################################################
-- 五、完成当日 = 单次分
-- ###########################################################################
create or replace function app.complete_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  e  app.point_ledger%rowtype;
  v_awarded int := 0;
  v_capped int;
  v_seq int;
  v_points int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能完成自己的任务';
  end if;

  o := app.materialize(p_task_id, p_date);

  if o.status = 'completed' then
    return jsonb_build_object(
      'occurrence_id', o.id, 'already', true, 'points_awarded', 0,
      'balance', (select points_balance from app.members where id = t.assignee_id));
  end if;

  update app.task_occurrences
     set status = 'completed', completed_at = now(), completed_by = me.id,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id
   returning * into o;

  -- 013：单次完成发「单次分」。整任务的完成分留给「完成全部」那一笔结清奖励。
  v_points := app.task_single_points(t.schedule_kind, o.snap_checkin_points,
                                     o.snap_completion_points);

  if v_points > 0 and not t.requires_approval then
    select coalesce(max(l.source_seq), -1) + 1 into v_seq
      from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id;

    e := app._post_ledger(t.assignee_id, v_points, 'completion', o.id, v_seq,
                          '完成 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
  elsif v_points > 0 then
    insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
    values (t.family_id, t.assignee_id, 'completion', o.id, v_points,
            '完成 · ' || o.snap_title)
    on conflict (source_type, source_id, source_seq) do nothing;
  end if;

  -- 单次 / 到期任务完成即打卡（011）。单次分已经发过了，
  -- 到期任务这次打卡只补痕迹；once 任务的单次分走的是完成分，打卡分照发。
  if (t.schedule_kind = 'once' or t.is_deadline_style)
     and o.snap_checkin_points > 0 and t.checkin_auto_approve
     and not exists (select 1 from app.checkins c where c.occurrence_id = o.id) then
    perform app.record_checkin(p_task_id, p_date, null, t.schedule_kind = 'once');
  end if;

  perform app.evaluate_milestones(p_task_id);
  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'already', false,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- ###########################################################################
-- 六、完成全部 = 各日单次分之和 + 一笔完成分
-- ###########################################################################
create or replace function app.complete_all_occurrences(
  p_task_id   uuid,
  p_upto_date date default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  t       app.tasks%rowtype;
  o       app.task_occurrences%rowtype;
  e       app.point_ledger%rowtype;
  v_today date;
  v_upto  date;
  v_from  date;
  v_occ   date;
  v_count int := 0;
  v_awarded int := 0;
  v_capped  int;
  v_seq   int;
  v_single int;
  v_extra boolean;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能完成自己的任务';
  end if;

  v_today := app.family_today(t.family_id);
  -- 收尾日：默认 ends_on，但 UI 建任务时通常不传 ends_on，
  -- 此时一次性任务只有 starts_on（就是它唯一那天的日期），
  -- 若仍按 v_today 收尾会漏掉"未来那一次"，补上 greatest 兜底。
  v_upto := least(
    coalesce(p_upto_date, greatest(coalesce(t.ends_on, v_today), coalesce(t.starts_on, v_today))),
    v_today + 730
  );
  -- 起始日：循环任务只做今天及以后（历史天数不倒补）；
  -- 一次性任务唯一那次可能已过期，允许往前扫到任务当天。
  v_from := case
    when t.schedule_kind = 'once' then least(v_today, coalesce(t.starts_on, v_today))
    else v_today
  end;

  v_single := app.task_single_points(t.schedule_kind, t.checkin_points, t.completion_points);
  -- 结清奖励只在"完成分还没被单次分用掉"时发：
  --   once              → 单次分就等于完成分，不重复发
  --   没开打卡的循环任务 → 单次分也是完成分，同样不重复发（沿用旧口径）
  v_extra  := (t.schedule_kind <> 'once'
               and coalesce(t.completion_points, 0) > 0
               and v_single <> t.completion_points);

  for v_occ in
    select x.d from app.expand_task(p_task_id, v_from, v_upto) as x(d)
     where x.d >= v_from
     order by x.d
  loop
    -- 已经完成的这一天跳过，避免重复置完成 / 重复发分
    if exists (
      select 1 from app.task_occurrences o2
       where o2.task_id = p_task_id and o2.occurrence_date = v_occ and o2.status = 'completed'
    ) then
      continue;
    end if;

    o := app.materialize(p_task_id, v_occ);
    update app.task_occurrences
       set status = 'completed', completed_at = now(), completed_by = me.id, updated_at = now()
     where id = o.id
    returning * into o;
    v_count := v_count + 1;

    -- 每一天的单次分（补齐：已完成的天在前面 continue 掉了）
    if v_single > 0 then
      if not t.requires_approval then
        select coalesce(max(l.source_seq), -1) + 1 into v_seq
          from app.point_ledger l
         where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id;

        e := app._post_ledger(t.assignee_id, v_single, 'completion', o.id, v_seq,
                              '完成 · ' || o.snap_title, v_occ, me.id);
        v_awarded := v_awarded + coalesce(e.delta, 0);
        v_capped := coalesce(e.capped_from, v_capped);
      else
        insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
        values (t.family_id, t.assignee_id, 'completion', o.id, v_single,
                '完成 · ' || o.snap_title)
        on conflict (source_type, source_id, source_seq) do nothing;
      end if;
    end if;

    -- 单次 / 到期：补一次打卡痕迹，不重复发分（once 任务的打卡分照发）
    if (t.schedule_kind = 'once' or t.is_deadline_style)
       and t.checkin_points > 0 and t.checkin_auto_approve
       and not exists (
         select 1 from app.checkins c
         join app.task_occurrences o3 on o3.id = c.occurrence_id
        where o3.task_id = p_task_id and o3.occurrence_date = v_occ)
    then
      perform app.record_checkin(p_task_id, v_occ, null, t.schedule_kind = 'once');
    end if;
  end loop;

  if v_count > 0 then
    perform app.evaluate_milestones(p_task_id);
  end if;

  -- 结清奖励：完成分一笔（按任务计，幂等）
  if v_count > 0 and v_extra then
    if not t.requires_approval then
      select coalesce(max(l.source_seq), -1) + 1 into v_seq
        from app.point_ledger l
       where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = p_task_id;

      e := app._post_ledger(t.assignee_id, t.completion_points, 'completion', p_task_id, v_seq,
                            '完成全部 · ' || t.title, v_today, me.id);
      v_awarded := v_awarded + coalesce(e.delta, 0);
      v_capped := coalesce(e.capped_from, v_capped);
    else
      insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
      values (t.family_id, t.assignee_id, 'completion', p_task_id, t.completion_points,
              '完成全部 · ' || t.title)
      on conflict (source_type, source_id, source_seq) do nothing;
    end if;
  end if;

  perform app.refresh_day_status(t.assignee_id, v_today);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'task_id', p_task_id,
    'completed_occurrences', v_count,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- ###########################################################################
-- 七、兑换：card 商品发卡
-- ###########################################################################
create or replace function app.redeem(
  p_item_id  uuid,
  p_quantity numeric default 1,
  p_note     text   default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me     app.members%rowtype;
  item   app.reward_items%rowtype;
  v_cost int;
  v_id   uuid;
  v_bal  int;
  v_qty  int;
begin
  me := app.require_member();
  if p_quantity is null or p_quantity <= 0 then raise exception 'BAD_QTY'; end if;

  select * into item from app.reward_items where id = p_item_id;
  if not found or item.family_id <> me.family_id then raise exception 'ITEM_NOT_FOUND'; end if;
  if not item.active then raise exception 'ITEM_INACTIVE: 这个商品已下架'; end if;

  if p_quantity < item.min_quantity then
    raise exception 'BELOW_MIN_QTY: 至少要兑 % %', item.min_quantity, coalesce(item.unit_label, '个');
  end if;
  if mod((p_quantity - item.min_quantity)::numeric, item.step_quantity) <> 0 then
    raise exception 'BAD_STEP_QTY: 数量必须按 % 递增', item.step_quantity;
  end if;

  if item.stock is not null and item.stock < p_quantity then
    raise exception 'OUT_OF_STOCK: 库存不足';
  end if;

  v_cost := ceil(
    case when item.pricing_mode = 'fixed' then item.price_points * p_quantity
         else item.rate_points * p_quantity end
  )::int;

  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < v_cost then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', v_cost - v_bal;
  end if;

  insert into app.redemptions (family_id, member_id, item_id, quantity, points_cost,
                               snap_name, snap_emoji, note)
  values (me.family_id, me.id, item.id, p_quantity, v_cost,
          item.name, item.emoji, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform app._post_ledger(me.id, -v_cost, 'redemption', v_id, 0,
                           '兑换 ' || item.name, null, me.id);

  if item.stock is not null then
    update app.reward_items set stock = stock - p_quantity where id = item.id;
  end if;

  -- 补卡：直接进库存。分数已经扣了，卡先给；家长驳回时 decide_redemption 再收回。
  if item.item_kind = 'card' and item.card_kind is not null then
    v_qty := ceil(p_quantity)::int;
    insert into app.member_cards (member_id, kind, qty)
    values (me.id, item.card_kind, v_qty)
    on conflict (member_id, kind) do update
       set qty = member_cards.qty + excluded.qty, updated_at = now();
  end if;

  return jsonb_build_object(
    'redemption_id', v_id,
    'points_spent', v_cost,
    'balance', (select points_balance from app.members where id = me.id),
    'pending', item.requires_approval,
    'granted_card', item.card_kind,
    'granted_qty', case when item.item_kind = 'card' then ceil(p_quantity)::int else 0 end,
    'message', case when item.requires_approval then '已提交，等家长确认' else '兑换成功' end);
end $$;


create or replace function app.decide_redemption(
  p_redemption_id uuid, p_decision text, p_parent_token text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  r      app.redemptions%rowtype;
  item   app.reward_items%rowtype;
  src    app.point_ledger%rowtype;
begin
  parent := app.require_parent(p_parent_token);
  if p_decision not in ('approved', 'rejected', 'delivered', 'cancelled') then
    raise exception 'BAD_DECISION';
  end if;

  select * into r from app.redemptions where id = p_redemption_id;
  if not found or r.family_id <> parent.family_id then raise exception 'REDEMPTION_NOT_FOUND'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED: 这笔已经处理过了'; end if;

  update app.redemptions
     set status = p_decision, decided_at = now(), decided_by = parent.id
   where id = r.id;

  if p_decision in ('rejected', 'cancelled') then
    select * into src from app.point_ledger
     where entry_kind = 'primary' and source_type = 'redemption'
       and source_id = r.id and source_seq = 0;
    if found then
      perform app._reverse_ledger(src.id, '兑换未通过，积分退回', parent.id);
    end if;

    -- 补卡跟着退：分都退回去了，卡不能留在手里
    select * into item from app.reward_items where id = r.item_id;
    if item.item_kind = 'card' and item.card_kind is not null then
      update app.member_cards
         set qty = greatest(0, qty - ceil(r.quantity)::int), updated_at = now()
       where member_id = r.member_id and kind = item.card_kind;
    end if;
  end if;

  return jsonb_build_object(
    'redemption_id', r.id, 'status', p_decision,
    'balance', (select points_balance from app.members where id = r.member_id));
end $$;


-- ###########################################################################
-- 八、商城播种（建家庭 / 存量回填共用）
-- ###########################################################################
-- 参考价按"这一天的达成难度"排：签到最易得、满星最难。
-- 连续档位奖励 signin 3→10/7→30/30→100，fullstar 3→20/7→60/30→200，
-- 所以补满星卡定价最高。家长可在商城里改。
create or replace function app.seed_reward_items(p_family_id uuid)
returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and item_kind = 'cash') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  rate_points, unit_label, min_quantity, step_quantity,
                                  requires_approval, item_kind, sort_order)
    values (p_family_id, '现金', '💰', '攒够了换零花钱', 'rate', 10, '元', 1, 1,
            true, 'cash', 0);
  end if;

  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and card_kind = 'retro_signin') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  price_points, min_quantity, step_quantity,
                                  requires_approval, item_kind, card_kind, sort_order)
    values (p_family_id, '补签卡', '🎫', '补一天忘记签到的日子', 'fixed', 30, 1, 1,
            false, 'card', 'retro_signin', 1);
  end if;

  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and card_kind = 'retro_active') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  price_points, min_quantity, step_quantity,
                                  requires_approval, item_kind, card_kind, sort_order)
    values (p_family_id, '补活跃卡', '⚡', '补一天没完成任务的日子', 'fixed', 60, 1, 1,
            false, 'card', 'retro_active', 2);
  end if;

  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and card_kind = 'retro_fullstar') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  price_points, min_quantity, step_quantity,
                                  requires_approval, item_kind, card_kind, sort_order)
    values (p_family_id, '补满星卡', '🌟', '补一天没全部完成的日子', 'fixed', 120, 1, 1,
            false, 'card', 'retro_fullstar', 3);
  end if;
end $$;


create or replace function app.create_family(
  p_family_name text,
  p_nickname    text,
  p_username    text,
  p_pin         text,
  p_avatar      text default '🙂',
  p_timezone    text default 'Asia/Shanghai'
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_uid uuid;
  f app.families%rowtype;
  m app.members%rowtype;
  v_child_code text;
  v_parent_code text;
  v_salt text;
  v_uname text;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'NO_AUTH: 缺少身份'; end if;
  if exists (select 1 from app.members where user_id = v_uid) then
    raise exception 'ALREADY_IN_FAMILY: 这个身份已经属于某个家庭了';
  end if;

  v_uname := lower(btrim(p_username));
  if v_uname = '' then raise exception 'USERNAME_REQUIRED: 请填写用户名'; end if;
  if exists (select 1 from app.members where username = v_uname) then
    raise exception 'USERNAME_TAKEN: 用户名已被占用';
  end if;
  if p_pin is null or p_pin !~ '^\d{4}$' then
    raise exception 'BAD_PIN: PIN 必须是 4 位数字';
  end if;

  insert into app.families (name, timezone) values (btrim(p_family_name), p_timezone)
  returning * into f;

  v_salt := app.gen_salt_text();
  insert into app.members (family_id, user_id, nickname, role, avatar_emoji, username, pin_hash, pin_salt)
  values (f.id, v_uid, btrim(p_nickname), 'parent', coalesce(p_avatar, '🙂'), v_uname,
          app.hash_pin(p_pin, v_salt), v_salt)
  returning * into m;

  v_child_code  := app._new_invite_code();
  v_parent_code := app._new_invite_code();
  insert into app.invites (family_id, code, role, created_by) values
    (f.id, v_child_code,  'child',  m.id),
    (f.id, v_parent_code, 'parent', m.id);

  -- 013：现金按 families.cash_rate_points（默认 10 分 = 1 元）+ 三张补卡
  perform app.seed_reward_items(f.id);

  return jsonb_build_object(
    'family_id', f.id, 'member_id', m.id, 'user_id', v_uid,
    'child_invite_code', v_child_code, 'parent_invite_code', v_parent_code);
end $$;


-- ###########################################################################
-- 九、存量数据回填
-- ###########################################################################

-- 老家庭那条 100 分/元的现金商品：改标 cash、按新比率重算。
-- item_kind 列是 013 新增、not null default 'goods'，所以存量现金商品 item_kind='goods'，
-- 这里按 pricing_mode 认不会误伤。播种脚本只造过现金这一种 rate 商品。
update app.reward_items r
   set item_kind   = 'cash',
       rate_points = coalesce(f.cash_rate_points, 10)
  from app.families f
 where f.id = r.family_id
   and r.item_kind = 'goods'
   and r.pricing_mode = 'rate';

-- 存量家庭补上三张补卡
do $$
declare fid uuid;
begin
  for fid in select id from app.families loop
    perform app.seed_reward_items(fid);
  end loop;
end $$;

-- 系统勋章的积分奖励参考值（按获取难度）。
-- 带 points_bonus = 0 的条件，家长手动调过的不覆盖。
update app.badges b
   set points_bonus = v.bonus
  from (values
    ('first_step',   5),   -- 完成第一个任务：入门，意思一下
    ('streak_3',    15),   -- 连续 3 天
    ('streak_7',    40),   -- 连续 7 天
    ('streak_30',  150),   -- 连续 30 天
    ('complete_10', 20),   -- 累计完成 10 个
    ('complete_50', 60),   -- 累计完成 50 个
    ('complete_200',150),  -- 累计完成 200 个
    ('points_500',  30),   -- 余额 500
    ('points_2000', 100),  -- 余额 2000
    ('early_bird',  20)    -- 8 点前完成
  ) as v(code, bonus)
 where b.code = v.code and b.family_id is null and b.points_bonus = 0;


-- ###########################################################################
-- 十、权限
-- ###########################################################################
grant select on app.badge_family_settings to authenticated;
grant all    on app.badge_family_settings to service_role;

grant execute on function app.task_single_points(text, int, int) to authenticated, service_role;
grant execute on function app.badge_points_bonus(uuid, uuid)     to authenticated, service_role;
grant execute on function app.set_family_settings(text, int)      to authenticated, service_role;
grant execute on function app.set_badge_bonus(text, uuid, int)    to authenticated, service_role;
grant execute on function app.seed_reward_items(uuid)             to authenticated, service_role;

grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
