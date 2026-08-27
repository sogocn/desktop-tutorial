import { AlarmClock, ChevronLeft, ChevronRight } from 'lucide-react'
import { useMemo, useState } from 'react'
import { SigninCard } from '@/components/SigninCard'
import { TaskCard } from '@/components/TaskCard'
import { Empty, Spinner } from '@/components/ui'
import { useBootstrap, useCalendar, useMe, useViewingMember } from '@/hooks/useApp'
import { cn } from '@/lib/cn'
import { addDays, formatFull, relativeDay, type Ymd } from '@/lib/date'
import { useSession } from '@/store/session'
import type { CalendarEntry } from '@/types/db'

export default function TodayPage() {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const viewing = useViewingMember()
  const setViewingMember = useSession((s) => s.setViewingMember)

  const today = boot?.today ?? ''
  const [date, setDate] = useState<Ymd | null>(null)
  const cur = date ?? today

  // deadline 型任务要提前预告，所以往后多看 30 天
  const { data: entries, isLoading } = useCalendar(cur, addDays(cur, 30), viewing?.id ?? null)

  const todayList = useMemo(
    () => (entries ?? []).filter((e) => e.occurrence_date === cur && !e.is_deadline_style),
    [entries, cur],
  )

  // 顶部倒计时条：未来 30 天内没做完的 deadline 任务
  const deadlines = useMemo(
    () =>
      (entries ?? [])
        .filter((e) => e.is_deadline_style && e.status !== 'completed' && e.status !== 'skipped')
        .sort((a, b) => a.occurrence_date.localeCompare(b.occurrence_date))
        .slice(0, 3),
    [entries],
  )

  const doneCount = todayList.filter((e) => e.status === 'completed').length
  const children = boot?.members?.filter((m) => m.role === 'child') ?? []
  const isParent = me?.role === 'parent'

  return (
    <div className="mx-auto w-full max-w-md">
      {/* 头部 */}
      <div className="pt-safe sticky top-0 z-20 bg-slate-50/85 px-4 pb-2 backdrop-blur-lg">
        <div className="flex items-center justify-between pt-2">
          <div>
            <p className="text-xs font-medium text-slate-400">{relativeDay(cur, today)}</p>
            <h1 className="text-2xl font-bold tracking-tight text-slate-900">{formatFull(cur)}</h1>
          </div>
          <div className="flex items-center gap-1">
            <button
              onClick={() => setDate(addDays(cur, -1))}
              className="rounded-full p-2 text-slate-500 active:bg-slate-200"
            >
              <ChevronLeft size={20} />
            </button>
            {cur !== today && (
              <button
                onClick={() => setDate(null)}
                className="rounded-full bg-slate-900 px-2.5 py-1 text-xs font-medium text-white"
              >
                今天
              </button>
            )}
            <button
              onClick={() => setDate(addDays(cur, 1))}
              className="rounded-full p-2 text-slate-500 active:bg-slate-200"
            >
              <ChevronRight size={20} />
            </button>
          </div>
        </div>

        {/* 家长切孩子。只有一个孩子时不显示，省得多一行噪音 */}
        {isParent && children.length > 1 && (
          <div className="no-scrollbar -mx-4 mt-2 flex gap-2 overflow-x-auto px-4 pb-1">
            {children.map((c) => (
              <button
                key={c.id}
                onClick={() => setViewingMember(c.id)}
                className={cn(
                  'flex shrink-0 items-center gap-1.5 rounded-full py-1.5 pl-1.5 pr-3 text-sm font-medium transition',
                  viewing?.id === c.id ? 'bg-slate-900 text-white' : 'bg-white text-slate-600',
                )}
              >
                <span className="text-base">{c.avatar_emoji}</span>
                {c.nickname}
              </button>
            ))}
          </div>
        )}
      </div>

      <div className="space-y-4 px-4 pb-28 pt-1">
        {/* 进度条 */}
        {todayList.length > 0 && (
          <div className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200/60">
            <div className="flex items-baseline justify-between">
              <p className="text-sm text-slate-500">
                {viewing?.nickname} 今天的进度
              </p>
              <p className="text-sm font-semibold text-slate-900">
                {doneCount}
                <span className="text-slate-400"> / {todayList.length}</span>
              </p>
            </div>
            <div className="mt-2.5 h-2 overflow-hidden rounded-full bg-slate-100">
              <div
                className="h-full rounded-full bg-emerald-500 transition-all duration-500"
                style={{ width: `${(doneCount / todayList.length) * 100}%` }}
              />
            </div>
            {doneCount === todayList.length && (
              <p className="mt-2.5 text-sm font-medium text-emerald-600">
                🎊 今天全部做完了，厉害！
              </p>
            )}
          </div>
        )}

        {/* 今日签到。签到只对"今天"有意义，翻到别的日期就不显示 */}
        {cur === today && <SigninCard />}

        {/* deadline 倒计时 */}
        {deadlines.length > 0 && (
          <div className="space-y-2">
            <p className="px-1 text-xs font-medium text-slate-400">重要截止</p>
            {deadlines.map((d) => (
              <DeadlineBar key={`${d.task_id}-${d.occurrence_date}`} entry={d} today={today} />
            ))}
          </div>
        )}

        {/* 今天的任务 */}
        {isLoading ? (
          <Spinner label="加载中" />
        ) : todayList.length === 0 ? (
          <Empty
            emoji="🌤️"
            title={cur === today ? '今天没有安排' : '这天没有安排'}
            hint="点右下角的 + 添加一个"
          />
        ) : (
          <div className="space-y-2.5">
            {todayList.map((e) => (
              <TaskCard key={`${e.task_id}-${e.occurrence_date}`} entry={e} />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function DeadlineBar({ entry, today }: { entry: CalendarEntry; today: Ymd }) {
  const rel = relativeDay(entry.occurrence_date, today)
  const urgent = entry.occurrence_date <= addDays(today, 2)
  return (
    <div
      className={cn(
        'flex items-center gap-3 rounded-2xl px-4 py-3',
        urgent ? 'bg-rose-50 ring-1 ring-rose-200' : 'bg-white shadow-sm ring-1 ring-slate-200/60',
      )}
    >
      <AlarmClock size={18} className={urgent ? 'text-rose-500' : 'text-slate-400'} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium text-slate-900">
          {entry.icon_emoji} {entry.title}
        </p>
        <p className={cn('text-xs', urgent ? 'text-rose-600' : 'text-slate-400')}>
          {rel}截止 · +{entry.completion_points} 分
        </p>
      </div>
    </div>
  )
}
