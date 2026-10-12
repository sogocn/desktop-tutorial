import { useState } from 'react'
import { Button, Sheet } from '@/components/ui'
import { useDeleteTask, useMe, useTaskActions } from '@/hooks/useApp'
import { getTask } from '@/api'
import { useQuery } from '@tanstack/react-query'
import { BackendError } from '@/lib/backend/types'
import { colorOf } from '@/components/ui'
import { formatFull } from '@/lib/date'
import type { CalendarEntry, Task } from '@/types/db'

/**
 * 任务详情 / 操作面板。
 * - 家长：编辑、删除本次（仅循环任务）、删除全部。
 * - 孩子：撤销（已完成时）、请假（未完成时，走审批——提交后等家长同意才生效）。
 * 删除"某一次"对循环任务 = 在 task_exclusions 里排除这一天；单次/到期任务的
 * "本次"即整条，会自动归并成"全部"删除。
 */
export function TaskDetailSheet({
  entry,
  onClose,
  onEdit,
}: {
  entry: CalendarEntry | null
  onClose: () => void
  onEdit: (task: Task) => void
}) {
  const me = useMe()
  const isParent = me?.role === 'parent'
  const del = useDeleteTask()
  const { uncomplete, requestSkip } = useTaskActions()
  const [err, setErr] = useState('')
  const [skipMsg, setSkipMsg] = useState('')

  const { data: task } = useQuery({
    queryKey: ['task', entry?.task_id],
    queryFn: () => getTask(entry!.task_id),
    enabled: !!entry,
  })

  if (!entry) return null

  const done = entry.status === 'completed'
  const skipped = entry.status === 'skipped'
  const isRecurring = entry.schedule_kind === 'recurring'
  const c = colorOf(entry.color)

  async function run(fn: () => Promise<unknown>) {
    setErr('')
    try {
      await fn()
      onClose()
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  // 孩子请假：提交申请（015 流程），不立即改变 occurrence，等家长审批
  async function onRequestSkip() {
    setErr('')
    setSkipMsg('')
    try {
      await requestSkip.mutateAsync({ taskId: entry!.task_id, date: entry!.occurrence_date })
      setSkipMsg('已提交请假申请，等家长同意后生效')
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <Sheet open={!!entry} onClose={onClose} title="任务详情">
      <div className="space-y-4">
        <div className="flex items-center gap-2">
          <span className="text-2xl">{entry.icon_emoji}</span>
          <div className="min-w-0">
            <p className="truncate text-lg font-semibold text-fg">{entry.title}</p>
            <p className="text-xs text-muted">
              {formatFull(entry.occurrence_date)} ·{' '}
              {isRecurring ? '循环任务' : entry.is_deadline_style ? '到期任务' : '单次任务'}
            </p>
          </div>
        </div>

        <div className="flex flex-wrap gap-2 text-xs">
          {entry.completion_points > 0 && (
            <span className={`rounded-md px-1.5 py-0.5 font-medium ${c.bg} ${c.text}`}>
              完成 +{entry.completion_points}
            </span>
          )}
          {entry.checkin_points > 0 && (
            <span className="rounded-md bg-amber-100 px-1.5 py-0.5 font-medium text-amber-700">
              打卡 +{entry.checkin_points}
            </span>
          )}
          <span className="rounded-md bg-surface2 px-1.5 py-0.5 text-muted">
            {done ? '已完成' : skipped ? '已请假' : '待完成'}
          </span>
        </div>

        {/* 家长：编辑 / 删除 */}
        {isParent && (
          <div className="space-y-2 border-t border-line pt-4">
            <Button
              variant="outline"
              className="w-full"
              onClick={() => task && onEdit(task)}
              disabled={!task}
            >
              编辑任务
            </Button>
            {isRecurring && (
              <Button
                variant="danger"
                className="w-full"
                onClick={() =>
                  run(() =>
                    del.mutateAsync({
                      taskId: entry.task_id,
                      scope: 'once',
                      date: entry.occurrence_date,
                    }),
                  )
                }
              >
                删除这一次（{formatFull(entry.occurrence_date)}）
              </Button>
            )}
            <Button
              variant="danger"
              className="w-full"
              onClick={() =>
                run(() => del.mutateAsync({ taskId: entry.task_id, scope: 'all' }))
              }
            >
              删除全部
            </Button>
          </div>
        )}

        {/* 任何人：撤销 / 请假 */}
          {!isParent && (
          <div className="space-y-2 border-t border-line pt-4">
            {done ? (
              <Button
                variant="outline"
                className="w-full"
                onClick={() =>
                  run(() => uncomplete.mutateAsync({ taskId: entry.task_id, date: entry.occurrence_date }))
                }
              >
                撤销完成
              </Button>
            ) : (
              !skipped && (
                <Button
                  variant="outline"
                  className="w-full"
                  disabled={!!skipMsg}
                  onClick={onRequestSkip}
                >
                  {skipMsg ? '已提交请假' : '今天请假'}
                </Button>
              )
            )}
            {skipMsg && (
              <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-700">{skipMsg}</p>
            )}
          </div>
        )}

        {err && (
          <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>
        )}

        <Button variant="ghost" className="w-full" onClick={onClose}>
          关闭
        </Button>
      </div>
    </Sheet>
  )
}
