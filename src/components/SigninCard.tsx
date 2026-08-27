import { CalendarCheck, Ticket } from 'lucide-react'
import { useState } from 'react'
import { Button, Empty, Field, Input, Sheet } from '@/components/ui'
import { useBootstrap, useMe, useRetroCard, useSignin, useSigninSummary } from '@/hooks/useApp'
import { BackendError } from '@/lib/backend/types'
import { buzz, celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { addDays, formatMd, type Ymd } from '@/lib/date'

/**
 * 今日签到区。
 *
 * 三个状态里只有「签到」是手动的，「活跃」（当天完成 ≥1 个任务）和「满星」
 * （当天全部完成）由后端在完成任务时自动记 —— 所以这里只展示，不给按钮。
 *
 * 视角说明：签到永远是"当前登录的这个人"给自己签，后端 do_signin 也不收
 * member_id。所以这张卡读的是 useMe() 而不是 useViewingMember()：家长切到
 * 孩子看任务时，这里显示的仍然是家长自己的签到状态。
 */

/** 补签卡的三种类型，key 与后端 retro_cards 一一对应 */
type RetroKind = 'retro_signin' | 'retro_active' | 'retro_fullstar'

const RETRO_KINDS: readonly RetroKind[] = ['retro_signin', 'retro_active', 'retro_fullstar']

const KIND_LABEL: Record<RetroKind, string> = {
  retro_signin: '签到',
  retro_active: '活跃',
  retro_fullstar: '满星',
}

const KIND_EMOJI: Record<RetroKind, string> = {
  retro_signin: '📅',
  retro_active: '🔥',
  retro_fullstar: '🌟',
}

/** 连续奖励按 7 天一档展示进度。后端阈值若不是 7 的倍数，改这一个常量即可 */
const MILESTONE_STEP = 7

/**
 * jsonb 过来的数字在 PGlite 里可能是字符串（numeric），统一收一下。
 * 少了这层，"连续 5 天"会变成 "连续 NaN 天"。
 */
function num(v: unknown): number {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

export function SigninCard() {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const { data: summary, isLoading } = useSigninSummary(me?.id ?? '')
  const signin = useSignin()

  const [retroOpen, setRetroOpen] = useState(false)
  const [err, setErr] = useState('')
  const [msg, setMsg] = useState('')

  const today: Ymd = boot?.today ?? ''

  // 地基没到位就整块不渲染，避免闪一个空壳
  if (!me || !today) return null

  const signed = !!summary?.signed_today
  const active = !!summary?.active_today
  const fullstar = !!summary?.fullstar_today

  const streaks: Record<'signin' | 'active' | 'fullstar', number> = {
    signin: num(summary?.streak?.signin),
    active: num(summary?.streak?.active),
    fullstar: num(summary?.streak?.fullstar),
  }

  const cards: Record<RetroKind, number> = {
    retro_signin: num(summary?.retro_cards?.retro_signin),
    retro_active: num(summary?.retro_cards?.retro_active),
    retro_fullstar: num(summary?.retro_cards?.retro_fullstar),
  }
  const totalCards = cards.retro_signin + cards.retro_active + cards.retro_fullstar

  async function doSignin() {
    setErr('')
    setMsg('')
    try {
      await signin.mutateAsync(today)
      buzz()
      celebrate('small')
      setMsg('签到成功，连续天数 +1')
      setTimeout(() => setMsg(''), 1800)
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <div className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200/60">
      {/* 标题行 + 签到按钮 */}
      <div className="flex items-center gap-3">
        <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-slate-100 text-slate-600">
          <CalendarCheck size={18} />
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-sm font-semibold text-slate-900">今日签到</p>
          <p className="truncate text-xs text-slate-400">
            {me.avatar_emoji} {me.nickname} · {formatMd(today)}
          </p>
        </div>
        <Button size="sm" disabled={signed || signin.isPending || isLoading} onClick={doSignin}>
          {signed ? '已签到' : signin.isPending ? '签到中…' : '签到'}
        </Button>
      </div>

      {/* 今日三状态 */}
      <div className="mt-3.5 grid grid-cols-3 gap-2">
        <StatusPill label="签到" emoji={KIND_EMOJI.retro_signin} done={signed} hint="每天手动点一次" />
        <StatusPill label="活跃" emoji={KIND_EMOJI.retro_active} done={active} hint="完成 ≥1 个任务" />
        <StatusPill label="满星" emoji={KIND_EMOJI.retro_fullstar} done={fullstar} hint="今天全部完成" />
      </div>

      {/* 连续天数 */}
      <div className="mt-3 space-y-2">
        <StreakRow label="连续签到" days={streaks.signin} />
        <StreakRow label="连续活跃" days={streaks.active} />
        <StreakRow label="连续满星" days={streaks.fullstar} />
      </div>

      {/* 补签卡 */}
      <div className="mt-3.5 flex items-center gap-2.5 border-t border-slate-100 pt-3">
        <Ticket size={16} className="shrink-0 text-slate-400" />
        <div className="min-w-0 flex-1">
          {totalCards > 0 ? (
            <p className="truncate text-xs text-slate-500">
              {RETRO_KINDS.filter((k) => cards[k] > 0)
                .map((k) => `${KIND_LABEL[k]} ${cards[k]} 张`)
                .join(' · ')}
            </p>
          ) : (
            <p className="text-xs text-slate-400">还没有补签卡，连续打卡可以攒</p>
          )}
        </div>
        <button
          onClick={() => setRetroOpen(true)}
          disabled={totalCards === 0}
          className="shrink-0 rounded-lg px-2 py-1 text-xs font-medium text-slate-600 transition active:scale-95 disabled:opacity-35"
        >
          用补签卡
        </button>
      </div>

      {msg && (
        <p className="mt-3 rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">{msg}</p>
      )}
      {err && <p className="mt-3 rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}

      <RetroSheet
        open={retroOpen}
        onClose={() => setRetroOpen(false)}
        today={today}
        cards={cards}
      />
    </div>
  )
}

function StatusPill({
  label,
  emoji,
  done,
  hint,
}: {
  label: string
  emoji: string
  done: boolean
  hint: string
}) {
  return (
    <div
      className={cn(
        'flex flex-col items-center rounded-xl px-1.5 py-2.5 text-center transition',
        done ? 'bg-emerald-50 ring-1 ring-emerald-200' : 'bg-slate-50',
      )}
      title={hint}
    >
      <span className={cn('text-xl leading-none', !done && 'opacity-35 grayscale')}>{emoji}</span>
      <p
        className={cn(
          'mt-1.5 text-[13px] font-medium',
          done ? 'text-emerald-700' : 'text-slate-500',
        )}
      >
        {label}
      </p>
      <p className={cn('text-[11px]', done ? 'text-emerald-600' : 'text-slate-400')}>
        {done ? '✅ 已达成' : '⬜ 未达成'}
      </p>
    </div>
  )
}

/** 一行连续天数 + 到下一档（7 天一档）的进度 */
function StreakRow({ label, days }: { label: string; days: number }) {
  const target = (Math.floor(days / MILESTONE_STEP) + 1) * MILESTONE_STEP
  const inStage = days % MILESTONE_STEP
  const pct = (inStage / MILESTONE_STEP) * 100

  return (
    <div>
      <div className="flex items-baseline justify-between">
        <span className="text-xs text-slate-500">{label}</span>
        <span className="text-xs text-slate-400">
          <span className="font-semibold tabular-nums text-slate-800">{days}</span> 天
          {days > 0 && ` · 还差 ${target - days} 天到 ${target} 天`}
        </span>
      </div>
      <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-100">
        <div
          className="h-full rounded-full bg-sky-400 transition-all duration-500"
          style={{ width: `${days === 0 ? 0 : Math.max(pct, 6)}%` }}
        />
      </div>
    </div>
  )
}

function RetroSheet({
  open,
  onClose,
  today,
  cards,
}: {
  open: boolean
  onClose: () => void
  today: Ymd
  cards: Record<RetroKind, number>
}) {
  const retro = useRetroCard()
  // 默认补昨天：补签的绝大多数场景就是"昨天忘了"
  const yesterday = addDays(today, -1)
  const [kind, setKind] = useState<RetroKind>('retro_signin')
  const [date, setDate] = useState<Ymd>(yesterday)
  const [err, setErr] = useState('')
  const [msg, setMsg] = useState('')

  function reset() {
    setKind('retro_signin')
    setDate(addDays(today, -1))
    setErr('')
    setMsg('')
  }

  const stock = cards[kind]
  // 只能补过去的日子。今天本来就能直接签，未来更不该能补
  const dateOk = !!date && date < today
  const canSubmit = stock > 0 && dateOk && !retro.isPending

  async function submit() {
    setErr('')
    setMsg('')
    try {
      await retro.mutateAsync({ kind, date })
      buzz()
      celebrate('small')
      setMsg(`已用 1 张「补签·${KIND_LABEL[kind]}」补上 ${formatMd(date)}`)
      setTimeout(() => {
        reset()
        onClose()
      }, 900)
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  const hasAny = RETRO_KINDS.some((k) => cards[k] > 0)

  return (
    <Sheet
      open={open}
      onClose={() => {
        reset()
        onClose()
      }}
      title="使用补签卡"
      footer={
        hasAny ? (
          <Button size="lg" className="mb-1 w-full" disabled={!canSubmit} onClick={submit}>
            {retro.isPending ? '处理中…' : stock > 0 ? `补 ${formatMd(date || today)}` : '没有这种补签卡'}
          </Button>
        ) : undefined
      }
    >
      {!hasAny ? (
        <Empty emoji="🎟️" title="还没有补签卡" hint="连续签到攒够天数会发补签卡" />
      ) : (
        <div className="space-y-5">
          <Field label="补哪一项">
            <div className="grid grid-cols-3 gap-2">
              {RETRO_KINDS.map((k) => {
                const n = cards[k]
                return (
                  <button
                    key={k}
                    type="button"
                    onClick={() => setKind(k)}
                    disabled={n === 0}
                    className={cn(
                      'flex flex-col items-center rounded-xl px-1.5 py-2.5 text-center transition active:scale-95',
                      kind === k ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600',
                      n === 0 && 'opacity-35',
                    )}
                  >
                    <span className="text-xl leading-none">{KIND_EMOJI[k]}</span>
                    <span className="mt-1.5 text-[13px] font-medium">{KIND_LABEL[k]}</span>
                    <span
                      className={cn(
                        'text-[11px] tabular-nums',
                        kind === k ? 'text-slate-300' : 'text-slate-400',
                      )}
                    >
                      {n} 张
                    </span>
                  </button>
                )
              })}
            </div>
          </Field>

          <Field label="补哪一天" hint="只能补今天之前的日子">
            {/* type=date 的 value 本身就是 'YYYY-MM-DD' 字符串，不经过 Date 对象 */}
            <Input
              type="date"
              value={date}
              max={addDays(today, -1)}
              onChange={(e) => setDate(e.target.value)}
            />
          </Field>

          {!dateOk && date !== '' && (
            <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
              只能补今天之前的日子。今天可以直接签到。
            </p>
          )}
          {stock === 0 && (
            <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
              没有对应的补签卡（补签·{KIND_LABEL[kind]}）。
            </p>
          )}
          {msg && (
            <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">{msg}</p>
          )}
          {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
        </div>
      )}
    </Sheet>
  )
}
