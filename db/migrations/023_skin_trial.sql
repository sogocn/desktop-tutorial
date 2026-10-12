-- =============================================================================
-- 023：皮肤试用 1 天
--
-- 规则：
--   1) 只有「付费 + 未拥有」的皮肤能试用；默认皮肤本来就免费，直接「使用」即可
--   2) 同一成员对同一皮肤只能试用一次（记在 skin_trials），到期想再用就得兑换
--   3) 试用时长 = 24 小时（用 timestamptz，按点开始计，不依赖家庭日切，
--      避免"晚上试用只剩两小时"的问题）
--   4) 到期自动回退：不需要定时任务，判断只看 trial_until > now()，
--      过期后 effective_skin_id() 自然回落到原来选中的皮肤
--   5) 手动切换到某个已拥有的皮肤 = 主动结束试用
--
-- 生效皮肤统一由 app.effective_skin_id() 决定，list_skins 的 current 也改成按它算，
-- 所以前端 ThemeApplier 不用改就能正确套用试用中的皮肤。
-- =============================================================================

-- ###########################################################################
-- 一、表与列
-- ###########################################################################
create table if not exists app.skin_trials (
  member_id  uuid not null references app.members(id) on delete cascade,
  skin_id    uuid not null references app.skins(id)   on delete cascade,
  started_at timestamptz not null default now(),
  until_at   timestamptz not null,
  primary key (member_id, skin_id)
);
create index if not exists skin_trials_member_idx on app.skin_trials (member_id);

alter table app.members add column if not exists trial_skin_id uuid
  references app.skins(id) on delete set null;
alter table app.members add column if not exists trial_until    timestamptz;

-- ###########################################################################
-- 二、当前"生效"皮肤：试用中 > 已拥有的选择 > 默认皮肤
-- ###########################################################################
create or replace function app.effective_skin_id(p_member_id uuid)
returns uuid
language sql stable security definer set search_path = app, public as $$
  select case
           when m.trial_skin_id is not null and m.trial_until > now()
             then m.trial_skin_id
           else coalesce(
             m.selected_skin_id,
             (select s.id from app.skins s where s.is_default limit 1))
         end
    from app.members m
   where m.id = p_member_id
$$;

-- ###########################################################################
-- 三、开始试用 / 提前结束试用
-- ###########################################################################
create or replace function app.start_skin_trial(p_skin_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype;
        sk app.skins%rowtype;
        v_until timestamptz;
begin
  me := app.require_member();

  select * into sk from app.skins where id = p_skin_id and active;
  if not found then raise exception 'SKIN_NOT_FOUND'; end if;

  if sk.is_default then
    raise exception 'SKIN_DEFAULT_FREE: 默认皮肤免费，直接点「使用」就行'; end if;

  if exists (select 1 from app.member_skins where member_id = me.id and skin_id = sk.id) then
    raise exception 'SKIN_OWNED: 已经拥有这个皮肤，点「使用」即可'; end if;

  if exists (select 1 from app.skin_trials where member_id = me.id and skin_id = sk.id) then
    raise exception 'SKIN_TRIAL_USED: 这个皮肤你已经试用过了，喜欢就兑换吧'; end if;

  -- 一次只能试一张。没有这层保护的话，开第二张会直接覆盖 trial_skin_id，
  -- 而第一张已经写进 skin_trials 不能再试 —— 等于白白浪费一次试用机会。
  -- 想要换一张，先点「结束试用」再开。
  if me.trial_skin_id is not null and me.trial_until > now() and me.trial_skin_id <> sk.id then
    raise exception 'SKIN_TRIAL_ACTIVE: 一次只能试用一张，先结束现在的试用'; end if;

  v_until := now() + interval '1 day';

  update app.members
     set trial_skin_id = sk.id, trial_until = v_until
   where id = me.id;

  insert into app.skin_trials (member_id, skin_id, until_at)
  values (me.id, sk.id, v_until)
  on conflict (member_id, skin_id) do nothing;

  return jsonb_build_object(
    'skin_id', sk.id,
    'ends_at', v_until,
    'hours_left', 24,
    'price', app.skin_price(me.family_id, sk.id),
    'message', format('已开始试用「%s」，24 小时后自动回到原来的皮肤', sk.name));
end $$;

/** 提前结束试用（回到原来选中的皮肤）。到期了调它也只是把残留字段清掉，无害。 */
create or replace function app.end_skin_trial()
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  me := app.require_member();
  update app.members set trial_skin_id = null, trial_until = null where id = me.id;
  return jsonb_build_object('trial_end', true);
end $$;

-- ###########################################################################
-- 四、切换皮肤：改用生效皮肤口径，并顺手结束试用
-- ###########################################################################
create or replace function app.set_member_skin(p_skin_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype;
        sk app.skins%rowtype;
begin
  me := app.require_member();
  select * into sk from app.skins where id = p_skin_id and active;
  if not found then raise exception 'SKIN_NOT_FOUND'; end if;

  -- 允许切换到「已拥有」「默认」，以及「正在试用的那张」（试用中点使用 = 转正意图，
  -- 但没拥有还是会拒绝，不会因此白嫖）
  if not (sk.is_default
          or exists (select 1 from app.member_skins where member_id = me.id and skin_id = sk.id)) then
    raise exception 'SKIN_NOT_OWNED: 先兑换这个皮肤才能使用'; end if;

  -- 主动选择已拥有的皮肤 = 结束试用
  update app.members
     set selected_skin_id = sk.id, trial_skin_id = null, trial_until = null
   where id = me.id;

  return jsonb_build_object('skin_id', sk.id, 'current', true);
end $$;

-- ###########################################################################
-- 五、列表：current 按"生效皮肤"算，并带上试用状态
-- ###########################################################################
create or replace function app.list_skins(p_member_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare me  app.members%rowtype;
        tm  app.members%rowtype;
        fid uuid; v_mid uuid; v_eff uuid;
        v_trialing boolean; v_hours int;
begin
  me := app.require_member();
  fid := me.family_id;
  v_mid := coalesce(p_member_id, me.id);
  -- 越权保护：只能看同家庭的成员
  if not exists (select 1 from app.members where id = v_mid and family_id = fid) then
    v_mid := me.id;
  end if;

  select * into tm from app.members where id = v_mid;
  v_eff := app.effective_skin_id(v_mid);
  v_trialing := (tm.trial_skin_id is not null and tm.trial_until > now());
  if v_trialing then
    v_hours := greatest(round(extract(epoch from (tm.trial_until - now())) / 3600)::int, 0);
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'key', s.key, 'name', s.name, 'emoji', s.emoji,
      'description', s.description, 'is_default', s.is_default, 'theme', s.theme,
      'price', app.skin_price(fid, s.id),
      'owned', (s.is_default or exists (
        select 1 from app.member_skins ms where ms.member_id = v_mid and ms.skin_id = s.id)),
      -- 关键改动：current 看"生效皮肤"，试用中的那张才是 current
      'current', (s.id = v_eff),
      'can_trial', (not s.is_default
                    and not exists (
                      select 1 from app.member_skins ms
                       where ms.member_id = v_mid and ms.skin_id = s.id)
                    and not exists (
                      select 1 from app.skin_trials st
                       where st.member_id = v_mid and st.skin_id = s.id)),
      'trial_active', (v_trialing and tm.trial_skin_id = s.id),
      'trial_ends_at', case when v_trialing and tm.trial_skin_id = s.id
                            then tm.trial_until else null end,
      'trial_hours_left', case when v_trialing and tm.trial_skin_id = s.id
                               then v_hours else null end
    ) order by s.sort_order, s.name)
      from app.skins s where s.active), '[]'::jsonb);
end $$;

-- ###########################################################################
-- 六、bootstrap：成员带上试用字段（最终生效即此版）
-- ###########################################################################
create or replace function app.bootstrap_state()
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare v_fid uuid; v_mid uuid; v_today date;
begin
  v_fid := app.current_family_id();
  if v_fid is null then return jsonb_build_object('in_family', false); end if;
  v_mid := app.current_member_id();
  v_today := app.family_today(v_fid);

  return jsonb_build_object(
    'in_family', true,
    'today', v_today,
    'me_id', v_mid,
    'family', (select to_jsonb(f) from app.families f where f.id = v_fid),
    'members', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.role, x.created_at)
        from (select m.id, m.family_id, m.user_id, m.nickname, m.role, m.avatar_emoji,
                     m.points_balance, (m.pin_hash is not null) as has_pin, m.created_at,
                     m.selected_skin_id, m.trial_skin_id, m.trial_until,
                     coalesce(md.signed, false)   as signed_today,
                     coalesce(md.active, false)   as active_today,
                     coalesce(md.fullstar, false) as fullstar_today
                from app.members m
                left join app.member_day md
                       on md.member_id = m.id and md.day = v_today
               where m.family_id = v_fid and m.archived_at is null) x
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from app.invites i where i.family_id = v_fid and i.revoked_at is null
    ), '[]'::jsonb)
  );
end $$;

-- ###########################################################################
-- 七、权限
-- ###########################################################################
alter table app.skin_trials enable row level security;

drop policy if exists skin_trials_select on app.skin_trials;
create policy skin_trials_select on app.skin_trials
  for select to authenticated
  using (member_id in (
    select m.id from app.members m
     where m.family_id = app.current_family_id()));

grant select on app.skin_trials to authenticated;
grant all    on app.skin_trials to service_role;

grant execute on function app.start_skin_trial(uuid)  to authenticated, service_role;
grant execute on function app.end_skin_trial()        to authenticated, service_role;
grant execute on function app.effective_skin_id(uuid) to authenticated, service_role;
