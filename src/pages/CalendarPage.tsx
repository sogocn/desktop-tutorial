import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useMemo, useState } from 'react'
import { TaskCard } from '@/components/TaskCard'
import { colorOf, Empty, Spinner } from '@/components/ui'
import { useBootstrap, useMe, useMonthCalendar, useViewingMember } from '@/hooks/useApp'
import { cn } from '@/lib/cn'
import { addMonths, formatMd, formatMonth, monthOf, WEEKDAY_LABELS, type Ymd } from '@/lib/date'
import { useSession } from '@/store/session'
import type { CalendarEntry } from '@/types/db'

export default function CalendarPage() {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const viewing = useViewingMember()
  const setViewingMember = useSession((s) => s.setViewingMember)

  const today = boot?.today ?? ''
  const [anchor, setAnchor] = useState<Ymd | null>(null)
  const cur = anchor ?? today
  const [selected, setSelected] = useState<Ymd | null>(null)
  const sel = selected ?? today

  const { grid, byDate, isLoading } = useMonthCalendar(cur, viewing?.id ?? null)
  const curMonth = monthOf(cur)

  const selList = useMemo(() => byDate.get(sel) ?? [], [byDate, sel])
  const children = boot?.members?.filter((m) => m.role === 'child') ?? []
  const isParent = me?.role === 'parent'

  if (!today) return <Spinner />

  return (
    <div className="mx-auto w-full max-w-md">
      <div className="pt-safe sticky top-0 z-20 bg-slate-50/85 px-4 pb-2 backdrop-blur-lg">
        <div className="flex items-center justify-between pt-2">
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">{formatMonth(cur)}</h1>
          <div className="flex items-center gap-1">
            <button
              onClick={() => setAnchor(addMonths(cur, -1))}
              className="rounded-full p-2 text-slate-500 active:bg-slate-200"
            >
              <ChevronLeft size={20} />
            </button>
            {curMonth !== monthOf(today) && (
              <button
                onClick={() => {
                  setAnchor(null)
                  setSelected(null)
                }}
                className="rounded-full bg-slate-900 px-2.5 py-1 text-xs font-medium text-white"
              >
                本月
              </button>
            )}
            <button
              onClick={() => setAnchor(addMonths(cur, 1))}
              className="rounded-full p-2 text-slate-500 active:bg-slate-200"
            >
              <ChevronRight size={20} />
            </button>
          </div>
        </div>

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

      <div className="px-3 pb-28">
        {/* 星期表头 */}
        <div className="grid grid-cols-7 pb-1">
          {WEEKDAY_LABELS.map((w, i) => (
            <div
              key={w}
              className={cn(
                'py-1.5 text-center text-xs font-medium',
                i >= 5 ? 'text-rose-400' : 'text-slate-400',
              )}
            >
              {w}
            </div>
          ))}
        </div>

        {/* 网格 */}
        <div className="grid grid-cols-7 gap-y-0.5">
          {grid.days.map((d) => (
            <DayCell
              key={d}
              date={d}
              entries={byDate.get(d) ?? []}
              inMonth={monthOf(d) === curMonth}
              isToday={d === today}
              selected={d === sel}
              onSelect={() => setSelected(d)}
            />
          ))}
        </div>

        {/* 选中日详情 */}
        <div className="mt-4">
          <div className="mb-2 flex items-baseline justify-between px-1">
            <h2 className="font-semibold text-slate-900">
              {formatMd(sel)}
              {sel === today && <span className="ml-1.5 text-sm text-slate-400">今天</span>}
            </h2>
            {selList.length > 0 && (
              <span className="text-xs text-slate-400">
                {selList.filter((e) => e.status === 'completed').length}/{selList.length} 完成
              </span>
            )}
          </div>

          {isLoading ? (
            <Spinner />
          ) : selList.length === 0 ? (
            <Empty emoji="🍃" title="这天空着" />
          ) : (
            <div className="space-y-2.5">
              {selList.map((e) => (
                <TaskCard
                  key={`${e.task_id}-${e.occurrence_date}`}
                  entry={e}
                  // 未来的任务不给点完成 —— 今天点明天的卡就是刷分
                  editable={e.occurrence_date <= today}
                />
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function DayCell({
  date,
  entries,
  inMonth,
  isToday,
  selected,
  onSelect,
}: {
  date: Ymd
  entries: CalendarEntry[]
  inMonth: boolean
  isToday: boolean
  selected: boolean
  onSelect: () => void
}) {
  const day = Number(date.slice(8, 10))
  const total = entries.length
  const done = entries.filter((e) => e.status === 'completed').length
  const allDone = total > 0 && done === total

  return (
    <button
      onClick={onSelect}
      className={cn(
        'flex h-14 flex-col items-center justify-start gap-1 rounded-xl pt-1.5 transition',
        !inMonth && 'opacity-30',
        selected && 'bg-slate-900/5 ring-2 ring-slate-900',
      )}
    >
      <span
        className={cn(
          'flex size-6 items-center justify-center rounded-full text-[13px] font-medium',
          isToday ? 'bg-slate-900 font-bold text-white' : 'text-slate-700',
          allDone && !isToday && 'text-emerald-600',
        )}
      >
        {day}
      </span>

      {/* 圆点：最多 4 个，多了显示 +N。全做完就变一个对勾，视觉上"结清" */}
      <span className="flex h-2 items-center gap-[3px]">
        {allDone ? (
          <span className="text-[10px] leading-none text-emerald-500">✓</span>
        ) : (
          <>
            {entries.slice(0, 4).map((e) => (
              <span
                key={`${e.task_id}-${e.occurrence_date}`}
                className={cn(
                  'size-1.5 rounded-full',
                  e.status === 'completed' ? 'bg-emerald-400' : colorOf(e.color).dot,
                  e.status === 'skipped' && 'bg-slate-200',
                )}
              />
            ))}
            {total > 4 && <span className="text-[9px] leading-none text-slate-400">+</span>}
          </>
        )}
      </span>
    </button>
  )
}
