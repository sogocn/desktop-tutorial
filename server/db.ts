import pg from 'pg'

const { Pool } = pg

const connectionString = process.env.DATABASE_URL
if (!connectionString) {
  throw new Error('DATABASE_URL 未设置（格式 postgres://user:pass@host:5432/dbname）')
}

export const pool = new Pool({ connectionString, max: 10 })

// node-postgres 默认把 DATE(1082) 列解析成 JS Date（且是服务器本地时区的零点），
// JSON 序列化后变成 ISO UTC 字符串（如 "2026-08-26T16:00:00.000Z"）。
// 前端（PGlite 本地模式）期望的是原始 'YYYY-MM-DD' 字符串 —— 两边不一致会导致
// 今天/日历页按日期比较/分组永远匹配不上（任务全部"消失"）。
// 这里把 DATE 保持为原始字符串，与 PGlite 的行为对齐。
pg.types.setTypeParser(1082, (v) => v)

/**
 * 以某个成员身份（sub = members.user_id）在事务内执行。
 * 完全复刻 pglite.adapter 的本地做法：
 *   set_config('request.jwt.claims', ...) → SET ROLE authenticated → 跑查询
 * 区别是这里用事务级 SET LOCAL，连接归还池后角色自动复位，避免串号。
 * sub 为空时降级为 anon（RLS/授权都会拒绝，等同游客）。
 */
export async function runAsMember<T>(
  sub: string | null,
  fn: (client: pg.PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    // 游客与已登录成员都用 authenticated 角色：它拥有 app schema 的 EXECUTE/RLS 权限。
    // 区别只在 request.jwt.claims.sub 是否有值 —— RLS 据此过滤数据。
    // （anon 角色没有 app 函数的 EXECUTE 权限，不能用来跑 bootstrap_state 等函数。）
    const role = 'authenticated'
    await client.query('SELECT set_config($1, $2, true)', [
      'request.jwt.claims',
      JSON.stringify({ sub: sub ?? null, role }),
    ])
    await client.query(`SET LOCAL ROLE ${role}`)
    const result = await fn(client)
    await client.query('COMMIT')
    return result
  } catch (e) {
    await client.query('ROLLBACK')
    throw e
  } finally {
    client.release()
  }
}

/** 以 service_role（bypassrls）在事务内执行，用于绕开 RLS 的管理类读取/写入。 */
export async function runAsService<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    await client.query('SET LOCAL ROLE service_role')
    const result = await fn(client)
    await client.query('COMMIT')
    return result
  } catch (e) {
    await client.query('ROLLBACK')
    throw e
  } finally {
    client.release()
  }
}
