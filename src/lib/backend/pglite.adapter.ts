import { PGlite } from '@electric-sql/pglite'
import { BackendError, type BackendClient } from './types'

// db/ 下的 SQL 在打包时内联进来。它们和将来上云要执行的是同一批文件。
const localSql = import.meta.glob('/db/local/*.sql', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>

const migrationSql = import.meta.glob('/db/migrations/*.sql', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>

const DATA_DIR = 'idb://familyquest'

// Postgres 内置类型 OID：date=1082，timestamp=1114，timestamptz=1184。
// 只覆盖 date，时间戳类型保持 PGlite 默认解析（JS Date），绝不截断。
const PG_TYPE_DATE = 1082

/**
 * PGlite 默认把 Postgres date 解析成 JS Date 对象，序列化后形如
 * '2026-08-21T00:00:00.000Z'，而按 CLAUDE.md 铁律 4 前端 date 语义字段
 * 一律是 'YYYY-MM-DD' 纯日期字符串（TodayPage/CalendarPage 用严格相等比较，
 * 一个带时间一个不带就永远对不上）。这里用 PGlite 官方类型解析器机制
 * （ParserOptions，按类型 OID 覆盖默认 parser），把 date 的文本输出原样截成
 * 'YYYY-MM-DD'；timestamptz/timestamp 不在覆盖范围，仍返回 Date。
 */
const dateParser = (v: string): string => (v.length >= 10 ? v.slice(0, 10) : v)

export class PGliteBackend implements BackendClient {
  private pg: PGlite | null = null
  private booting: Promise<void> | null = null
  private identity: string | null = null

  async ready(): Promise<void> {
    if (!this.booting) this.booting = this.boot()
    return this.booting
  }

  private async boot() {
    this.pg = await PGlite.create({
      dataDir: DATA_DIR,
      relaxedDurability: true,
      parsers: { [PG_TYPE_DATE]: dateParser },
    })
    await this.migrate()
    await this.applyIdentity()
  }

  private async migrate() {
    const pg = this.pg!
    // 迁移必须以超级用户身份跑（建角色、建 SECURITY DEFINER 函数）
    await pg.exec('reset role;')
    await pg.exec(`
      create table if not exists public.__migrations (
        name text primary key,
        applied_at timestamptz not null default now()
      );
    `)

    const files = [
      ...Object.keys(localSql).sort().map((p) => [p, localSql[p]] as const),
      ...Object.keys(migrationSql).sort().map((p) => [p, migrationSql[p]] as const),
    ]

    for (const [path, sql] of files) {
      const done = await pg.query<{ n: number }>(
        'select count(*)::int as n from public.__migrations where name = $1',
        [path],
      )
      if ((done.rows[0]?.n ?? 0) > 0) continue
      try {
        // 简单查询协议下多语句本身就是一个隐式事务，失败自动整体回滚
        await pg.exec(sql)
        await pg.query('insert into public.__migrations (name) values ($1)', [path])
      } catch (err) {
        throw new Error(`迁移失败 ${path}：${(err as Error).message}`)
      }
    }
  }

  /**
   * 这一步是本地能不能正确验证 RLS 的关键。
   * PGlite 默认以超级用户连接，超级用户绕过所有 RLS ——
   * 不 SET ROLE 的话本地怎么写都通，上云才发现越权，那时候已经晚了。
   */
  private async applyIdentity() {
    const pg = this.pg!
    await pg.exec('reset role;')
    await pg.query('select set_config($1, $2, false)', [
      'request.jwt.claims',
      JSON.stringify({ sub: this.identity, role: 'authenticated' }),
    ])
    await pg.exec('set role authenticated;')
  }

  async setIdentity(userId: string | null) {
    this.identity = userId
    if (this.pg) await this.applyIdentity()
  }

  async login(
    _username: string,
    _pin: string,
  ): Promise<{ userId: string; token: string; nickname: string; role: string }> {
    throw new BackendError('本地模式不支持用户名登录，请使用服务器模式')
  }

  async query<T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T[]> {
    await this.ready()
    try {
      const res = await this.pg!.query<T>(sql, params as never[])
      return res.rows
    } catch (err) {
      throw new BackendError((err as Error).message)
    }
  }

  async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    const keys = Object.keys(args)
    const call = keys.map((k, i) => `${k} => $${i + 1}`).join(', ')
    const values = keys.map((k) => {
      const v = args[k]
      // 数组（uuid[] 等）原样透传，由驱动按参数类型做原生数组序列化；
      // 只有对象才按 JSON 字符串传（给 jsonb 字段用）。
      // 以前把数组也 JSON.stringify，导致 uuid[] 收到 "["uuid"]" 字面量而报
      // "malformed array literal"。
      return v !== null && typeof v === 'object' && !Array.isArray(v) ? JSON.stringify(v) : v
    })
    const rows = await this.query<{ result: T }>(`select app.${fn}(${call}) as result`, values)
    return rows[0]?.result as T
  }

  async dump(): Promise<Blob> {
    await this.ready()
    const file = await this.pg!.dumpDataDir('gzip')
    return file as unknown as Blob
  }

  async reset(): Promise<void> {
    if (this.pg) await this.pg.close()
    this.pg = null
    this.booting = null
    // 实测 indexedDB.databases() 里真实库名是 "/pglite/familyquest"，不是 "familyquest"。
    // 依据（@electric-sql/pglite 源码 IdbFs.init()）：
    //   FS.mkdir('/pglite'); FS.mount(IDBFS, {}, `/pglite/${dataDir}`)
    // 而 Emscripten IDBFS 以挂载点 mount.mountpoint 作为 IndexedDB 库名
    // （IDBFS.getDB(e.mountpoint)）。所以 idb://familyquest → "/pglite/familyquest"，
    // 前缀 "/pglite/" 是 PGlite 内部固定加的，这里按同一规则推导，不硬编码猜测。
    const idbName = `/pglite/${DATA_DIR.replace(/^idb:\/\//, '')}`
    await this.deleteIdb(idbName)
  }

  /**
   * 删除 IndexedDB 库。onblocked 意味着另一个标签页仍持有该库的连接，浏览器会
   * 阻塞删除 —— 不能像旧实现那样静默放行（UI 显示已清空、数据实际还在）。
   * 处理：console.warn 提示 + 每 300ms 重试，最多等 ~3 秒；单标签页场景删除一定
   * 真正完成，多标签页场景最多等 3 秒后放弃并告警，避免永久挂起或假成功。
   */
  private async deleteIdb(idbName: string): Promise<void> {
    const deadline = Date.now() + 3_000
    for (;;) {
      const outcome = await new Promise<'deleted' | 'blocked'>((resolve, reject) => {
        const req = indexedDB.deleteDatabase(idbName)
        req.onsuccess = () => resolve('deleted')
        req.onerror = () => reject(req.error)
        req.onblocked = () => resolve('blocked')
      })
      if (outcome === 'deleted') return
      console.warn(
        `[familyquest] 删除 IndexedDB 库 ${idbName} 被其他标签页阻塞，300ms 后重试`,
      )
      if (Date.now() >= deadline) {
        console.warn(
          `[familyquest] 等待 ${idbName} 释放连接超时（>3s），放弃删除；请关闭其他打开本应用的标签页后重试`,
        )
        return
      }
      await new Promise((r) => setTimeout(r, 300))
    }
  }
}
