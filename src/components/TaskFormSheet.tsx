import { useEffect, useState } from 'react'
import {
  defaultSchedule,
  RecurrencePicker,
  taskToSchedule,
  toRecurrence,
  type ScheduleValue,
} from '@/components/RecurrencePicker'
import { Button, Chip, Field, Input, Sheet, TASK_COLORS } from '@/components/ui'
import { useBootstrap, useCreateTask, useMe, useUpdateTask } from '@/hooks/useApp'
import { BackendError } from '@/lib/backend/types'
import { celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import type { Task, TaskColor } from '@/types/db'

const ICONS = ['⭐', '📚', '🎹', '🏃', '🧹', '🦷', '🛏️', '🥦', '🐶', '🎨', '🧮', '💧']

export function TaskFormSheet({
  open,
  onClose,
  task,
}: {
  open: boolean
  onClose: () => void
  /** 传入即有任务 = 编辑模式；不传 = 新建 */
  task?: Task | null
}) {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const createTask = useCreateTask()
  const updateTask = useUpdateTask()
  const today = boot?.today ?? ''

  const isParent = me?.role === 'parent'
  const editing = !!task
  const cap = boot?.family?.child_task_points_cap ?? 5

  const [title, setTitle] = useState('')
  const [icon, setIcon] = useState('⭐')
  const [color, setColor] = useState<TaskColor>('sky')
  const [assignees, setAssignees] = useState<string[]>([])
  const [sched, setSched] = useState<ScheduleValue>(() => defaultSchedule(today))
  const [completionPoints, setCompletionPoints] = useState(isParent ? 5 : 1)
  const [checkinPoints, setCheckinPoints] = useState(0)
  const [checkinLimit, setCheckinLimit] = useState(1)
  const [windowStart, setWindowStart] = useState('')
  const [windowEnd, setWindowEnd] = useState('')
  const [err, setErr] = useState('')

  const members = boot?.members ?? []

  // 打开时根据「新建 / 编辑」预填
  useEffect(() => {
    if (!open) return
    if (task) {
      setTitle(task.title)
      setIcon(task.icon_emoji)
      setColor(task.color)
      setSched(taskToSchedule(task))
      setCompletionPoints(task.completion_points)
      setCheckinPoints(task.checkin_points)
      setCheckinLimit(task.checkin_daily_limit)
      setWindowStart(task.window_start_time ?? '')
      setWindowEnd(task.due_time ?? task.window_end_time ?? '')
      setAssignees([task.assignee_id])
    } else {
      setTitle('')
      setIcon('⭐')
      setColor('sky')
      setAssignees([])
      setSched(defaultSchedule(today))
      setCompletionPoints(isParent ? 5 : 1)
      setCheckinPoints(0)
      setCheckinLimit(1)
      setWindowStart('')
      setWindowEnd('')
    }
    setErr('')
  }, [open, task, today, isParent])

  const pending = createTask.isPending || updateTask.isPending
  const total = completionPoints + checkinPoints
  const overCap = !isParent && total > cap
  // 家长新建必须至少选一个孩子
  const needAssignee = isParent && !editing
  const canSave = !!title.trim() && !overCap && !pending && (!needAssignee || assignees.length > 0)

  function toggleAssignee(id: string) {
    setAssignees((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]))
  }

  async function submit() {
    if (!canSave || !title.trim()) return
    setErr('')
    const r = toRecurrence(sched)
    try {
      if (editing && task) {
        await updateTask.mutateAsync({
          taskId: task.id,
          title: title.trim(),
          iconEmoji: icon,
          color,
          scheduleKind: r.scheduleKind,
          recurrence: r.recurrence,
          startsOn: r.startsOn,
          endsOn: sched.endsOn,
          isDeadline: r.isDeadline,
          windowStart: windowStart || null,
          windowEnd: windowEnd || null,
          dueTime: sched.mode === 'deadline' ? windowEnd || null : null,
          checkinPoints,
          checkinLimit,
          completionPoints,
        })
      } else {
        const ids = isParent ? assignees : [me!.id]
        if (ids.length === 0) {
          setErr('请至少选一个孩子')
          return
        }
        await createTask.mutateAsync({
          assigneeIds: ids,
          title: title.trim(),
          iconEmoji: icon,
          color,
          scheduleKind: r.scheduleKind,
          recurrence: r.recurrence,
          startsOn: r.startsOn,
          endsOn: sched.endsOn,
          isDeadline: r.isDeadline,
          windowStart: windowStart || null,
          windowEnd: windowEnd || null,
          dueTime: sched.mode === 'deadline' ? windowEnd || null : null,
          checkinPoints,
          checkinLimit,
          completionPoints,
        })
      }
      celebrate('small')
      onClose()
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <Sheet
      open={open}
      onClose={onClose}
      title={editing ? '编辑任务' : '新建任务'}
      footer={
        <Button
          size="lg"
          className="mb-1 w-full"
          disabled={!canSave}
          onClick={submit}
        >
          {pending ? '保存中…' : editing ? '保存修改' : '保存'}
        </Button>
      }
    >
      <div className="space-y-5">
        <Field label="要做什么">
          <Input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="比如：练琴 30 分钟"
            maxLength={60}
            autoFocus
          />
        </Field>

        {/* 图标 + 颜色 */}
        <div>
          <p className="mb-1.5 text-sm font-medium text-slate-700">图标</p>
          <div className="grid grid-cols-6 gap-2">
            {ICONS.map((i) => (
              <button
                key={i}
                type="button"
                onClick={() => setIcon(i)}
                className={cn(
                  'flex aspect-square items-center justify-center rounded-xl text-xl transition active:scale-95',
                  icon === i ? 'bg-slate-900' : 'bg-slate-100',
                )}
              >
                {i}
              </button>
            ))}
          </div>
        </div>

        <div>
          <p className="mb-1.5 text-sm font-medium text-slate-700">颜色</p>
          <div className="flex gap-2.5">
            {(Object.keys(TASK_COLORS) as TaskColor[]).map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => setColor(c)}
                className={cn(
                  'size-9 rounded-full transition active:scale-90',
                  TASK_COLORS[c].dot,
                  color === c && 'ring-2 ring-slate-900 ring-offset-2',
                )}
              />
            ))}
          </div>
        </div>

        {/* 派给谁：仅家长新建时可多选（编辑不改指派人） */}
        {isParent && !editing && (
          <div>
            <p className="mb-1.5 text-sm font-medium text-slate-700">派给谁（可多选）</p>
            <div className="flex flex-wrap gap-2">
              {members.map((m) => (
                <Chip
                  key={m.id}
                  active={assignees.includes(m.id)}
                  onClick={() => toggleAssignee(m.id)}
                  className="flex items-center gap-1.5"
                >
                  <span className="text-base">{m.avatar_emoji}</span>
                  {m.nickname}
                </Chip>
              ))}
            </div>
            {assignees.length === 0 && (
              <p className="mt-1.5 text-xs text-rose-500">请至少选一个孩子</p>
            )}
          </div>
        )}

        {/* 排期 */}
        <div className="border-t border-slate-100 pt-4">
          <p className="mb-2.5 text-sm font-semibold text-slate-900">什么时候做</p>
          <RecurrencePicker value={sched} onChange={setSched} />
        </div>

        {/* 时间段 */}
        {sched.mode !== 'deadline' && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="开始时间">
              <input
                type="time"
                value={windowStart}
                onChange={(e) => setWindowStart(e.target.value)}
                className="h-12 w-full rounded-xl border border-slate-200 bg-white px-3 focus:border-slate-900 focus:outline-none"
              />
            </Field>
            <Field label="结束时间">
              <input
                type="time"
                value={windowEnd}
                onChange={(e) => setWindowEnd(e.target.value)}
                className="h-12 w-full rounded-xl border border-slate-200 bg-white px-3 focus:border-slate-900 focus:outline-none"
              />
            </Field>
          </div>
        )}
        {sched.mode === 'deadline' && (
          <Field label="当天几点前" hint="不填就是当天任意时间">
            <input
              type="time"
              value={windowEnd}
              onChange={(e) => setWindowEnd(e.target.value)}
              className="h-12 w-full rounded-xl border border-slate-200 bg-white px-3 focus:border-slate-900 focus:outline-none"
            />
          </Field>
        )}

        {/* 奖励（手动输入积分） */}
        <div className="space-y-4 border-t border-slate-100 pt-4">
          <p className="text-sm font-semibold text-slate-900">奖励</p>

          <PointStepper
            label="完成奖励"
            hint="做完这件事拿多少分"
            value={completionPoints}
            onChange={setCompletionPoints}
            max={isParent ? 200 : cap}
          />

          <PointStepper
            label="打卡奖励"
            hint="过程中每打一次卡拿多少分，0 = 不用打卡"
            value={checkinPoints}
            onChange={setCheckinPoints}
            max={isParent ? 50 : cap}
          />

          {checkinPoints > 0 && (
            <PointStepper
              label="每天最多打几次"
              value={checkinLimit}
              onChange={setCheckinLimit}
              min={1}
              max={20}
            />
          )}

          {overCap && (
            <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
              自己建的任务，两种分加起来最多 {cap} 分。想要更多分，让家长来派任务。
            </p>
          )}
        </div>

        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}

function PointStepper({
  label,
  hint,
  value,
  onChange,
  min = 0,
  max = 100,
}: {
  label: string
  hint?: string
  value: number
  onChange: (v: number) => void
  min?: number
  max?: number
}) {
  const [text, setText] = useState(String(value))
  // value 被外部（如 +/- 按钮）改变时，同步输入框文字
  useEffect(() => {
    setText(String(value))
  }, [value])

  const step = value >= 50 ? 10 : value >= 20 ? 5 : 1

  function clamp(n: number) {
    if (Number.isNaN(n)) return value
    return Math.max(min, Math.min(max, Math.trunc(n)))
  }

  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-700">{label}</p>
        {hint && <p className="text-xs text-slate-400">{hint}</p>}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <button
          type="button"
          onClick={() => onChange(clamp(value - step))}
          className="size-9 rounded-lg bg-slate-100 text-lg font-medium text-slate-600 active:scale-90"
        >
          −
        </button>
        <input
          type="number"
          inputMode="numeric"
          value={text}
          min={min}
          max={max}
          onChange={(e) => {
            setText(e.target.value)
            const n = parseInt(e.target.value, 10)
            if (!Number.isNaN(n)) onChange(clamp(n))
          }}
          onBlur={() => setText(String(clamp(parseInt(text, 10))))}
          className="h-9 w-14 rounded-lg border border-slate-200 bg-white text-center text-base font-semibold tabular-nums text-slate-900 focus:border-slate-900 focus:outline-none"
        />
        <button
          type="button"
          onClick={() => onChange(clamp(value + step))}
          className="size-9 rounded-lg bg-slate-100 text-lg font-medium text-slate-600 active:scale-90"
        >
          +
        </button>
      </div>
    </div>
  )
}
