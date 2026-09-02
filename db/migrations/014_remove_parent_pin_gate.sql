-- =============================================================================
-- 014_remove_parent_pin_gate.sql —— 家长操作免 PIN/token 直通
-- =============================================================================
-- 背景：PIN 本来只应是"登录家长身份"的凭证，结果在每一步家长操作上都被
-- 反复重验。前端体验："想打个赏/审个批 → '需要家长验证，请先输入 PIN'
-- → 跳我的页 → 输 PIN → 回来重做"。
--
-- 家长身份 (role='parent') 本身就是足够的闸门：孩子 role='child' 会被
-- require_member + role 检查挡在门外。所以这次把 PIN 从"每一步的二次校验"
-- 降级回"登录凭证"。
--
-- 改动（两处，缺一不可）：
--   1) app.require_parent：没传 token 时不再一律拒绝，改为走角色闸门。
--      这一处是根因——decide_redemption / revoke_ledger_entry / add_member
--      是**直接**调 require_parent 的，光改 _parent_guard 管不到它们。
--   2) app._parent_guard：没传 token 时去掉 pin_hash 强制分支。
--      覆盖 adjust_member_points / upsert_badge / delete_badge /
--      set_badge_bonus / set_family_settings。
--
-- 保持不变（严格性没被削弱）：
--   * 传了 token：照旧严格校验（错 token → PARENT_TOKEN_INVALID，
--     过期 → PARENT_TOKEN_EXPIRED），PIN 登录 / 家长会话链路完整保留。
--   * 孩子无论带不带 token，一律 FORBIDDEN。
--   * set_pin / login_by_pin 这些真正"验 PIN"的入口一个没动。
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1) require_parent：null token → 家长角色闸门，而不是无条件拒绝
-- -----------------------------------------------------------------------------
create or replace function app.require_parent(p_token text)
returns app.members
language plpgsql stable security definer set search_path = app, public as $$
declare m app.members%rowtype; s app.parent_sessions%rowtype;
begin
  -- 014：没带 token 不再强制验 PIN，家长角色本身就是闸门
  if p_token is null then
    m := app.require_member();
    if m.role <> 'parent' then
      raise exception 'FORBIDDEN: 只有家长能做这件事';
    end if;
    return m;
  end if;

  select * into s from app.parent_sessions where token = p_token;
  if not found then raise exception 'PARENT_TOKEN_INVALID: 需要家长验证'; end if;
  if s.expires_at < now() then raise exception 'PARENT_TOKEN_EXPIRED: 家长验证已过期，请重新输入 PIN'; end if;

  select * into m from app.members where id = s.member_id and archived_at is null;
  if not found or m.role <> 'parent' then raise exception 'PARENT_TOKEN_INVALID'; end if;
  return m;
end $$;


-- -----------------------------------------------------------------------------
-- 2) _parent_guard：去掉 pin_hash 强制分支（与 1) 语义对齐）
-- -----------------------------------------------------------------------------
create or replace function app._parent_guard(p_token text)
returns app.members
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  -- 带了 token：维持原来的严格校验（PIN 登录签发的家长会话仍生效）
  if p_token is not null then
    return app.require_parent(p_token);
  end if;

  -- 没带 token：只要是家长角色就放行，不再因为设过 PIN 而强制重验
  me := app.require_member();
  if me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只有家长能做这件事';
  end if;
  return me;
end $$;
