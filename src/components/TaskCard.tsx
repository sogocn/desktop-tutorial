import { Check, Clock, Star } from 'lucide-react'
import { colorOf } from '@/components/ui'
import { useTaskActions } from '@/hooks/useApp'
import { buzz, celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { formatTime } from '@/lib/date'
import type { CalendarEntry } from '@/types/db'

/**
 * 任务卡交互（落实需求3"循环 / 到期任务当日默认打卡"语义）：
 *
 *  - 单次任务（非到期）：主按钮="完成"。后端 complete_occurrence 会自动补一次打卡，
 *    所以"完成"本身就等于"完成+打卡"。已完成时圆圈变绿、不可再点，撤销走详情页。
 *
 *  - 循环任务（带打卡分）：主按钮="打卡"（当日默认动作，可提前打、可打满 daily_limit
 *    次）；右上方次级="完成(提前)"，把当天这一次的 occurrence 直接标完成。
 *    循环任务不自动打卡，所以"完成"与"打卡"是两个独立动作。
 *
 *  - 到期任务（带打卡分，is_deadline_style=true）：主按钮同样="打卡"（当日默认动作），
 *    右上方次级="完成(提前)"。最后一次/提前完成走 complete_occurrence，后端会同时补一次
 *    打卡（完成+打卡一起发分）。
 *
 *  - 循环 / 到期任务（不带打卡分）：没有打卡概念，主按钮直接="完成"。
 *
 *  内联 menu 已移除，请假 / 撤销 / 编辑 / 删除统一收进 TaskDetailSheet。
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
  const c = colorOf(entry.color)

  const isRecurring = entry.schedule_kind === 'recurring'
  const isDeadline = entry.is_deadline_style
  const hasCheckin = entry.checkin_points > 0
  const done = entry.status === 'completed'
  const skipped = entry.status === 'skipped'
  const busy =
    complete.isPending || checkin.isPending || uncomplete.isPending || skip.isPending

  // 循环任务当天已打卡达标（或整次已"完成"）
  const checkedInFull =
    done || (hasCheckin && entry.checkin_count >= entry.checkin_daily_limit && entry.checkin_daily_limit > 0)

  // 主按钮 = 打卡 的场景：循环任务 或 到期任务，且配了打卡分
  // （需求3：循环 / 到期任务当日默认是实现打卡；单次任务则"完成"本身即完成+打卡）
  const primaryIsCheckin = hasCheckin && (isRecurring || isDeadline)
  // 还能继续打卡
  const canCheckinMore = editable && !busy && !done && !skipped && primaryIsCheckin && !checkedInFull

  const timeLabel = entry.window_start_time
    ? `${formatTime(entry.window_start_time)}${entry.window_end_time ? `–${formatTime(entry.window_end_time)}` : ''}`
    : entry.due_time
      ? `${formatTime(entry.due_time)} 前`
      : ''

  // 圆圈主操作：循环带打卡分 = 打卡；其余 = 完成
  async function primaryAction() {
    if (!editable || busy || done || skipped) return
    buzz()
    if (primaryIsCheckin) {
      await checkin.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
      celebrate('small')
    } else {
      const r = await complete.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
      // 被日上限截断时不撒花 —— 假装很开心是欺骗
      celebrate((r?.points_awarded ?? 0) >= 20 ? 'big' : 'small')
    }
  }

  // 循环任务的"完成(提前)"
  async function completeAhead() {
    if (!editable || busy || done || skipped) return
    buzz()
    const r = await complete.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
    celebrate((r?.points_awarded ?? 0) >= 20 ? 'big' : 'small')
  }

  // 已完成 / 已请假 时，圆圈点开详情走撤销
  function onCircleClick() {
    if (done || skipped) {
      onOpen?.(entry)
      return
    }
    void primaryAction()
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
        {/* 主操作圈：大热区，孩子的手指没那么准 */}
        <button
          onClick={onCircleClick}
          disabled={!editable || busy || (primaryIsCheckin && !done && !skipped && !canCheckinMore)}
          className="flex shrink-0 items-center justify-center py-4 pl-4 pr-3 disabled:opacity-100"
          aria-label={
            done || skipped
              ? '查看详情'
              : primaryIsCheckin
                ? '打卡'
                : '标记完成'
          }
        >
          <span
            className={cn(
              'flex size-7 items-center justify-center rounded-full border-2 transition',
              (done || checkedInFull) ? 'border-emerald-500 bg-emerald-500 text-white' : 'border-slate-300',
              !done && !skipped && editable && 'active:scale-90',
            )}
          >
            {done && <Check size={16} strokeWidth={3} />}
            {skipped && <Clock size={13} className="text-slate-400" />}
            {!done && !skipped && checkedInFull && <Check size={16} strokeWidth={3} className="text-white" />}
          </span>
        </button>

        {/* 正文：点开详情 */}
        <button
          className="min-w-0 flex-1 py-3.5 pr-3 text-left"
          onClick={() => onOpen?.(entry)}
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
            {hasCheckin && (
              <span className="rounded-md bg-amber-100 px-1.5 py-0.5 font-medium text-amber-700">
                打卡 +{entry.checkin_points}
                {entry.checkin_daily_limit > 1 &&
                  ` (${entry.checkin_count}/${entry.checkin_daily_limit})`}
              </span>
            )}
            {!isRecurring && entry.checkin_count > 0 && (
              <span className="inline-flex items-center gap-0.5 rounded-md bg-emerald-100 px-1.5 py-0.5 font-medium text-emerald-700">
                <Check size={11} strokeWidth={3} />已打卡
              </span>
            )}
            {skipped && <span className="text-slate-400">已请假</span>}
            {entry.archived && <span className="text-slate-400">已停用</span>}
          </div>
        </button>

        {/* 循环任务（带打卡分）的"完成(提前)"次级按钮；无打卡分时主按钮就是完成 */}
        {editable && primaryIsCheckin && !done && !skipped && (
          <button
            onClick={completeAhead}
            disabled={busy}
            className="my-2 mr-2 flex shrink-0 items-center gap-0.5 rounded-xl bg-violet-100 px-3 text-sm font-medium text-violet-700 active:scale-95"
          >
            <Star size={14} strokeWidth={2.5} />
            完成
          </button>
        )}
      </div>
    </div>
  )
}
