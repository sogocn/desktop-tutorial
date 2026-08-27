import { BackendError, type BackendClient } from './types'
import { useSession } from '@/store/session'

const API = '/api'

// 这些 RPC 在建成员行之前调用，必须走"临时身份"头（X-User-Id + X-Login-Key），
// 跑完服务端会把 login_key 落库，之后就能换 JWT。
const BOOTSTRAP_FNS = new Set(['create_family', 'join_family', 'add_member'])

function loginKeyFor(userId: string | null): string | null {
  if (!userId) return null
  const u = useSession.getState().knownUsers.find((k) => k.userId === userId)
  return u?.loginKey ?? null
}

export class ServerBackend implements BackendClient {
  private activeUserId: string | null = null
  private activeToken: string | null = null
  private tokenCache = new Map<string, string>()

  async ready(): Promise<void> {
    // 服务端不需要本地建库，连接即就绪
  }

  private async fetchToken(userId: string): Promise<string | null> {
    const key = loginKeyFor(userId)
    if (!key) return null
    const res = await fetch(`${API}/auth/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ userId, loginKey: key }),
    })
    if (!res.ok) return null
    const data = (await res.json()) as { token?: string }
    return data.token ?? null
  }

  async setIdentity(userId: string | null): Promise<void> {
    this.activeUserId = userId
    if (!userId) {
      this.activeToken = null
      return
    }
    // 尝试换 JWT；换不到（成员还没建）就留空，引导类 RPC 会用临时身份头
    const cached = this.tokenCache.get(userId)
    if (cached) {
      this.activeToken = cached
      return
    }
    const token = await this.fetchToken(userId)
    this.activeToken = token
    if (token) this.tokenCache.set(userId, token)
  }

  async query<T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T[]> {
    const res = await fetch(`${API}/query`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({ sql, params }),
    })
    if (!res.ok) throw new BackendError(await this.err(res))
    const data = (await res.json()) as { rows: T[] }
    return data.rows
  }

  async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    const useProvisional = BOOTSTRAP_FNS.has(fn) && !this.activeToken
    const res = await fetch(`${API}/rpc`, {
      method: 'POST',
      headers: useProvisional ? this.provisionalHeaders() : this.headers(),
      body: JSON.stringify({ fn, args }),
    })
    if (!res.ok) throw new BackendError(await this.err(res))
    const data = (await res.json()) as { result: T }

    // 引导成功后换 JWT，后续调用走 Bearer；add_member 还会回传孩子的 login_key
    if (useProvisional && this.activeUserId) {
      const token = await this.fetchToken(this.activeUserId)
      if (token) {
        this.activeToken = token
        this.tokenCache.set(this.activeUserId, token)
      }
    }
    const result = data.result as T & { login_key?: string; user_id?: string }
    if (result?.login_key && result?.user_id) {
      this.cacheChildKey(result.user_id, result.login_key)
    }
    return data.result
  }

  async dump(): Promise<Blob> {
    // 云端数据由服务端托管，本地无需导出备份
    return new Blob([JSON.stringify({ note: '云端数据由服务端托管，无需本地备份' })], {
      type: 'application/json',
    })
  }

  async reset(): Promise<void> {
    throw new BackendError('CLOUD_RESET_UNSUPPORTED: 云端数据请在服务端管理，不支持本机清空')
  }

  // ---- 内部 ----
  private headers(): Record<string, string> {
    const h: Record<string, string> = { 'content-type': 'application/json' }
    if (this.activeToken) h['authorization'] = `Bearer ${this.activeToken}`
    return h
  }

  private provisionalHeaders(): Record<string, string> {
    const key = loginKeyFor(this.activeUserId)
    return {
      'content-type': 'application/json',
      'x-user-id': this.activeUserId ?? '',
      'x-login-key': key ?? '',
    }
  }

  private cacheChildKey(userId: string, loginKey: string) {
    const s = useSession.getState()
    const exists = s.knownUsers.some((k) => k.userId === userId)
    if (!exists) {
      s.addKnownUser({ userId, nickname: '家庭成员', role: 'child', loginKey })
    }
  }

  private async err(res: Response): Promise<string> {
    try {
      const d = (await res.json()) as { error?: string }
      return d.error ?? `HTTP ${res.status}`
    } catch {
      return `HTTP ${res.status}`
    }
  }
}
