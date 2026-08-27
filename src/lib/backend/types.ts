// 业务代码只认这个接口。换后端 = 换一个实现，上层一行不改。
export interface BackendClient {
  /** 建库 / 跑迁移，只会真正执行一次 */
  ready(): Promise<void>
  /** 切换当前身份（对应云端 JWT 的 sub）。切完之后 RLS 看到的就是这个人。 */
  setIdentity(userId: string | null): Promise<void>
  query<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]>
  /** 调 app schema 下的函数，参数用具名写法，和 PostgREST 的 RPC 语义一致 */
  rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T>
  /** 导出整库快照（本地阶段的备份手段） */
  dump(): Promise<Blob>
  /** 清库重来 */
  reset(): Promise<void>
}

export class BackendError extends Error {
  code: string
  constructor(message: string) {
    // 服务端约定：'CODE: 人话' —— 前端据此判断分支，同时能直接把人话显示出来
    const m = /^([A-Z_]+):\s*(.*)$/s.exec(message)
    super(m ? m[2] : message)
    this.code = m ? m[1] : 'UNKNOWN'
    this.name = 'BackendError'
  }
}
