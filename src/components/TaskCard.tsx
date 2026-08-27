import { Check, Clock, Plus, RotateCcw, SkipForward } from 'lucide-react'
import { useState } from 'react'
import { colorOf } from '@/components/ui'
import { useTaskActions } from '@/hooks/useApp'
import { buzz, celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { formatTime } from '@/lib/date'
import type { CalendarEntry } from '@/types/db'

/**
 * 任务卡是整个应用被点得最多的东西，交互只讲三件事：
 * 1. 一眼看出做没做（左侧勾选圈）
 * 2. 一下点得到（整卡可点，不做小图标热区）
 * 3. 点错能退（长按或右滑出撤销）
 */
export function TaskCard({
  entry,
  editable = true,
  onOpen,
}: {
  entry: CalendarEntry
  editable?: boolean
  onOpen?: (e: CalendarEntry) => void
}) {
  const { checkin, complete, uncomplete, skip } = useTaskActions()
  const [menu, setMenu] = useState(false)
  const c = colorOf(entry.color)

  const done = entry.status === 'completed'
  const skipped = entry.status === 'skipped'
  const busy = complete.isPending || checkin.isPending || uncomplete.isPending || skip.isPending
  const canCheckin = entry.checkin_points > 0 && entry.checkin_count < entry.checkin_daily_limit

  const timeLabel = entry.window_start_time
    ? `${formatTime(entry.window_start_time)}${entry.window_end_time ? `–${formatTime(entry.window_end_time)}` : ''}`
    : entry.due_time
      ? `${formatTime(entry.due_time)} 前`
      : ''

  async function toggle() {
    if (!editable || busy) return
    buzz()
    if (done) {
      await uncomplete.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
    } else {
      const r = await complete.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
      // 被日上限截断时不撒花 —— 假装很开心是欺骗
      celebrate((r?.points_awarded ?? 0) >= 20 ? 'big' : 'small')
    }
  }

  return (
    <div
      className={cn(
        'relative rounded-2xl border bg-white transition',
        done ? 'border-slate-100 opacity-60' : 'border-slate-200/80 shadow-sm',
        skipped && 'opacity-45',
        entry.archived && 'border-dashed',
      )}
    >
      <div className="flex items-stretch">
        {/* 勾选区：大热区，孩子的手指没那么准 */}
        <button
          onClick={toggle}
          disabled={!editable || busy || skipped}
          className="flex shrink-0 items-center justify-center py-4 pl-4 pr-3 disabled:opacity-100"
          aria-label={done ? '取消完成' : '标记完成'}
        >
          <span
            className={cn(
              'flex size-7 items-center justify-center rounded-full border-2 transition',
              done ? 'border-emerald-500 bg-emerald-500 text-white' : 'border-slate-300',
              !done && !skipped && editable && 'active:scale-90',
            )}
          >
            {done && <Check size={16} strokeWidth={3} />}
            {skipped && <SkipForward size={13} className="text-slate-400" />}
          </span>
        </button>

        {/* 正文 */}
        <button
          className="min-w-0 flex-1 py-3.5 pr-3 text-left"
          onClick={() => (onOpen ? onOpen(entry) : setMenu((v) => !v))}
        >
          <div className="flex items-center gap-1.5">
            <span className="text-base">{entry.icon_emoji}</span>
            <span
              className={cn(
                'truncate font-medium text-slate-900',
                done && 'text-slate-400 line-through',
              )}
            >
              {entry.title}
            </span>
          </div>

          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
            {timeLabel && (
              <span className="inline-flex items-center gap-0.5 text-slate-400">
                <Clock size={11} />
                {timeLabel}
              </span>
            )}
            {entry.completion_points > 0 && (
              <span className={cn('rounded-md px-1.5 py-0.5 font-medium', c.bg, c.text)}>
                完成 +{entry.completion_points}
              </span>
            )}
            {entry.checkin_points > 0 && (
              <span className="rounded-md bg-amber-100 px-1.5 py-0.5 font-medium text-amber-700">
                打卡 +{entry.checkin_points}
                {entry.checkin_daily_limit > 1 &&
                  ` (${entry.checkin_count}/${entry.checkin_daily_limit})`}
              </span>
            )}
            {skipped && <span className="text-slate-400">已请假</span>}
            {entry.archived && <span className="text-slate-400">已停用</span>}
          </div>
        </button>

        {/* 打卡按钮：只有配了打卡分的任务才出现 */}
        {editable && canCheckin && !done && !skipped && (
          <button
            onClick={async () => {
              buzz()
              await checkin.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
              celebrate('small')
            }}
            disabled={busy}
            className="my-2 mr-2 flex shrink-0 items-center gap-0.5 rounded-xl bg-amber-100 px-3 text-sm font-medium text-amber-700 active:scale-95"
          >
            <Plus size={14} strokeWidth={2.5} />
            打卡
          </button>
        )}
      </div>

      {/* 展开的次要操作。默认收起，不让"请假"和"完成"一样显眼 */}
      {menu && editable && !onOpen && (
        <div className="flex gap-2 border-t border-slate-100 px-4 py-2.5">
          {!skipped && !done && (
            <button
              onClick={async () => {
                await skip.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
                setMenu(false)
              }}
              className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-sm text-slate-500 hover:bg-slate-100"
            >
              <SkipForward size={14} />
              今天请假
            </button>
          )}
          {(done || skipped) && (
            <button
              onClick={async () => {
                await uncomplete.mutateAsync({
                  taskId: entry.task_id,
                  date: entry.occurrence_date,
                })
                setMenu(false)
              }}
              className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-sm text-slate-500 hover:bg-slate-100"
            >
              <RotateCcw size={14} />
              撤销
            </button>
          )}
        </div>
      )}
    </div>
  )
}
