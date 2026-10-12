import { QueryClient, QueryClientProvider, useQueryClient } from '@tanstack/react-query'
import { CalendarDays, Plus, Sun, User, Wallet } from 'lucide-react'
import { useEffect, useState } from 'react'
import { SkinBackdrop } from '@/components/SkinBackdrop'
import { TaskFormSheet } from '@/components/TaskFormSheet'
import { Spinner } from '@/components/ui'
import { useBootstrap, useMe, useSkins } from '@/hooks/useApp'
import * as api from '@/api'
import { cn } from '@/lib/cn'
import { applyTheme } from '@/lib/theme'
import CalendarPage from '@/pages/CalendarPage'
import MePage from '@/pages/MePage'
import Onboarding from '@/pages/Onboarding'
import TodayPage from '@/pages/TodayPage'
import WalletPage from '@/pages/WalletPage'
import { useSession } from '@/store/session'

const qc = new QueryClient({
  defaultOptions: {
    queries: {
      // 本地 PGlite 查询是毫秒级的，重试没有意义，失败就是真失败
      retry: false,
      refetchOnWindowFocus: false,
    },
  },
})

type Tab = 'today' | 'calendar' | 'wallet' | 'me'

const TABS: { key: Tab; label: string; icon: typeof Sun }[] = [
  { key: 'today', label: '今天', icon: Sun },
  { key: 'calendar', label: '日历', icon: CalendarDays },
  { key: 'wallet', label: '钱包', icon: Wallet },
  { key: 'me', label: '我的', icon: User },
]

export default function App() {
  return (
    <QueryClientProvider client={qc}>
      {/* 全屏皮肤背景：登录页和主界面共用同一层，别再让主壳的不透明底色把它盖掉 */}
      <SkinBackdrop />
      <Boot />
    </QueryClientProvider>
  )
}

/**
 * 启动顺序不能乱：
 * 先把本地身份塞进数据库连接（决定 RLS 看到什么），再查 bootstrap_state。
 * 反过来的话第一次查询会以"游客"身份跑，永远返回 in_family=false。
 */
function Boot() {
  const [identityReady, setIdentityReady] = useState(false)
  const userId = useSession((s) => s.userId)

  useEffect(() => {
    let cancelled = false
    api.setIdentity(userId)
      .then(() => {
        if (!cancelled) setIdentityReady(true)
      })
      // 网络抖动/服务端瞬时不可用时也要放行：卡在这里等于永远停在启动画面。
      // 放行后由 bootstrap 查询自己暴露错误（Shell 有「启动失败 + 重新加载」兜底）。
      .catch(() => {
        if (!cancelled) setIdentityReady(true)
      })
    return () => {
      cancelled = true
    }
  }, [userId])

  if (!identityReady) return <BootSplash />
  return <Shell />
}

function BootSplash() {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center gap-4">
      <div className="animate-pop-in text-6xl">🏡</div>
      <Spinner label="正在连接服务器" />
    </div>
  )
}

/**
 * 全局主题应用。读「当前登录成员」所选皮肤（list_skins 里 current=true 的那条），
 * 把它的配色写到 document 根节点，整页背景/按钮/卡片随皮肤切换。
 * 皮肤列表没回来前 applyTheme(null) 走默认主题，不会闪。
 */
function ThemeApplier({ memberId }: { memberId: string }) {
  const qc = useQueryClient()
  const { data: skins } = useSkins(memberId)
  const me = useMe()

  useEffect(() => {
    const current = skins?.find((s) => s.current)
    applyTheme(current?.theme)
  }, [skins])

  // 试用皮肤到期自动回退：后端没有定时任务，判断靠 trial_until > now()，
  // 但页面一直开着的话没人去重新取数据，主题会卡在过期的试用皮肤上。
  // 这里按到期时间挂一个定时器，到点了就重新拉列表，主题自然回落。
  const trialUntil = me?.trial_until ?? null
  useEffect(() => {
    if (!trialUntil) return
    const at = new Date(trialUntil).getTime()
    if (!Number.isFinite(at)) return
    const delay = Math.max(at - Date.now(), 0)
    const t = setTimeout(() => {
      qc.invalidateQueries({ queryKey: ['skins'] })
      qc.invalidateQueries({ queryKey: ['bootstrap'] })
    }, delay + 1000)
    return () => clearTimeout(t)
  }, [trialUntil, qc])

  return null
}

function Shell() {
  const { data, isLoading, isError, error } = useBootstrap()
  const userId = useSession((s) => s.userId)
  const addKnownUser = useSession((s) => s.addKnownUser)
  const [tab, setTab] = useState<Tab>('today')
  const [formOpen, setFormOpen] = useState(false)

  // 兜底：只要进了主壳，就把当前身份记进「本机身份」列表。
  // 老用户升级后第一次进来会被记录；加入家庭时昵称留空的占位名也会在这里被纠正成真实昵称。
  useEffect(() => {
    if (!data?.in_family || !data.me_id || !userId) return
    const me = data.members?.find((m) => m.id === data.me_id)
    if (!me) return
    addKnownUser({
      userId,
      nickname: me.nickname,
      role: me.role,
      avatarEmoji: me.avatar_emoji,
      familyName: data.family?.name,
    })
  }, [data?.in_family, data?.me_id, data?.family?.name, userId, addKnownUser])

  if (isLoading) return <BootSplash />

  if (isError) {
    return (
      <div className="flex min-h-dvh flex-col items-center justify-center gap-3 px-8 text-center">
        <div className="text-5xl">😵</div>
        <p className="font-medium text-fg">启动失败</p>
        <p className="text-sm text-muted">{(error as Error)?.message}</p>
        <button
          onClick={() => location.reload()}
          className="mt-2 rounded-xl bg-primary px-4 py-2 text-sm text-on-primary"
        >
          重新加载
        </button>
      </div>
    )
  }

  if (!data?.in_family) return <Onboarding />

  return (
    // 这里【不要】加 bg-app：那是一层不透明底色，会把 SkinBackdrop 的皮肤大图整个盖死。
    // 页面底色由 <SkinBackdrop /> 统一负责，卡片/列表自己带 bg-surface，可读性不受影响。
    <div className="min-h-dvh">
      {/* 全局主题：把当前成员所选皮肤的配色套到根节点 CSS 变量上 */}
      <ThemeApplier memberId={data.me_id!} />

      {tab === 'today' && <TodayPage />}
      {tab === 'calendar' && <CalendarPage />}
      {tab === 'wallet' && <WalletPage />}
      {tab === 'me' && <MePage />}

      {/* 悬浮 + 按钮：只在今天/日历页出现，钱包页放个加号没有意义 */}
      {(tab === 'today' || tab === 'calendar') && (
        <button
          onClick={() => setFormOpen(true)}
          className="fixed bottom-24 right-5 z-30 flex size-14 items-center justify-center rounded-full bg-primary text-on-primary shadow-lg shadow-primary/25 transition active:scale-90"
          aria-label="新建任务"
        >
          <Plus size={26} strokeWidth={2.5} />
        </button>
      )}

      {/* 底部导航 */}
      <nav className="pb-safe fixed inset-x-0 bottom-0 z-40 border-t border-line bg-nav backdrop-blur-lg">
        <div className="mx-auto flex max-w-md">
          {TABS.map(({ key, label, icon: Icon }) => (
            <button
              key={key}
              onClick={() => setTab(key)}
              className={cn(
                'flex flex-1 flex-col items-center gap-0.5 py-2 transition',
                tab === key ? 'text-fg' : 'text-muted',
              )}
            >
              <Icon size={22} strokeWidth={tab === key ? 2.4 : 1.9} />
              <span className="text-[11px] font-medium">{label}</span>
            </button>
          ))}
        </div>
      </nav>

      <TaskFormSheet open={formOpen} onClose={() => setFormOpen(false)} />
    </div>
  )
}
