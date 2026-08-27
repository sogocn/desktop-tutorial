-- =============================================================================
-- 000_init.sql —— schema 与通用工具
-- 本地(PGlite)与云端(CloudBase PG)执行同一份文件，不允许出现任何环境分支。
-- =============================================================================

create schema if not exists app;

-- 不引 pgcrypto：gen_random_uuid() 从 PG13 起已进内核，PIN 哈希用内核的
-- sha256(bytea)。少一个扩展依赖 = 少一个上云时可能没开的东西。
comment on schema app is 'FamilyQuest 业务 schema';

-- ---------------------------------------------------------------------------
-- 随机短码：家庭邀请码用。去掉 0/O/1/I/l 这些肉眼易混的字符。
-- ---------------------------------------------------------------------------
create or replace function app.gen_code(p_len int default 6)
returns text
language plpgsql volatile
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  out_text text := '';
  i int;
begin
  for i in 1..p_len loop
    out_text := out_text || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return out_text;
end $$;

-- ---------------------------------------------------------------------------
-- PIN 哈希（sha256(pin || salt)，salt 每人一份）
-- 家庭 4 位 PIN 的威胁模型是"弟弟偷看"，不是"离线爆破"，sha256 足够；
-- 真正的闸门是 pin_attempts 的失败次数限制。
-- ---------------------------------------------------------------------------
create or replace function app.hash_pin(p_pin text, p_salt text)
returns text
language sql immutable
as $$
  select encode(sha256(convert_to(p_salt || ':' || p_pin, 'UTF8')), 'hex')
$$;

create or replace function app.gen_salt_text()
returns text
language sql volatile
as $$
  select encode(sha256(convert_to(random()::text || clock_timestamp()::text, 'UTF8')), 'hex')
$$;
