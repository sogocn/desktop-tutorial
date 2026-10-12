import { AlarmClock, ChevronLeft, ChevronRight } from 'lucide-react'
import { useMemo, useState } from 'react'
import { ChallengeCard } from '@/components/ChallengeCard'
import { SigninCard } from '@/components/SigninCard'
import { TaskCard } from '@/components/TaskCard'
import { TaskDetailSheet } from '@/components/TaskDetailSheet'
import { TaskFormSheet } from '@/components/TaskFormSheet'
import { Empty, Spinner } from '@/components/ui'
import { useBootstrap, useCalendar, useCurrentSkin, useMe, useViewingMember } from '@/hooks/useApp'
import { cn } from '@/lib/cn'
import { addDays, formatFull, relativeDay, type Ymd } from '@/lib/date'
import { useSession } from '@/store/session'
import type { CalendarEntry, Task } from '@/types/db'

export default function TodayPage() {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const viewing = useViewingMember()
  const setViewingMember = useSession((s) => s.setViewingMember)
  // 当前皮肤：首页头图用（和日历页同一张图）
  const skin = useCurrentSkin()

  const today = boot?.today ?? ''
  const [date, setDate] = useState<Ymd | null>(null)
  const cur = date ?? today
  const [detail, setDetail] = useState<CalendarEntry | null>(null)
  const [editing, setEditing] = useState<Task | null>(null)

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
      <div className="pt-safe sticky top-0 z-20 bg-app/85 px-4 pb-2 backdrop-blur-lg">
        <div className="flex items-center justify-between pt-2">
          <div>
            <p className="text-xs font-medium text-muted">{relativeDay(cur, today)}</p>
            <h1 className="text-2xl font-bold tracking-tight text-fg">{formatFull(cur)}</h1>
          </div>
          <div className="flex items-center gap-1">
            <button
              onClick={() => setDate(addDays(cur, -1))}
              className="rounded-full p-2 text-muted active:bg-surface2"
            >
              <ChevronLeft size={20} />
            </button>
            {cur !== today && (
              <button
                onClick={() => setDate(null)}
                className="rounded-full bg-primary px-2.5 py-1 text-xs font-medium text-white"
              >
                今天
              </button>
            )}
            <button
              onClick={() => setDate(addDays(cur, 1))}
              className="rounded-full p-2 text-muted active:bg-surface2"
            >
              <ChevronRight size={20} />
            </button>
          </div>
        </div>

        {/* 家长切换查看谁的日程。默认看第一个孩子；也可以切回自己看自己的安排 */}
        {isParent && me && children.length > 0 && (
          <div className="no-scrollbar -mx-4 mt-2 flex gap-2 overflow-x-auto px-4 pb-1">
            {children.map((c) => (
              <button
                key={c.id}
                onClick={() => setViewingMember(c.id)}
                className={cn(
                  'flex shrink-0 items-center gap-1.5 rounded-full py-1.5 pl-1.5 pr-3 text-sm font-medium transition',
                  viewing?.id === c.id ? 'bg-primary text-white' : 'bg-surface text-muted',
                )}
              >
                <span className="text-base">{c.avatar_emoji}</span>
                {c.nickname}
              </button>
            ))}
            <button
              onClick={() => setViewingMember(me.id)}
              className={cn(
                'flex shrink-0 items-center gap-1.5 rounded-full py-1.5 pl-1.5 pr-3 text-sm font-medium transition',
                viewing?.id === me.id ? 'bg-primary text-white' : 'bg-surface text-muted',
              )}
            >
              <span className="text-base">{me.avatar_emoji}</span>
              {me.nickname}（我）
            </button>
          </div>
        )}
      </div>

      <div className="space-y-4 px-4 pb-28 pt-1">
        {/* 皮肤头图：3:1 宽幅横幅，<img> 按原比例整张渲染，不裁切（和日历页同一张） */}
        {skin?.theme.banner && (
          <img
            src={skin.theme.banner}
            alt=""
            className="block w-full rounded-2xl ring-1 ring-line"
          />
        )}

        {/* 进度条 */}
        {todayList.length > 0 && (
          <div className="rounded-2xl bg-surface p-4 shadow-sm ring-1 ring-slate-200/60">
            <div className="flex items-baseline justify-between">
              <p className="text-sm text-muted">
                {viewing?.nickname} 今天的进度
              </p>
              <p className="text-sm font-semibold text-fg">
                {doneCount}
                <span className="text-muted"> / {todayList.length}</span>
              </p>
            </div>
            <div className="mt-2.5 h-2 overflow-hidden rounded-full bg-surface2">
              {/* 进度条用皮肤强调色，而不是写死的绿色 */}
              <div
                className="h-full rounded-full bg-accent transition-all duration-500"
                style={{ width: `${(doneCount / todayList.length) * 100}%` }}
              />
            </div>
            {doneCount === todayList.length && (
              <p className="mt-2.5 text-sm font-medium text-primary">
                🎊 今天全部做完了，厉害！
              </p>
            )}
          </div>
        )}

        {/* 今日签到。签到只对"今天"有意义，翻到别的日期就不显示 */}
        {cur === today && <SigninCard />}

        {/* 满星挑战（016）。和签到卡一样只对"今天"有意义；组件内部再按角色判孩子 */}
        {cur === today && <ChallengeCard />}

        {/* deadline 倒计时 */}
        {deadlines.length > 0 && (
          <div className="space-y-2">
            <p className="px-1 text-xs font-medium text-muted">重要截止</p>
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
              <TaskCard key={`${e.task_id}-${e.occurrence_date}`} entry={e} onOpen={setDetail} />
            ))}
          </div>
        )}
      </div>

      <TaskDetailSheet
        entry={detail}
        onClose={() => setDetail(null)}
        onEdit={(t) => {
          setDetail(null)
          setEditing(t)
        }}
      />
      <TaskFormSheet open={!!editing} onClose={() => setEditing(null)} task={editing} />
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
        urgent ? 'bg-rose-50 ring-1 ring-rose-200' : 'bg-surface shadow-sm ring-1 ring-slate-200/60',
      )}
    >
      <AlarmClock size={18} className={urgent ? 'text-rose-500' : 'text-muted'} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium text-fg">
          {entry.icon_emoji} {entry.title}
        </p>
        <p className={cn('text-xs', urgent ? 'text-rose-600' : 'text-muted')}>
          {rel}截止 · +{entry.completion_points} 分
        </p>
      </div>
    </div>
  )
}
