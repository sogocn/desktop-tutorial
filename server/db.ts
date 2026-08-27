import pg from 'pg'

const { Pool } = pg

const connectionString = process.env.DATABASE_URL
if (!connectionString) {
  throw new Error('DATABASE_URL 未设置（格式 postgres://user:pass@host:5432/dbname）')
}

export const pool = new Pool({ connectionString, max: 10 })

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
    const role = sub ? 'authenticated' : 'anon'
    if (sub) {
      await client.query('SELECT set_config($1, $2, true)', [
        'request.jwt.claims',
        JSON.stringify({ sub, role: 'authenticated' }),
      ])
    }
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
