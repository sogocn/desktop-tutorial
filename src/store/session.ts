import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { Ymd } from '@/lib/date'

/**
 * 本地阶段没有 auth 服务，用一个持久化的随机 uuid 冒充 JWT 的 sub。
 * 它就是 auth.uid() 看到的东西 —— 换句话说，清掉它 = 换了个人。
 * 上云后这里替换成真实 token 的 sub，其余代码一行不动。
 */
function newUserId(): string {
  return crypto.randomUUID()
}

/**
 * 本机已知的一个身份。没有账号体系，靠它实现"退出后一键恢复"：
 * signOut 只清当前身份，不清这个列表 —— 用户随时可以点回原来的身份和数据。
 * 字段都可能缺失（旧数据 / 加入时没有家庭名），渲染时要做兜底。
 */
export interface KnownUser {
  userId: string
  nickname: string
  role: 'parent' | 'child'
  avatarEmoji?: string
  familyName?: string
  /** 自托管后端模式下的登录密钥（与 userId 成对，跨设备迁移身份用）。本地模式不使用。 */
  loginKey?: string
}

/** 生成一个高熵登录密钥（32 字节十六进制）。 */
function newLoginKey(): string {
  const buf = new Uint8Array(32)
  crypto.getRandomValues(buf)
  return Array.from(buf)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

interface SessionState {
  /** 对应 auth.uid()。null = 还没有身份 */
  userId: string | null
  /** 家长 PIN 校验后拿到的短期令牌，30 分钟过期 */
  parentToken: string | null
  parentTokenExpiresAt: number | null
  /** 家长视角下正在查看哪个孩子；null = 看全家 */
  viewingMemberId: string | null
  /** 日历游标，'YYYY-MM-DD'。只存字符串，绝不存 Date */
  cursor: Ymd | null
  /** 本机已知身份列表（persist 落盘）。signOut 不会清空它 */
  knownUsers: KnownUser[]

  ensureUserId: () => string
  setUserId: (id: string | null) => void
  setParentToken: (token: string | null, expiresAt?: string | number | null) => void
  /** 令牌还有效吗。过期的直接当没有 */
  validParentToken: () => string | null
  setViewingMember: (id: string | null) => void
  setCursor: (d: Ymd | null) => void
  /** 记录一个已知身份：按 userId 去重，已存在则用新信息覆盖（昵称/头像等） */
  addKnownUser: (info: KnownUser) => void
  /** 从本机身份列表移除。只影响列表，不删数据库里的任何数据 */
  removeKnownUser: (userId: string) => void
  /**
   * 清空全部已知身份。只用于「清空所有数据」流程（数据库已 reset，旧身份
   * 指向空数据，留着只会误导）；「退出身份」不清 —— 那正是"一键恢复"的意义。
   */
  removeAllKnownUsers: () => void
  signOut: () => void
}

export const useSession = create<SessionState>()(
  persist(
    (set, get) => ({
      userId: null,
      parentToken: null,
      parentTokenExpiresAt: null,
      viewingMemberId: null,
      cursor: null,
      knownUsers: [],

      ensureUserId: () => {
        const cur = get().userId
        if (cur) return cur
        const id = newUserId()
        set({ userId: id })
        // 自托管后端：每个身份配一把登录密钥，随身份一起持久化，供跨设备迁移
        get().addKnownUser({ userId: id, nickname: '我', role: 'parent', loginKey: newLoginKey() })
        return id
      },

      setUserId: (id) => set({ userId: id }),

      setParentToken: (token, expiresAt) => {
        let ts: number | null = null
        if (typeof expiresAt === 'number') ts = expiresAt
        else if (typeof expiresAt === 'string') ts = new Date(expiresAt).getTime()
        else if (token) ts = Date.now() + 30 * 60 * 1000
        set({ parentToken: token, parentTokenExpiresAt: token ? ts : null })
      },

      validParentToken: () => {
        const { parentToken, parentTokenExpiresAt } = get()
        if (!parentToken) return null
        if (parentTokenExpiresAt && parentTokenExpiresAt < Date.now()) return null
        return parentToken
      },

      setViewingMember: (id) => set({ viewingMemberId: id }),
      setCursor: (d) => set({ cursor: d }),

      addKnownUser: (info) =>
        set((s) => {
          const idx = s.knownUsers.findIndex((k) => k.userId === info.userId)
          if (idx === -1) return { knownUsers: [...s.knownUsers, info] }
          // 已存在：只覆盖本次拿到的新字段，不动的字段（如旧家庭名）保留
          const next = s.knownUsers.slice()
          next[idx] = { ...next[idx], ...info }
          return { knownUsers: next }
        }),

      removeKnownUser: (userId) =>
        set((s) => ({ knownUsers: s.knownUsers.filter((k) => k.userId !== userId) })),

      removeAllKnownUsers: () => set({ knownUsers: [] }),

      signOut: () =>
        set({
          userId: null,
          parentToken: null,
          parentTokenExpiresAt: null,
          viewingMemberId: null,
          // 注意：knownUsers 不清空 —— 这是"退出后一键恢复"的核心
        }),
    }),
    {
      name: 'familyquest.session',
      // 令牌不落盘：刷新页面就得重新输 PIN。
      // 家长解锁后把手机递给孩子，孩子刷新一下就能改任务 —— 这种事必须防。
      partialize: (s) => ({
        userId: s.userId,
        viewingMemberId: s.viewingMemberId,
        knownUsers: s.knownUsers,
      }),
    },
  ),
)
