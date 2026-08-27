import { useState } from 'react'
import {
  defaultSchedule,
  RecurrencePicker,
  toRecurrence,
  type ScheduleValue,
} from '@/components/RecurrencePicker'
import { Button, Chip, Field, Input, Sheet, TASK_COLORS } from '@/components/ui'
import { useBootstrap, useCreateTask, useMe, useViewingMember } from '@/hooks/useApp'
import { BackendError } from '@/lib/backend/types'
import { celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import type { TaskColor } from '@/types/db'

const ICONS = ['⭐', '📚', '🎹', '🏃', '🧹', '🦷', '🛏️', '🥦', '🐶', '🎨', '🧮', '💧']

export function TaskFormSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const viewing = useViewingMember()
  const createTask = useCreateTask()
  const today = boot?.today ?? ''

  const isParent = me?.role === 'parent'
  const cap = boot?.family?.child_task_points_cap ?? 5

  const [title, setTitle] = useState('')
  const [icon, setIcon] = useState('⭐')
  const [color, setColor] = useState<TaskColor>('sky')
  const [assignee, setAssignee] = useState<string>('')
  const [sched, setSched] = useState<ScheduleValue>(() => defaultSchedule(today))
  const [completionPoints, setCompletionPoints] = useState(isParent ? 5 : 1)
  const [checkinPoints, setCheckinPoints] = useState(0)
  const [checkinLimit, setCheckinLimit] = useState(1)
  const [windowStart, setWindowStart] = useState('')
  const [windowEnd, setWindowEnd] = useState('')
  const [err, setErr] = useState('')

  const targetId = isParent ? assignee || viewing?.id || me?.id : me?.id
  const members = boot?.members ?? []

  // 孩子自建任务的积分上限，UI 上直接卡住，别等提交完再报错
  const total = completionPoints + checkinPoints
  const overCap = !isParent && total > cap

  function reset() {
    setTitle('')
    setIcon('⭐')
    setColor('sky')
    setAssignee('')
    setSched(defaultSchedule(today))
    setCompletionPoints(isParent ? 5 : 1)
    setCheckinPoints(0)
    setCheckinLimit(1)
    setWindowStart('')
    setWindowEnd('')
    setErr('')
  }

  async function submit() {
    if (!targetId || !title.trim()) return
    setErr('')
    const r = toRecurrence(sched)
    try {
      await createTask.mutateAsync({
        assigneeId: targetId,
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
      celebrate('small')
      reset()
      onClose()
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="新建任务"
      footer={
        <Button
          size="lg"
          className="mb-1 w-full"
          disabled={!title.trim() || overCap || createTask.isPending}
          onClick={submit}
        >
          {createTask.isPending ? '保存中…' : '保存'}
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

        {/* 派给谁：只有家长能派；成员列表含全部家人（含自己，便于 solo 自测） */}
        {isParent && (
          <div>
            <p className="mb-1.5 text-sm font-medium text-slate-700">派给谁</p>
            <div className="flex flex-wrap gap-2">
              {members.map((m) => (
                <Chip
                  key={m.id}
                  active={targetId === m.id}
                  onClick={() => setAssignee(m.id)}
                  className="flex items-center gap-1.5"
                >
                  <span className="text-base">{m.avatar_emoji}</span>
                  {m.nickname}
                </Chip>
              ))}
            </div>
            {!members.some((m) => m.role === 'child') && (
              <p className="mt-1.5 text-xs text-slate-400">
                还没有孩子加入，可先派给自己测试；要给孩子派任务，去「我」页生成邀请码让孩子加入。
              </p>
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

        {/* 奖励 */}
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
  const step = value >= 50 ? 10 : value >= 20 ? 5 : 1
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-700">{label}</p>
        {hint && <p className="text-xs text-slate-400">{hint}</p>}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <button
          type="button"
          onClick={() => onChange(Math.max(min, value - step))}
          className="size-9 rounded-lg bg-slate-100 text-lg font-medium text-slate-600 active:scale-90"
        >
          −
        </button>
        <span className="w-11 text-center text-base font-semibold tabular-nums text-slate-900">
          {value}
        </span>
        <button
          type="button"
          onClick={() => onChange(Math.min(max, value + step))}
          className="size-9 rounded-lg bg-slate-100 text-lg font-medium text-slate-600 active:scale-90"
        >
          +
        </button>
      </div>
    </div>
  )
}
