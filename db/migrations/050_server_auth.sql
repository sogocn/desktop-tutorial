-- =============================================================================
-- 050_server_auth.sql —— 自托管后端的身份密钥
-- =============================================================================
-- CloudBase / Supabase 自带账号体系与 auth.uid() 的绑定，不需要这一层。
-- 我们选了"全自建在轻量云"：成员身份 = (user_id, login_key)。
--   * user_id     公开标识（UUID），设备用它定位自己的成员行
--   * login_key   私密凭证（随机串），跨设备迁移身份时随身携带
-- 同一人在不同设备只要带上同一对 (user_id, login_key)，就能拿到同一个
-- sub 的 JWT，看到同一份家庭数据 —— 这就是"多端同步"。
-- =============================================================================

alter table app.members add column if not exists login_key_hash text;

-- user_id 必须能唯一定位一个成员（本地每浏览器一个，服务端跨设备复用同一个）
create unique index if not exists members_user_id_uidx on app.members(user_id);

-- 把当前身份的登录密钥哈希写进自己的行。SECURITY DEFINER + auth.uid() 保证
-- 只能写自己，且即使在 RLS 下也能执行（策略不递归）。
create or replace function app.set_member_login_key(p_key_hash text)
returns void
language plpgsql security definer set search_path = app, public as $$
begin
  update app.members set login_key_hash = p_key_hash where user_id = auth.uid();
  if not found then
    raise exception 'NOT_A_MEMBER: 无法绑定登录密钥';
  end if;
end $$;

grant execute on function app.set_member_login_key(text) to authenticated, service_role;
