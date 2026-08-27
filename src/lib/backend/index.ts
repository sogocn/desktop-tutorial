import type { BackendClient } from './types'

let instance: BackendClient | null = null
let creating: Promise<BackendClient> | null = null

/**
 * 数据层唯一入口。业务代码 import 这里，永远不要 import 具体 adapter，
 * 更不要 import @electric-sql/pglite —— 见 CLAUDE.md 铁律 1。
 */
export async function getBackend(): Promise<BackendClient> {
  if (instance) return instance
  if (!creating) {
    creating = (async () => {
      const mode = import.meta.env.VITE_BACKEND ?? 'pglite'
      if (mode === 'server') {
        // 自托管后端（轻量云）：Postgres + Node 代理，详见 server/、deploy/nginx.conf
        const { ServerBackend } = await import('./server.adapter')
        const client = new ServerBackend()
        await client.ready()
        instance = client
        return client
      }
      if (mode !== 'pglite') {
        // M5 会在这里挂上 cloudbase.adapter.ts
        throw new Error(`未知的后端模式：${mode}`)
      }
      // 动态 import：3MB 的 WASM 单独成 chunk，不拖首屏
      const { PGliteBackend } = await import('./pglite.adapter')
      const client = new PGliteBackend()
      await client.ready()
      instance = client
      return client
    })()
  }
  return creating
}

export type { BackendClient } from './types'
export { BackendError } from './types'
