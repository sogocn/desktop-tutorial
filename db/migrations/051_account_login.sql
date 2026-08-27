-- =============================================================================
-- 051_account_login.sql —— 用户名 + PIN 登录（跨设备）
-- =============================================================================
-- 之前身份 = 本地随机 user_id + login_key，换设备登不进来（没有可记忆的凭证）。
-- 现在每个成员额外有 username（唯一）+ 复用已有的 pin_hash/pin_salt 作为密码，
-- 登录 = (username, PIN) → 校验 → 返回该成员的 JWT。这样在任何设备输入
-- 同一组用户名+PIN 都能拿到同一个 user_id 的数据，实现"跨设备登录"。
-- =============================================================================

alter table app.members add column if not exists username text;

-- 用户名唯一。允许 NULL 以兼容"家长代建、尚未认领"的成员；认领时由 join_family 写入。
create unique index if not exists members_username_uidx on app.members(username);

-- 登录校验：用户名 + PIN → 返回该成员的 user_id / nickname / role。
-- 故意把"用户名不存在"和"PIN 错"合并成同一条，避免被用来枚举用户名。
create or replace function app.login_by_pin(p_username text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  m app.members%rowtype;
begin
  select * into m from app.members where username = lower(btrim(p_username));
  if not found then
    raise exception 'LOGIN_FAIL: 用户名或 PIN 不正确';
  end if;
  if m.pin_hash is null then
    raise exception 'LOGIN_FAIL: 该账号尚未设置 PIN';
  end if;
  if app.hash_pin(p_pin, m.pin_salt) <> m.pin_hash then
    raise exception 'LOGIN_FAIL: 用户名或 PIN 不正确';
  end if;
  return jsonb_build_object('user_id', m.user_id, 'nickname', m.nickname, 'role', m.role);
end $$;

grant execute on function app.login_by_pin(text, text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- create_family：新增 p_username，且 PIN 改为必填（登录必须要有密码）。
-- 旧签名 (text,text,text,text,text) 与新签名参数不同，先 drop 旧重载避免歧义。
-- ---------------------------------------------------------------------------
drop function if exists app.create_family(text, text, text, text, text);

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

  insert into app.reward_items (family_id, name, emoji, pricing_mode, rate_points, unit_label,
                                min_quantity, step_quantity, requires_approval, sort_order)
  values (f.id, '现金', '💰', 'rate', 100, '元', 1, 1, true, 0);

  return jsonb_build_object(
    'family_id', f.id, 'member_id', m.id, 'user_id', v_uid,
    'child_invite_code', v_child_code, 'parent_invite_code', v_parent_code);
end $$;

-- ---------------------------------------------------------------------------
-- join_family：新增 p_username / p_pin，认领分支(claim)和新成员分支都写入
-- username + pin_hash/pin_salt。旧签名 (text,text,text) 先 drop。
-- ---------------------------------------------------------------------------
drop function if exists app.join_family(text, text, text);

create or replace function app.join_family(
  p_code text, p_username text, p_pin text,
  p_nickname text default null, p_avatar text default '🙂'
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_uid uuid; inv app.invites%rowtype; m app.members%rowtype;
  v_uname text; v_salt text;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'NO_AUTH'; end if;
  if exists (select 1 from app.members where user_id = v_uid) then
    raise exception 'ALREADY_IN_FAMILY';
  end if;

  v_uname := lower(btrim(p_username));
  if v_uname = '' then raise exception 'USERNAME_REQUIRED: 请填写用户名'; end if;
  if exists (select 1 from app.members where username = v_uname) then
    raise exception 'USERNAME_TAKEN: 用户名已被占用';
  end if;
  if p_pin is null or p_pin !~ '^\d{4}$' then
    raise exception 'BAD_PIN: PIN 必须是 4 位数字';
  end if;

  select * into inv from app.invites where code = upper(btrim(p_code));
  if not found then raise exception 'INVITE_NOT_FOUND: 邀请码不存在'; end if;
  if inv.revoked_at is not null then raise exception 'INVITE_REVOKED: 邀请码已作废'; end if;
  if inv.expires_at is not null and inv.expires_at < now() then
    raise exception 'INVITE_EXPIRED: 邀请码已过期';
  end if;
  if inv.max_uses > 0 and inv.used_count >= inv.max_uses then
    raise exception 'INVITE_USED_UP: 邀请码已用完';
  end if;

  v_salt := app.gen_salt_text();
  if inv.member_id is not null then
    -- 认领家长代建的成员：补上 username + PIN
    update app.members
       set user_id = v_uid,
           nickname = coalesce(nullif(btrim(p_nickname), ''), nickname),
           username = v_uname,
           pin_hash = app.hash_pin(p_pin, v_salt),
           pin_salt = v_salt
     where id = inv.member_id
     returning * into m;
  else
    if nullif(btrim(coalesce(p_nickname, '')), '') is null then
      raise exception 'NICKNAME_REQUIRED: 请填写昵称';
    end if;
    insert into app.members (family_id, user_id, nickname, role, avatar_emoji, username, pin_hash, pin_salt)
    values (inv.family_id, v_uid, btrim(p_nickname), inv.role, coalesce(p_avatar, '🙂'), v_uname,
            app.hash_pin(p_pin, v_salt), v_salt)
    returning * into m;
  end if;

  update app.invites set used_count = used_count + 1 where id = inv.id;

  return jsonb_build_object('family_id', m.family_id, 'member_id', m.id, 'role', m.role, 'username', m.username);
end $$;
