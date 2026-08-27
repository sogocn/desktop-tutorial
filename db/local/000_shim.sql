-- =============================================================================
-- 000_shim.sql  ——  仅本地（PGlite）执行，永远不要上传到 CloudBase / Supabase
-- =============================================================================
-- 云端已经预置好这些东西：
--   * anon / authenticated / service_role 三个角色
--   * auth schema 与 auth.uid() / auth.role() / auth.jwt()
-- 本地 PGlite 是一个裸 Postgres，必须自己补出来，否则：
--   1) 迁移文件里的 GRANT ... TO authenticated 会直接报 role 不存在
--   2) 没有 auth.uid()，RLS 策略无从判断"我是谁"
--
-- 所有本地与云端的差异都必须收敛在这一个文件里。任何时候你想在
-- db/migrations/*.sql 里写 "if local then ..."，先回来看这一行。
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

-- 让当前超级用户可以 SET ROLE 过去
do $$
begin
  execute format('grant anon, authenticated, service_role to %I', current_user);
exception when others then
  null; -- 已经授予过
end $$;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- PostgREST / CloudBase 的约定：请求的 JWT payload 放在 request.jwt.claims 里。
-- 本地由 pglite.adapter.ts 在每次切换成员时 set_config 写入。
create or replace function auth.jwt() returns jsonb
  language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  )
$$;

create or replace function auth.uid() returns uuid
  language sql stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
  language sql stable
as $$
  select coalesce(nullif(auth.jwt() ->> 'role', ''), 'anon')
$$;

grant execute on function auth.jwt(), auth.uid(), auth.role()
  to anon, authenticated, service_role;
