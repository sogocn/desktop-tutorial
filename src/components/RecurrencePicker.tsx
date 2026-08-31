import { Chip } from '@/components/ui'
import { cn } from '@/lib/cn'
import { dayOfMonth, isoWeekday, WEEKDAY_LABELS, type Ymd } from '@/lib/date'
import type { Recurrence, Task } from '@/types/db'

/**
 * 六种排期的 UI。用户脑子里想的是"每周三练琴"，
 * 数据库存的是 {"freq":"weekly","byweekday":[3]}，这里负责翻译。
 *
 * 预设不是六个平级选项：单日/截止是"一次性"，其余四个是"重复"，
 * 分成两组用户才不用在六个词里比对。
 */
export type ScheduleMode = 'once' | 'deadline' | 'daily' | 'weekday' | 'weekly' | 'monthly'

export const MODE_LABELS: Record<ScheduleMode, { label: string; hint: string; emoji: string }> = {
  once: { label: '就这一天', hint: '只做一次', emoji: '📅' },
  deadline: { label: '某天之前', hint: '倒计时提醒', emoji: '⏳' },
  daily: { label: '每天', hint: '天天都有', emoji: '🔁' },
  weekday: { label: '工作日', hint: '周一到周五', emoji: '💼' },
  weekly: { label: '每周几', hint: '自己挑', emoji: '📆' },
  monthly: { label: '每月几号', hint: '自己挑', emoji: '🗓️' },
}

export interface ScheduleValue {
  mode: ScheduleMode
  date: Ymd
  byweekday: number[]
  bymonthday: number[]
  monthOverflow: 'skip' | 'last_day'
  endsOn: Ymd | null
}

export function defaultSchedule(today: Ymd): ScheduleValue {
  return {
    mode: 'once',
    date: today,
    byweekday: [isoWeekday(today)],
    bymonthday: [dayOfMonth(today)],
    monthOverflow: 'last_day',
    endsOn: null,
  }
}

/** 编辑任务时把已有的 Task 反向映射回表单状态 */
export function taskToSchedule(t: Task): ScheduleValue {
  const date = t.starts_on
  const r = t.recurrence as Recurrence | undefined
  const byweekday = r && 'byweekday' in r && Array.isArray(r.byweekday) ? r.byweekday : [1]
  const bymonthday = r && 'bymonthday' in r && Array.isArray(r.bymonthday) ? r.bymonthday : [1]
  const monthOverflow =
    r && 'month_overflow' in r && (r.month_overflow === 'skip' || r.month_overflow === 'last_day')
      ? r.month_overflow
      : 'last_day'

  if (t.is_deadline_style) {
    return { mode: 'deadline', date, byweekday, bymonthday, monthOverflow, endsOn: t.ends_on }
  }
  if (t.schedule_kind === 'once') {
    return { mode: 'once', date, byweekday, bymonthday, monthOverflow, endsOn: t.ends_on }
  }
  if (r?.freq === 'daily') {
    return { mode: 'daily', date, byweekday, bymonthday, monthOverflow, endsOn: t.ends_on }
  }
  if (r?.freq === 'weekly') {
    const isWeekday = byweekday.length === 5 && [1, 2, 3, 4, 5].every((d) => byweekday.includes(d))
    return {
      mode: isWeekday ? 'weekday' : 'weekly',
      date,
      byweekday,
      bymonthday,
      monthOverflow,
      endsOn: t.ends_on,
    }
  }
  if (r?.freq === 'monthly') {
    return { mode: 'monthly', date, byweekday, bymonthday, monthOverflow, endsOn: t.ends_on }
  }
  return { mode: 'once', date, byweekday: [1], bymonthday: [1], monthOverflow: 'last_day', endsOn: t.ends_on }
}

/** 把 UI 状态翻译成数据库认的东西 */
export function toRecurrence(v: ScheduleValue): {
  scheduleKind: 'once' | 'recurring'
  recurrence: Recurrence
  startsOn: Ymd
  isDeadline: boolean
} {
  switch (v.mode) {
    case 'once':
    case 'deadline':
      return {
        scheduleKind: 'once',
        recurrence: { freq: 'once', date: v.date },
        startsOn: v.date,
        isDeadline: v.mode === 'deadline',
      }
    case 'daily':
      return { scheduleKind: 'recurring', recurrence: { freq: 'daily' }, startsOn: v.date, isDeadline: false }
    case 'weekday':
      return {
        scheduleKind: 'recurring',
        recurrence: { freq: 'weekly', byweekday: [1, 2, 3, 4, 5] },
        startsOn: v.date,
        isDeadline: false,
      }
    case 'weekly':
      return {
        scheduleKind: 'recurring',
        recurrence: { freq: 'weekly', byweekday: [...v.byweekday].sort((a, b) => a - b) },
        startsOn: v.date,
        isDeadline: false,
      }
    case 'monthly':
      return {
        scheduleKind: 'recurring',
        recurrence: {
          freq: 'monthly',
          bymonthday: [...v.bymonthday].sort((a, b) => a - b),
          month_overflow: v.monthOverflow,
        },
        startsOn: v.date,
        isDeadline: false,
      }
  }
}

/** 一句人话摘要，放在表单顶部让用户确认自己选对了 */
export function describeSchedule(v: ScheduleValue): string {
  const wd = (n: number) => `周${WEEKDAY_LABELS[n - 1]}`
  switch (v.mode) {
    case 'once':
      return `只在 ${v.date} 这天`
    case 'deadline':
      return `${v.date} 之前完成`
    case 'daily':
      return '每天都有'
    case 'weekday':
      return '每个工作日（周一到周五）'
    case 'weekly':
      return v.byweekday.length ? `每${v.byweekday.map(wd).join('、').replace(/周/g, '')}`.replace('每', '每周') : '还没选星期'
    case 'monthly': {
      if (!v.bymonthday.length) return '还没选日期'
      const days = v.bymonthday.join('、')
      const has31 = v.bymonthday.some((d) => d > 28)
      const tail = has31
        ? v.monthOverflow === 'last_day'
          ? '（没有这天的月份顺延到月底）'
          : '（没有这天的月份跳过）'
        : ''
      return `每月 ${days} 号${tail}`
    }
  }
}

export function RecurrencePicker({
  value,
  onChange,
}: {
  value: ScheduleValue
  onChange: (v: ScheduleValue) => void
}) {
  const set = (p: Partial<ScheduleValue>) => onChange({ ...value, ...p })

  const toggleWeekday = (n: number) => {
    const has = value.byweekday.includes(n)
    // 不允许清空成 0 个 —— 数据库那边 CHECK 会拒，不如在这里就不让点
    if (has && value.byweekday.length === 1) return
    set({ byweekday: has ? value.byweekday.filter((x) => x !== n) : [...value.byweekday, n] })
  }

  const toggleMonthday = (n: number) => {
    const has = value.bymonthday.includes(n)
    if (has && value.bymonthday.length === 1) return
    set({ bymonthday: has ? value.bymonthday.filter((x) => x !== n) : [...value.bymonthday, n] })
  }

  const isRecurring = value.mode !== 'once' && value.mode !== 'deadline'

  return (
    <div className="space-y-4">
      {/* 六种模式 */}
      <div className="grid grid-cols-3 gap-2">
        {(Object.keys(MODE_LABELS) as ScheduleMode[]).map((m) => {
          const info = MODE_LABELS[m]
          return (
            <button
              key={m}
              type="button"
              onClick={() => set({ mode: m })}
              className={cn(
                'flex flex-col items-center gap-0.5 rounded-xl py-2.5 transition active:scale-95',
                value.mode === m ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600',
              )}
            >
              <span className="text-lg">{info.emoji}</span>
              <span className="text-[13px] font-medium">{info.label}</span>
              <span
                className={cn(
                  'text-[10px]',
                  value.mode === m ? 'text-slate-300' : 'text-slate-400',
                )}
              >
                {info.hint}
              </span>
            </button>
          )
        })}
      </div>

      {/* 日期 */}
      <label className="block">
        <span className="mb-1.5 block text-sm font-medium text-slate-700">
          {value.mode === 'deadline' ? '截止日期' : value.mode === 'once' ? '哪一天' : '从哪天开始'}
        </span>
        <input
          type="date"
          value={value.date}
          onChange={(e) => set({ date: e.target.value })}
          className="h-12 w-full rounded-xl border border-slate-200 bg-white px-3.5 text-slate-900 focus:border-slate-900 focus:outline-none"
        />
      </label>

      {/* 星期选择 */}
      {value.mode === 'weekly' && (
        <div>
          <p className="mb-1.5 text-sm font-medium text-slate-700">每周哪几天</p>
          <div className="grid grid-cols-7 gap-1.5">
            {WEEKDAY_LABELS.map((w, i) => {
              const n = i + 1
              const on = value.byweekday.includes(n)
              return (
                <button
                  key={w}
                  type="button"
                  onClick={() => toggleWeekday(n)}
                  className={cn(
                    'aspect-square rounded-lg text-sm font-medium transition active:scale-95',
                    on ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-500',
                  )}
                >
                  {w}
                </button>
              )
            })}
          </div>
        </div>
      )}

      {/* 每月几号 */}
      {value.mode === 'monthly' && (
        <div className="space-y-3">
          <div>
            <p className="mb-1.5 text-sm font-medium text-slate-700">每月哪几号</p>
            <div className="grid grid-cols-7 gap-1.5">
              {Array.from({ length: 31 }, (_, i) => i + 1).map((n) => {
                const on = value.bymonthday.includes(n)
                return (
                  <button
                    key={n}
                    type="button"
                    onClick={() => toggleMonthday(n)}
                    className={cn(
                      'aspect-square rounded-lg text-[13px] font-medium transition active:scale-95',
                      on ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-500',
                    )}
                  >
                    {n}
                  </button>
                )
              })}
            </div>
          </div>

          {/* 29/30/31 号才需要问这个，2 月没有 31 号 */}
          {value.bymonthday.some((d) => d > 28) && (
            <div>
              <p className="mb-1.5 text-sm font-medium text-slate-700">遇到没有这天的月份</p>
              <div className="flex gap-2">
                <Chip
                  active={value.monthOverflow === 'last_day'}
                  onClick={() => set({ monthOverflow: 'last_day' })}
                >
                  顺延到月底
                </Chip>
                <Chip
                  active={value.monthOverflow === 'skip'}
                  onClick={() => set({ monthOverflow: 'skip' })}
                >
                  当月跳过
                </Chip>
              </div>
            </div>
          )}
        </div>
      )}

      {/* 结束日期 */}
      {isRecurring && (
        <label className="block">
          <span className="mb-1.5 block text-sm font-medium text-slate-700">
            重复到哪天为止 <span className="font-normal text-slate-400">（可不填）</span>
          </span>
          <input
            type="date"
            value={value.endsOn ?? ''}
            min={value.date}
            onChange={(e) => set({ endsOn: e.target.value || null })}
            className="h-12 w-full rounded-xl border border-slate-200 bg-white px-3.5 text-slate-900 focus:border-slate-900 focus:outline-none"
          />
        </label>
      )}

      <p className="rounded-xl bg-sky-50 px-3.5 py-2.5 text-sm text-sky-800">
        {describeSchedule(value)}
      </p>
    </div>
  )
}
