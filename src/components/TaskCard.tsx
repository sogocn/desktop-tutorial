import { Check, Clock, Star } from 'lucide-react'
import { useState } from 'react'
import { colorOf } from '@/components/ui'
import { useTaskActions } from '@/hooks/useApp'
import { buzz, celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { formatTime } from '@/lib/date'
import type { CalendarEntry } from '@/types/db'

/**
 * 任务卡交互（落实 012 打卡 / 完成 逻辑梳理）：
 *
 *  - 单次任务（非到期）：主按钮="完成"。后端 complete_occurrence 会自动补一次打卡，
 *    所以"完成"本身就等于"完成+打卡"。已完成时圆圈变绿、不可再点，撤销走详情页。
 *
 *  - 循环任务（带打卡分）：主按钮="打卡"（当日默认动作，可提前打、可打满 daily_limit
 *    次）；右上方次级="完成 ▾"，展开「完成当日 / 完成全部」两个选项。
 *
 *  - 到期任务（is_deadline_style）：与循环任务同理——主按钮"打卡"，次级"完成 ▾"。
 *    走"完成"时后端会同时补一次打卡（完成+打卡一起发分）。
 *
 *  - 循环 / 到期任务（不带打卡分）：主按钮直接="完成当日"，次级"完成 ▾"仍可「完成全部」。
 *
 *  两套积分在卡片上并列展示：打卡分（琥珀色）+ 完成分（主题色），点明它们是两条独立账目。
 *
 *  非循环任务不再单独挂「✓已打卡」徽标：单次/到期任务点"完成"时后端已经顺带补了
 *  一次打卡，卡片右上角的绿色对勾圆圈就是完成态，再挂一个"已打卡"是同一件事说两遍。
 *  循环任务的"打卡 +N (a/b)"徽标保留——那是当日进度，与完成态不是一回事。
 *
 *  内联 menu 之外，请假 / 撤销 / 编辑 / 删除统一收进 TaskDetailSheet。
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
  const { checkin, complete, uncomplete, skip, completeAll } = useTaskActions()
  const [menuOpen, setMenuOpen] = useState(false)
  const c = colorOf(entry.color)

  const isRecurring = entry.schedule_kind === 'recurring'
  const isDeadline = entry.is_deadline_style
  const hasCheckin = entry.checkin_points > 0
  const done = entry.status === 'completed'
  const skipped = entry.status === 'skipped'
  const busy =
    complete.isPending || checkin.isPending || uncomplete.isPending || skip.isPending || completeAll.isPending

  // 循环任务当天已打卡达标（或整次已"完成"）
  const checkedInFull =
    done || (hasCheckin && entry.checkin_count >= entry.checkin_daily_limit && entry.checkin_daily_limit > 0)

  // 主按钮 = 打卡 的场景：循环任务 或 到期任务，且配了打卡分
  const primaryIsCheckin = hasCheckin && (isRecurring || isDeadline)
  // 还能继续打卡
  const canCheckinMore = editable && !busy && !done && !skipped && primaryIsCheckin && !checkedInFull

  const timeLabel = entry.window_start_time
    ? `${formatTime(entry.window_start_time)}${entry.window_end_time ? `–${formatTime(entry.window_end_time)}` : ''}`
    : entry.due_time
      ? `${formatTime(entry.due_time)} 前`
      : ''

  // 圆圈主操作：循环带打卡分 = 打卡；其余 = 完成当日
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

  // 完成当日：把今天这一次 occurrence 标完成（发完成分；once/到期同时补一次打卡）
  async function completeToday() {
    if (busy) return
    setMenuOpen(false)
    buzz()
    const r = await complete.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date })
    celebrate((r?.points_awarded ?? 0) >= 20 ? 'big' : 'small')
  }

  // 完成全部：今天及之后的所有安排一次性标记完成（只发一次完成分）
  async function completeAllDays() {
    setMenuOpen(false)
    if (
      !window.confirm(
        '将把该任务「今天及之后」的所有安排一次性标记为完成（只发一次完成分），确定？',
      )
    ) {
      return
    }
    buzz()
    const r = await completeAll.mutateAsync({ taskId: entry.task_id, uptoDate: null })
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
            {/* 两套积分并列展示，点明是独立账目 */}
            {entry.completion_points > 0 && (
              <span className={cn('rounded-md px-1.5 py-0.5 font-medium', c.bg, c.text)}>
                {hasCheckin ? `完成全部 +${entry.completion_points}` : `完成 +${entry.completion_points}`}
              </span>
            )}
            {hasCheckin && (
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

        {/* 循环 / 到期任务：次级"完成 ▾"菜单，含 完成当日 / 完成全部 */}
        {editable && (isRecurring || isDeadline) && !done && !skipped && (
          <div className="relative my-2 mr-2 flex shrink-0 items-center">
            <button
              onClick={() => setMenuOpen((o) => !o)}
              disabled={busy}
              className="flex items-center gap-0.5 rounded-xl bg-violet-100 px-3 text-sm font-medium text-violet-700 active:scale-95"
            >
              <Star size={14} strokeWidth={2.5} />
              完成 ▾
            </button>
            {menuOpen && (
              <>
                {/* 点击空白处关闭 */}
                <button
                  className="fixed inset-0 z-10 cursor-default"
                  aria-label="关闭菜单"
                  onClick={() => setMenuOpen(false)}
                />
                <div className="absolute right-0 z-20 mt-1 w-36 overflow-hidden rounded-xl border border-slate-200 bg-white shadow-lg">
                  <button
                    onClick={completeToday}
                    disabled={busy}
                    className="block w-full px-3 py-2 text-left text-sm text-slate-700 hover:bg-slate-50 active:bg-slate-100"
                  >
                    完成当日
                  </button>
                  <button
                    onClick={completeAllDays}
                    disabled={busy}
                    className="block w-full border-t border-slate-100 px-3 py-2 text-left text-sm text-violet-700 hover:bg-violet-50 active:bg-violet-100"
                  >
                    完成全部
                  </button>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
