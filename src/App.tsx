import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { CalendarDays, Plus, Sun, User, Wallet } from 'lucide-react'
import { useEffect, useState } from 'react'
import { TaskFormSheet } from '@/components/TaskFormSheet'
import { Spinner } from '@/components/ui'
import { useBootstrap } from '@/hooks/useApp'
import * as api from '@/api'
import { cn } from '@/lib/cn'
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
        <p className="font-medium text-slate-900">启动失败</p>
        <p className="text-sm text-slate-500">{(error as Error)?.message}</p>
        <button
          onClick={() => location.reload()}
          className="mt-2 rounded-xl bg-slate-900 px-4 py-2 text-sm text-white"
        >
          重新加载
        </button>
      </div>
    )
  }

  if (!data?.in_family) return <Onboarding />

  return (
    <div className="min-h-dvh bg-slate-50">
      {tab === 'today' && <TodayPage />}
      {tab === 'calendar' && <CalendarPage />}
      {tab === 'wallet' && <WalletPage />}
      {tab === 'me' && <MePage />}

      {/* 悬浮 + 按钮：只在今天/日历页出现，钱包页放个加号没有意义 */}
      {(tab === 'today' || tab === 'calendar') && (
        <button
          onClick={() => setFormOpen(true)}
          className="fixed bottom-24 right-5 z-30 flex size-14 items-center justify-center rounded-full bg-slate-900 text-white shadow-lg shadow-slate-900/25 transition active:scale-90"
          aria-label="新建任务"
        >
          <Plus size={26} strokeWidth={2.5} />
        </button>
      )}

      {/* 底部导航 */}
      <nav className="pb-safe fixed inset-x-0 bottom-0 z-40 border-t border-slate-200/70 bg-white/90 backdrop-blur-lg">
        <div className="mx-auto flex max-w-md">
          {TABS.map(({ key, label, icon: Icon }) => (
            <button
              key={key}
              onClick={() => setTab(key)}
              className={cn(
                'flex flex-1 flex-col items-center gap-0.5 py-2 transition',
                tab === key ? 'text-slate-900' : 'text-slate-400',
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
