import { ChevronRight, Trophy } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Button, Empty, Sheet } from '@/components/ui'
import { useChallengeState, useMe, useRescueChallenge, useStartChallenge } from '@/hooks/useApp'
import { BackendError } from '@/lib/backend/types'
import { buzz, celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { formatMd } from '@/lib/date'
import type { ChallengeCategory, ChallengeCurrent, ChallengeSpec } from '@/api'

/**
 * 不同类挑战统计的"达标维度"用词不同：满星类看「满星」、签到类看「签到」。
 * 后端判定维度已按类切换（018），前端展示文案也要跟着切，不能写死"满星"。
 */
const METRIC_WORD: Record<ChallengeCategory, string> = { fullstar: '满星', signin: '签到' }

/**
 * 挑战任务（016 满星 / 017 按类互斥 / 018 连续签到）。
 *
 * 只给孩子（me.role === 'child'）：挑战是自己的事，家长视角不显示——
 * 和签到卡一样，家长"视孩子"看的是家长自己的数据。
 *
 * 017 起按「类」管理：连续满星 / 连续签到各算一类，
 *   同一类同一时间只能有一条进行中（后端 unique index + start_challenge 双保险），
 *   但不同类可以并行，结束后也能再开（"重复开始"）。
 *   → 这里把 currents 按类逐个渲染；specs 里 busy=true 的类禁用开启按钮。
 *
 * 判定全在后端（challenge_state 惰性评估），所以这里不做任何算分/算天的逻辑，
 * 只把后端算好的数字画出来。
 */

export function ChallengeCard() {
  const me = useMe()
  const { data: state } = useChallengeState()
  const start = useStartChallenge()
  const rescue = useRescueChallenge()

  const [open, setOpen] = useState(false)
  const [err, setErr] = useState('')

  const currents = state?.currents ?? []
  const actives = currents.filter((c) => c.status === 'active')
  const closed = currents.filter((c) => c.status !== 'active')
  const specs = state?.specs ?? []
  const isChild = me?.role === 'child'

  // 刚判成功那一次弹个庆祝（下次读取 just_succeeded 会回到 false，不会反复弹）
  const justSucceeded = currents.some((c) => c.just_succeeded)
  useEffect(() => {
    if (justSucceeded) {
      buzz()
      celebrate('big')
    }
  }, [justSucceeded])

  if (!isChild) return null

  async function onStart(kind: string) {
    setErr('')
    try {
      await start.mutateAsync(kind as ChallengeSpec['kind'])
      buzz()
      celebrate('small')
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  async function onRescue(c: ChallengeCurrent) {
    if (!c.retro_card_item || !c.latest_missed_day) return
    setErr('')
    try {
      await rescue.mutateAsync({ itemId: c.retro_card_item.id, day: c.latest_missed_day })
      buzz()
      celebrate('small')
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  const sub = !currents.length
    ? '还没有进行中的挑战'
    : actives.length
      ? `进行中 · ${actives.map((c) => c.category_label).join(' / ')}`
      : '上一次挑战已结束'

  return (
    <>
      <div className="rounded-2xl bg-surface p-4 shadow-sm ring-1 ring-slate-200/60">
        <div className="flex items-center gap-3">
          <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-surface2 text-muted">
            <Trophy size={18} />
          </span>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-semibold text-fg">挑战任务</p>
            <p className="truncate text-xs text-muted">{sub}</p>
          </div>
          <Button size="sm" onClick={() => setOpen(true)}>
            {actives.length ? '看进度' : '开启挑战'}
          </Button>
        </div>

        {/* 卡片正面：每个进行中的类一行条形进度（按"满星 / 需要"画，不按天数） */}
        {actives.length > 0 && (
          <div className="mt-3 space-y-3">
            {actives.map((c) => (
              <button key={c.id} className="w-full text-left" onClick={() => setOpen(true)}>
                <div className="flex items-baseline justify-between text-xs">
                  <span className="truncate font-medium text-muted">
                    {c.category_label} · 第 {c.elapsed}/{c.window_days} 天
                  </span>
                  <span
                    className={cn(
                      'flex shrink-0 items-center gap-0.5',
                      c.failing ? 'text-rose-600' : 'text-muted',
                    )}
                  >
                    {METRIC_WORD[c.category]} {c.fullstar_days}/{c.required_fullstar}
                    <ChevronRight size={12} />
                  </span>
                </div>
                <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-surface2">
                  <div
                    className={cn(
                      'h-full rounded-full transition-all duration-500',
                      c.failing ? 'bg-rose-400' : 'bg-amber-400',
                    )}
                    style={{
                      width: `${Math.min(c.fullstar_days / c.required_fullstar, 1) * 100}%`,
                    }}
                  />
                </div>
              </button>
            ))}
          </div>
        )}
      </div>

      <Sheet open={open} onClose={() => setOpen(false)} title="挑战任务">
        <div className="space-y-5">
          {/* 进行中：每类一块，含失败预警的补救入口 */}
          {actives.map((c) => (
            <div key={c.id} className="space-y-3">
              <div className="rounded-2xl bg-app p-4">
                <p className="text-sm font-semibold text-fg">
                  {c.category_label}挑战 · 进行中（第 {c.elapsed}/{c.window_days} 天）
                </p>
                <p className="mt-1 text-xs text-muted">
                  {formatMd(c.started_on)} — {formatMd(c.ends_on)} · 每天把任务全部做完就是满星
                </p>
                <div className="mt-3 flex items-end gap-6">
                  <div>
                    <p className="text-2xl font-bold tabular-nums text-fg">
                      {c.fullstar_days}
                      <span className="text-base font-medium text-muted">
                        /{c.required_fullstar}
                      </span>
                    </p>
                    <p className="text-xs text-muted">{METRIC_WORD[c.category]}天数</p>
                  </div>
                  <div>
                    <p
                      className={cn(
                        'text-2xl font-bold tabular-nums',
                        c.missed_days > c.allowed_miss ? 'text-rose-600' : 'text-fg',
                      )}
                    >
                      {c.missed_days}
                      <span className="text-base font-medium text-muted">
                        /{c.allowed_miss}
                      </span>
                    </p>
                    <p className="text-xs text-muted">已漏 / 容错</p>
                  </div>
                  <div>
                    <p className="text-2xl font-bold tabular-nums text-fg">
                      {c.remaining_days}
                    </p>
                    <p className="text-xs text-muted">剩余天数</p>
                  </div>
                </div>
              </div>

              {c.failing ? (
                <div className="rounded-xl bg-rose-50 px-3.5 py-3">
                  <p className="text-sm font-medium text-rose-700">
                    已经漏了 {c.missed_days} 天，超过容错 {c.allowed_miss} 天
                  </p>
                  <p className="mt-1 text-xs text-rose-600">
                    剩下的天数不够凑满 {c.required_fullstar} 天{METRIC_WORD[c.category]}了，这次挑战要失败了。
                    {c.retro_card_item && c.latest_missed_day && (
                      <>
                        <br />
                        要不要买一张「{c.retro_card_item.name}」补上 {formatMd(c.latest_missed_day)}
                        ，让挑战继续？
                      </>
                    )}
                  </p>
                  {c.retro_card_item && c.latest_missed_day && (
                    <Button
                      size="sm"
                      className="mt-2.5"
                      disabled={rescue.isPending}
                      onClick={() => onRescue(c)}
                    >
                      {rescue.isPending
                        ? '处理中…'
                        : `购买${c.retro_card_item.name}补救（${c.retro_card_item.price} 分）`}
                    </Button>
                  )}
                  {!c.retro_card_item && (
                    <p className="mt-2 text-xs text-muted">
                      商城里没有在售的{c.reward_card_label}，先请家长上架一张。
                    </p>
                  )}
                </div>
              ) : (
                <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
                  凑满 {c.required_fullstar} 天{METRIC_WORD[c.category]}就能拿 {c.reward_points} 分和
                  {c.reward_card_label}！
                </p>
              )}
            </div>
          ))}

          {/* 已结束的：给一句结论（这类已经没有进行中的了，下面卡片可以再开） */}
          {closed.map((c) => (
            <p
              key={c.id}
              className={cn(
                'rounded-xl px-3.5 py-2.5 text-sm',
                c.status === 'succeeded'
                  ? 'bg-emerald-50 text-emerald-700'
                  : 'bg-surface2 text-muted',
              )}
            >
              {c.status === 'succeeded'
                ? `🎉 ${c.category_label}挑战成功！已到账 +${c.reward_points} 分 · ${c.reward_card_label} ×1`
                : `${c.category_label}挑战没达标，入场分不退。攒够了可以再开一次。`}
            </p>
          ))}

          {/* 可开的规格：同类已经进行中 → 禁用并说明 */}
          {specs.length ? (
            <div className="space-y-3">
              {specs.map((s) => {
                const afford = (me?.points_balance ?? 0) >= s.entry_fee
                return (
                  <div key={s.kind} className="rounded-2xl bg-surface p-4 ring-1 ring-slate-200/60">
                    <div className="flex items-center justify-between">
                      <p className="text-sm font-semibold text-fg">{s.title}</p>
                      <span className="rounded-md bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-700">
                        入场 -{s.entry_fee} 分
                      </span>
                    </div>
                    <p className="mt-1.5 text-xs text-muted">
                      {s.category_label}类 · {s.window_days} 天内累计{METRIC_WORD[s.category]} ≥{' '}
                      {s.required_fullstar} 天
                      <br />
                      最多可以漏 {s.allowed_miss} 天，漏多了就补不回来了
                    </p>
                    <p className="mt-1.5 text-xs font-medium text-emerald-700">
                      成功奖励 +{s.reward_points} 分 · {s.reward_card_label} ×1
                    </p>
                    <Button
                      size="sm"
                      className="mt-3 w-full"
                      disabled={s.busy || !afford || start.isPending}
                      onClick={() => onStart(s.kind)}
                    >
                      {s.busy
                        ? `${s.category_label}挑战进行中`
                        : !afford
                          ? `积分不够（还差 ${s.entry_fee - (me?.points_balance ?? 0)}）`
                          : start.isPending
                            ? '开启中…'
                            : '开启挑战'}
                    </Button>
                  </div>
                )
              })}
            </div>
          ) : (
            <Empty emoji="🏆" title="挑战加载中" hint="稍等一下" />
          )}

          {err && (
            <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>
          )}
        </div>
      </Sheet>
    </>
  )
}
