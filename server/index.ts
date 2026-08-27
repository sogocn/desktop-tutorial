import express from 'express'
import type { Request, Response } from 'express'
import { pool, runAsMember, runAsService } from './db'
import { signToken, verifyToken, hashKey } from './auth'

const app = express()
app.use(express.json({ limit: '1mb' }))

const PORT = Number(process.env.PORT ?? 3000)

// 这些 RPC 在建成员行、还没有 JWT，需要"临时身份"(X-User-Id + X-Login-Key)引导，
// 跑完后把 login_key 落库，后续就能用 JWT 了。
const BOOTSTRAP_FNS = new Set(['create_family', 'join_family', 'add_member'])

interface RpcBody {
  fn: string
  args?: Record<string, unknown>
}

function jsonValue(v: unknown): unknown {
  // 对象/数组按 JSON 字符串传，避免驱动把它当成 Postgres 数组字面量
  return v !== null && typeof v === 'object' ? JSON.stringify(v) : v
}

app.get('/api/health', (_req, res) => {
  res.json({ ok: true })
})

/**
 * 取身份：优先 Bearer JWT；否则看临时身份头。返回 { sub, provisional }。
 * 两者都没有 → 401。
 */
function resolveIdentity(req: Request): { sub: string; provisional: boolean } | null {
  const auth = req.headers['authorization']
  if (typeof auth === 'string' && auth.startsWith('Bearer ')) {
    try {
      return { sub: verifyToken(auth.slice(7)).sub, provisional: false }
    } catch {
      return null
    }
  }
  const uid = req.headers['x-user-id']
  const key = req.headers['x-login-key']
  if (typeof uid === 'string' && typeof key === 'string') {
    return { sub: uid, provisional: true }
  }
  return null
}

// ---------------------------------------------------------------------------
// 业务动作 / 读取：RPC
// ---------------------------------------------------------------------------
app.post('/api/rpc', async (req: Request, res: Response) => {
  const { fn, args } = req.body as RpcBody
  if (typeof fn !== 'string') return res.status(400).json({ error: 'fn 必填' })

  // bootstrap_state 允许游客身份（首次打开 / 退出身份后）：以 anon 跑，
  // 函数内部 auth.uid() 为 null → 直接返回 {"in_family": false}，前端据此进入引导页。
  const ident = resolveIdentity(req)
  if (!ident && fn !== 'bootstrap_state') {
    return res.status(401).json({ error: '未认证' })
  }
  const safeIdent = ident ?? { sub: null, provisional: false }

  try {
    const result = await runAsMember(safeIdent.sub, async (client) => {
      const keys = Object.keys(args ?? {})
      const call = keys.map((k, i) => `${k} => $${i + 1}`).join(', ')
      const values = keys.map((k) => jsonValue((args ?? {})[k]))
      const sql = `select app.${fn}(${call}) as result`
      const rows = await client.query(sql, values)
      return rows.rows[0]?.result ?? null
    })

    // 引导阶段：把登录密钥落库，让这个身份之后能换 JWT
    if (safeIdent.provisional && BOOTSTRAP_FNS.has(fn)) {
      const loginKey = String(req.headers['x-login-key'])
      if (fn === 'add_member') {
        const childUserId = (result as { user_id?: string } | null)?.user_id
        if (childUserId) {
          await runAsService((c) =>
            c.query('update app.members set login_key_hash = $1 where user_id = $2', [
              hashKey(loginKey),
              childUserId,
            ]),
          )
          return res.json({ result: { ...(result as object), login_key: loginKey } })
        }
      } else {
        await runAsMember(safeIdent.sub, (c) =>
          c.query('select app.set_member_login_key($1)', [hashKey(loginKey)]),
        )
      }
    }

    return res.json({ result })
  } catch (e) {
    return res.status(400).json({ error: (e as Error).message })
  }
})

// ---------------------------------------------------------------------------
// 直接 SELECT（业务层的 getCalendar / getTask / listTasks 等走这里）
// ---------------------------------------------------------------------------
app.post('/api/query', async (req: Request, res: Response) => {
  const { sql, params } = req.body as { sql: string; params?: unknown[] }
  if (typeof sql !== 'string') return res.status(400).json({ error: 'sql 必填' })

  const ident = resolveIdentity(req)
  if (!ident || ident.provisional) {
    return res.status(401).json({ error: '需要先登录' })
  }

  try {
    const rows = await runAsMember(ident.sub, (client) =>
      client.query(sql, (params ?? []) as unknown[]),
    )
    return res.json({ rows: (rows as { rows?: unknown[] }).rows ?? rows })
  } catch (e) {
    return res.status(400).json({ error: (e as Error).message })
  }
})

// ---------------------------------------------------------------------------
// 用 (user_id, login_key) 换 JWT
// ---------------------------------------------------------------------------
app.post('/api/auth/token', async (req: Request, res: Response) => {
  const { userId, loginKey } = req.body as { userId?: string; loginKey?: string }
  if (!userId || !loginKey) return res.status(400).json({ error: 'userId / loginKey 必填' })

  try {
    const hash = await runAsService(async (c) => {
      const r = await c.query('select login_key_hash from app.members where user_id = $1', [userId])
      return r.rows[0]?.login_key_hash as string | undefined
    })
    if (!hash || hash !== hashKey(loginKey)) {
      return res.status(401).json({ error: '身份密钥错误' })
    }
    return res.json({ token: signToken(userId) })
  } catch (e) {
    return res.status(400).json({ error: (e as Error).message })
  }
})

// ---------------------------------------------------------------------------
// 用户名 + PIN 登录（跨设备）。校验通过返回该成员的 JWT，前端据此在任何设备
// 拿到同一份家庭数据。错误统一成 401，不暴露用户名是否存在。
// ---------------------------------------------------------------------------
app.post('/api/auth/login', async (req: Request, res: Response) => {
  const { username, pin } = req.body as { username?: string; pin?: string }
  if (!username || !pin) return res.status(400).json({ error: '用户名 / PIN 必填' })

  try {
    const result = await runAsService(async (c) => {
      const r = await c.query('select app.login_by_pin($1, $2) as result', [username, pin])
      return r.rows[0]?.result as { user_id: string; nickname: string; role: string }
    })
    return res.json({
      userId: result.user_id,
      token: signToken(result.user_id),
      nickname: result.nickname,
      role: result.role,
    })
  } catch (e) {
    // 服务端函数抛 'LOGIN_FAIL: ...'，统一回 401，不泄露细节
    return res.status(401).json({ error: '用户名或 PIN 不正确' })
  }
})

app.listen(PORT, () => {
  console.log(`[familyquest] API listening on :${PORT}`)
})

process.on('SIGINT', () => {
  void pool.end().then(() => process.exit(0))
})
