-- =============================================================================
-- 011_badges.sql —— 勋章：家长自定义 + 自动评估 + 进度
-- =============================================================================
-- 005 只建了表，规则一直没人算。这里把规则跑起来：
--
--   rule = {"kind":"...", "threshold":N, "dimension":"..."}
--     total_completions  累计完成任务数
--     total_checkins     累计打卡次数
--     total_points       当前积分余额
--     total_signin       累计签到天数
--     total_active       累计活跃天数
--     total_fullstar     累计满星天数
--     streak_days        连续天数，dimension ∈ signin|active|fullstar（默认 active）
--     first_task         完成第一个任务（等价 total_completions threshold=1）
--
-- 评估是事件驱动的：完成任务 / 签到 / 补卡都会调 evaluate_badges，
-- 没有定时任务。达标即写 member_badges（唯一约束兜幂等），不倒扣、不撤回。
-- =============================================================================


-- ###########################################################################
-- 一、规则校验
-- ###########################################################################
create or replace function app.badge_rule_is_valid(r jsonb)
returns boolean
language sql immutable set search_path = app, public as $$
  select coalesce(case
    when r is null or jsonb_typeof(r) <> 'object' then false
    when (r ->> 'kind') is null then false
    when (r ->> 'kind') not in ('total_completions', 'total_checkins', 'total_points',
                                'total_signin', 'total_active', 'total_fullstar',
                                'streak_days', 'first_task') then false
    when (r ->> 'threshold') is null then false
    when (r ->> 'threshold') !~ '^\d+$' then false
    when (r ->> 'threshold')::int <= 0 then false
    when (r ->> 'kind') = 'streak_days'
         and coalesce(r ->> 'dimension', 'active') not in ('signin', 'active', 'fullstar')
      then false
    else true
  end, false)
$$;


-- ###########################################################################
-- 二、家长维护家庭勋章
-- ###########################################################################
create or replace function app.upsert_badge(
  p_name         text,
  p_rule         jsonb,
  p_parent_token text default null,
  p_id           uuid default null,
  p_emoji        text default '🏅',
  p_tier         text default 'bronze',
  p_description  text default null,
  p_code         text default null,
  p_sort_order   int  default 0
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

  if p_id is not null then
    select * into b from app.badges where id = p_id;
    if not found then raise exception 'BADGE_NOT_FOUND'; end if;
    -- 系统内置勋章（family_id is null）所有家庭共享，谁都不能改
    if b.family_id is distinct from parent.family_id then
      raise exception 'FORBIDDEN: 只能改自己家庭的勋章';
    end if;

    update app.badges
       set name        = btrim(p_name),
           emoji       = coalesce(nullif(btrim(p_emoji), ''), '🏅'),
           tier        = coalesce(p_tier, 'bronze'),
           description = nullif(btrim(coalesce(p_description, '')), ''),
           rule        = p_rule,
           sort_order  = coalesce(p_sort_order, 0)
     where id = b.id
     returning id into v_id;
    return v_id;
  end if;

  -- code 只是唯一键，家长不需要关心。给一个稳定可读的默认值。
  v_code := nullif(btrim(coalesce(p_code, '')), '');
  if v_code is null then
    v_code := 'custom_' || substr(md5(gen_random_uuid()::text), 1, 10);
  end if;

  insert into app.badges (family_id, code, name, description, emoji, tier, rule, sort_order)
  values (parent.family_id, v_code, btrim(p_name),
          nullif(btrim(coalesce(p_description, '')), ''),
          coalesce(nullif(btrim(p_emoji), ''), '🏅'),
          coalesce(p_tier, 'bronze'), p_rule, coalesce(p_sort_order, 0))
  returning id into v_id;

  return v_id;
end $$;


create or replace function app.delete_badge(p_id uuid, p_parent_token text default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; n int;
begin
  parent := app._parent_guard(p_parent_token);

  -- family_id is null 的系统勋章匹配不到，自然删不掉
  delete from app.badges where id = p_id and family_id = parent.family_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'BADGE_NOT_FOUND: 没有这个家庭勋章'; end if;

  return jsonb_build_object('deleted', n);
end $$;


-- ###########################################################################
-- 三、评估
-- ###########################################################################
-- 返回 jsonb 数组：每个勋章的进度 + 是否已获得，前端直接渲染进度条。
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
      insert into app.member_badges (member_id, badge_id, source_type, source_id)
      values (m.id, b.id, 'rule', b.id)
      on conflict (member_id, badge_id) do nothing;
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
      'is_system',   (b.family_id is null)));
  end loop;

  return v_out;
end $$;


-- 前端勋章页调这个：先评估再返回，保证进度和刚做完的动作对得上。
create or replace function app.list_badges_with_progress(p_member_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype; target app.members%rowtype;
begin
  me := app.require_member();

  if p_member_id is null or p_member_id = me.id then
    target := me;
  else
    select * into target from app.members
     where id = p_member_id and family_id = me.family_id;
    if not found then raise exception 'FORBIDDEN: 只能看本家庭成员'; end if;
  end if;

  return app.evaluate_badges(target.id);
end $$;


-- 家长的勋章管理页：本家庭自定义 + 系统内置（系统的只读，is_system=true）
create or replace function app.list_family_badges(p_parent_token text default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  me := app.require_member();
  -- 只读列表不值得再要一次 PIN：是家长就能看。给了 token 就顺手验一下。
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
             'earned_count', (select count(*)::int from app.member_badges mb
                               join app.members m2 on m2.id = mb.member_id
                              where mb.badge_id = b.id and m2.family_id = me.family_id))
             order by (b.family_id is null), b.sort_order, b.name)
      from app.badges b
     where b.family_id = me.family_id or b.family_id is null), '[]'::jsonb);
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
