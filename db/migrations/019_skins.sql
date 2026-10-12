-- =============================================================================
-- 019_skins.sql —— 皮肤（主题）系统
-- =============================================================================
-- 四块需求：
--   1) 新增皮肤：背景 / 配色 / 按钮随皮肤同步切换（前端读 theme 里的 CSS 变量）。
--   2) 孩子兑换 + 切换：app.member_skins 记录拥有，members.selected_skin_id 记录当前。
--   3) 家长定价：app.skin_family_settings 覆盖每个家庭的价格（仿 badge_family_settings）。
--   4) 预置 5 个皮肤：默认 / 护眼 / 宝可梦 / 线条小狗 / 哈利波特（赫敏）。
--      素材走"配色 + 图案 key"，图案 SVG 在前端 assets 注册，方便日后替换正版素材。
--
-- 设计要点：
--   * skins 是全局目录（family_id 为 null，仿系统勋章），由 seed_skins() 预置一次。
--   * 默认皮肤 is_default=true、price_points=0，无需兑换、人人"拥有"。
--   * 兑换复用 point_ledger 的 'redemption' 来源（不改既有的 source_type 枚举约束）。
--   * 价格：基础价在 skins.price_points；家庭覆盖在 skin_family_settings；skin_price() 取覆盖值。
-- =============================================================================

-- ###########################################################################
-- 一、表
-- ###########################################################################
create table if not exists app.skins (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique,
  name         text not null check (length(btrim(name)) between 1 and 40),
  emoji        text not null default '🎨',
  description  text,
  price_points int  not null default 0 check (price_points >= 0),
  is_default   boolean not null default false,
  active       boolean not null default true,
  sort_order   int  not null default 0,
  theme        jsonb not null,
  created_at   timestamptz not null default now()
);
create index if not exists skins_active_idx on app.skins (active, sort_order) where active;

create table if not exists app.member_skins (
  member_id   uuid not null references app.members(id) on delete cascade,
  skin_id     uuid not null references app.skins(id) on delete cascade,
  acquired_at timestamptz not null default now(),
  primary key (member_id, skin_id)
);
create index if not exists member_skins_member_idx on app.member_skins (member_id);

create table if not exists app.skin_family_settings (
  family_id    uuid not null references app.families(id) on delete cascade,
  skin_id      uuid not null references app.skins(id) on delete cascade,
  price_points int  not null check (price_points >= 0),
  updated_at   timestamptz not null default now(),
  primary key (family_id, skin_id)
);

alter table app.members add column if not exists selected_skin_id uuid references app.skins(id);

-- ###########################################################################
-- 二、价格解析（基础价 < 家庭覆盖价）
-- ###########################################################################
create or replace function app.skin_price(p_family_id uuid, p_skin_id uuid)
returns int
language sql stable security definer set search_path = app, public as $$
  select coalesce(s.price_points, sk.price_points, 0)
    from app.skins sk
    left join app.skin_family_settings s
           on s.skin_id = sk.id and s.family_id = p_family_id
   where sk.id = p_skin_id
$$;

-- ###########################################################################
-- 三、皮肤目录预置（全局，family_id 为 null；按 key 幂等）
-- ###########################################################################
create or replace function app.seed_skins()
returns void
language plpgsql security definer set search_path = app, public as $$
begin
  insert into app.skins (key, name, emoji, description, price_points, is_default, sort_order, theme)
  values
    ('default', '默认', '🎨', '经典浅灰，清爽不刺眼', 0, true, 0,
     '{"bg":"#f8fafc","surface":"#ffffff","surface2":"#f1f5f9","primary":"#0f172a","primaryHover":"#1e293b","onPrimary":"#ffffff","onPrimaryMuted":"rgba(255,255,255,0.7)","text":"#0f172a","muted":"#64748b","border":"rgba(226,232,240,0.7)","navBg":"rgba(255,255,255,0.9)","accent":"#0ea5e9","pattern":null}'::jsonb),
    ('eye_care', '护眼', '🌿', '柔和草绿，长时间看更舒服', 50, false, 1,
     '{"bg":"#eef4e6","surface":"#f7faf2","surface2":"#e3ecd9","primary":"#3f6212","primaryHover":"#4d7c3f","onPrimary":"#ffffff","onPrimaryMuted":"rgba(255,255,255,0.75)","text":"#1f3d1a","muted":"#6b8e5a","border":"rgba(180,200,160,0.5)","navBg":"rgba(247,250,242,0.92)","accent":"#84cc16","pattern":null}'::jsonb),
    ('pokemon', '宝可梦', '⚡', '红黄蓝活力配色（宝可梦风）', 200, false, 2,
     '{"bg":"#f0f4ff","surface":"#ffffff","surface2":"#e6ecff","primary":"#ee1515","primaryHover":"#c81010","onPrimary":"#ffffff","onPrimaryMuted":"rgba(255,255,255,0.8)","text":"#1e2a4a","muted":"#5b6b9a","border":"rgba(180,190,230,0.6)","navBg":"rgba(255,255,255,0.92)","accent":"#ffcb05","pattern":"poke_dots"}'::jsonb),
    ('line_dog', '线条小狗', '🐶', '黑白线描，极简治愈', 150, false, 3,
     '{"bg":"#fff9f0","surface":"#ffffff","surface2":"#fbeede","primary":"#2b2b2b","primaryHover":"#444444","onPrimary":"#ffffff","onPrimaryMuted":"rgba(255,255,255,0.75)","text":"#2b2b2b","muted":"#8a8175","border":"rgba(220,210,195,0.7)","navBg":"rgba(255,249,240,0.92)","accent":"#f59e0b","pattern":"dog_lines"}'::jsonb),
    ('hp_hermione', '哈利波特', '🪄', '霍格沃茨猩红与金，魔法羊皮纸', 300, false, 4,
     '{"bg":"#f3e9d2","surface":"#fbf5e6","surface2":"#ecdfc2","primary":"#7b1e1e","primaryHover":"#5e1515","onPrimary":"#f5d27a","onPrimaryMuted":"rgba(245,210,122,0.8)","text":"#3d2410","muted":"#8a6d43","border":"rgba(180,150,100,0.5)","navBg":"rgba(251,245,230,0.92)","accent":"#c9a227","pattern":"hp_stars"}'::jsonb)
  on conflict (key) do nothing;
end $$;

-- ###########################################################################
-- 四、列表
-- ###########################################################################
-- 孩子 / 家长都能看：带"已拥有 / 当前"标记。p_member_id 省略 = 自己。
create or replace function app.list_skins(p_member_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
        fid uuid;
        v_mid uuid;
begin
  me := app.require_member();
  fid := me.family_id;
  v_mid := coalesce(p_member_id, me.id);
  -- 越权保护：只能看同家庭的成员
  if not exists (select 1 from app.members where id = v_mid and family_id = fid) then
    v_mid := me.id;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'key', s.key, 'name', s.name, 'emoji', s.emoji,
      'description', s.description, 'is_default', s.is_default, 'theme', s.theme,
      'price', app.skin_price(fid, s.id),
      'owned', (s.is_default or exists (
        select 1 from app.member_skins ms where ms.member_id = v_mid and ms.skin_id = s.id)),
      'current', (s.id = (select selected_skin_id from app.members where id = v_mid)
                  or ((select selected_skin_id from app.members where id = v_mid) is null and s.is_default))
    ) order by s.sort_order, s.name)
      from app.skins s where s.active), '[]'::jsonb);
end $$;

-- 家长定价用：不含"拥有 / 当前"，带基础价 + 家庭生效价。
create or replace function app.list_skins_for_family()
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare fid uuid;
begin
  fid := app.current_family_id();
  if fid is null then return '[]'::jsonb; end if;
  perform app.require_member();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'key', s.key, 'name', s.name, 'emoji', s.emoji,
      'description', s.description, 'is_default', s.is_default,
      'base_price', s.price_points, 'price', app.skin_price(fid, s.id)
    ) order by s.sort_order, s.name)
      from app.skins s where s.active), '[]'::jsonb);
end $$;

-- ###########################################################################
-- 五、孩子兑换皮肤（扣积分 + 记拥有）
--   * 默认皮肤免费、无需兑换
--   * 已拥有 → 拒绝
--   * 复用 point_ledger 的 'redemption' 来源（不改既有枚举约束）
-- ###########################################################################
create or replace function app.redeem_skin(p_skin_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype;
        sk app.skins%rowtype;
        price int;
        v_bal int;
begin
  me := app.require_member();
  select * into sk from app.skins where id = p_skin_id and active;
  if not found then raise exception 'SKIN_NOT_FOUND'; end if;
  if sk.is_default then raise exception 'SKIN_DEFAULT_FREE: 默认皮肤免费，无需兑换'; end if;
  if exists (select 1 from app.member_skins where member_id = me.id and skin_id = sk.id) then
    raise exception 'SKIN_OWNED: 已经拥有这个皮肤'; end if;

  price := app.skin_price(me.family_id, sk.id);
  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < price then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', price - v_bal;
  end if;

  if price > 0 then
    perform app._post_ledger(me.id, -price, 'redemption', sk.id, 0,
                             '兑换皮肤 · ' || sk.name, null, me.id);
  end if;

  insert into app.member_skins (member_id, skin_id) values (me.id, sk.id)
    on conflict do nothing;

  return jsonb_build_object(
    'skin_id', sk.id,
    'points_spent', price,
    'balance', (select points_balance from app.members where id = me.id),
    'owned', true,
    'message', '兑换成功，点「使用」即可换上');
end $$;

-- ###########################################################################
-- 六、切换皮肤（仅已拥有或默认）
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
  if not (sk.is_default or exists (
    select 1 from app.member_skins where member_id = me.id and skin_id = sk.id)) then
    raise exception 'SKIN_NOT_OWNED: 先兑换这个皮肤才能使用'; end if;

  update app.members set selected_skin_id = sk.id where id = me.id;
  return jsonb_build_object('skin_id', sk.id, 'current', true);
end $$;

-- ###########################################################################
-- 七、家长定价（覆盖家庭价；仿 set_badge_bonus）
-- ###########################################################################
create or replace function app.set_skin_price(
  p_skin_id       uuid,
  p_price_points  int,
  p_parent_token  text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype;
        sk      app.skins%rowtype;
begin
  parent := app._parent_guard(p_parent_token);
  if p_skin_id is null then raise exception 'BAD_SKIN_ID'; end if;
  if p_price_points is null or p_price_points < 0 or p_price_points > 100000 then
    raise exception 'BAD_PRICE: 价格要在 0 ~ 100000 之间'; end if;

  select * into sk from app.skins where id = p_skin_id;
  if not found then raise exception 'SKIN_NOT_FOUND'; end if;

  insert into app.skin_family_settings (family_id, skin_id, price_points)
  values (parent.family_id, p_skin_id, p_price_points)
  on conflict (family_id, skin_id) do update
     set price_points = excluded.price_points, updated_at = now();

  return jsonb_build_object('skin_id', p_skin_id, 'price', p_price_points);
end $$;

-- ###########################################################################
-- 八、bootstrap 带上 selected_skin_id（010 之后再次覆盖，最终生效即此版）
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
                     m.selected_skin_id,
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
-- 九、RLS
-- ###########################################################################
alter table app.skins               enable row level security;
alter table app.member_skins        enable row level security;
alter table app.skin_family_settings enable row level security;

drop policy if exists skins_select on app.skins;
create policy skins_select on app.skins
  for select to authenticated using (active);

drop policy if exists member_skins_select on app.member_skins;
create policy member_skins_select on app.member_skins
  for select to authenticated
  using (member_id in (select id from app.members where family_id = app.current_family_id()));

drop policy if exists skin_family_settings_select on app.skin_family_settings;
create policy skin_family_settings_select on app.skin_family_settings
  for select to authenticated
  using (family_id = app.current_family_id());

-- ###########################################################################
-- 十、权限
-- ###########################################################################
grant select on app.skins               to authenticated;
grant select on app.member_skins        to authenticated;
grant select on app.skin_family_settings to authenticated;
grant all    on app.skins               to service_role;
grant all    on app.member_skins        to service_role;
grant all    on app.skin_family_settings to service_role;

grant execute on function app.skin_price(uuid, uuid)            to authenticated, service_role;
grant execute on function app.seed_skins()                      to authenticated, service_role;
grant execute on function app.list_skins(uuid)                  to authenticated, service_role;
grant execute on function app.list_skins_for_family()           to authenticated, service_role;
grant execute on function app.redeem_skin(uuid)                 to authenticated, service_role;
grant execute on function app.set_member_skin(uuid)             to authenticated, service_role;
grant execute on function app.set_skin_price(uuid, int, text)   to authenticated, service_role;

-- ###########################################################################
-- 十一、预置皮肤目录（幂等，已部署库也会补上 5 个皮肤）
-- ###########################################################################
select app.seed_skins();
