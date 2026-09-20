import { Trophy } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Button, Empty, Sheet } from '@/components/ui'
import { useChallengeState, useMe, useRescueChallenge, useStartChallenge } from '@/hooks/useApp'
import { BackendError } from '@/lib/backend/types'
import { buzz, celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { formatMd } from '@/lib/date'
import type { ChallengeSpec } from '@/api'

/**
 * 满星挑战（016）。
 *
 * 只给孩子（me.role === 'child'）：挑战是自己的事，家长视角不显示——
 * 和签到卡一样，家长"视孩子"看的是家长自己的数据。
 *
 * 三种形态：
 *   1) 没开过 / 已结束 → 两张挑战卡，付积分开启
 *   2) 进行中         → 进度（满星 x/要求 · 第 n/窗口 天 · 已漏 m 天）
 *   3) 漏超过容错     → 失败预警 + 「购买满星卡补救」（补完那天，挑战自动恢复）
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

  const cur = state?.current ?? null
  const isChild = me?.role === 'child'

  // 刚判成功那一次弹个庆祝（下次读取 just_succeeded 会回到 false，不会反复弹）
  useEffect(() => {
    if (cur?.just_succeeded) {
      buzz()
      celebrate('big')
    }
  }, [cur?.just_succeeded])

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

  async function onRescue() {
    if (!state?.fullstar_card_item || !cur?.latest_missed_day) return
    setErr('')
    try {
      await rescue.mutateAsync({
        itemId: state.fullstar_card_item.id,
        day: cur.latest_missed_day,
      })
      buzz()
      celebrate('small')
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  const card = state?.fullstar_card_item

  return (
    <>
      <div className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200/60">
        <div className="flex items-center gap-3">
          <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-slate-100 text-slate-600">
            <Trophy size={18} />
          </span>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-semibold text-slate-900">挑战任务</p>
            <p className="truncate text-xs text-slate-400">
              {!cur
                ? '还没有进行中的挑战'
                : cur.status === 'active'
                  ? cur.failing
                    ? '⚠️ 漏太多了，可以买满星卡补救'
                    : `进行中 · 第 ${cur.elapsed}/${cur.window_days} 天`
                  : cur.status === 'succeeded'
                    ? '🎉 挑战成功'
                    : '挑战失败，可以再开一次'}
            </p>
          </div>
          <Button size="sm" onClick={() => setOpen(true)}>
            {!cur || cur.status !== 'active' ? '开启挑战' : '看进度'}
          </Button>
        </div>

        {/* 进行中：条形进度（按"满星 / 需要"画，而不是按天数） */}
        {cur?.status === 'active' && (
          <div className="mt-3">
            <div className="flex items-baseline justify-between text-xs">
              <span className={cn('font-medium', cur.failing ? 'text-rose-600' : 'text-slate-500')}>
                满星 {cur.fullstar_days}/{cur.required_fullstar}
              </span>
              <span className="text-slate-400">
                已漏 {cur.missed_days} 天 · 容错 {cur.allowed_miss} 天 · 剩 {cur.remaining_days} 天
              </span>
            </div>
            <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-slate-100">
              <div
                className={cn(
                  'h-full rounded-full transition-all duration-500',
                  cur.failing ? 'bg-rose-400' : 'bg-amber-400',
                )}
                style={{
                  width: `${Math.min(cur.fullstar_days / cur.required_fullstar, 1) * 100}%`,
                }}
              />
            </div>
          </div>
        )}
      </div>

      <Sheet open={open} onClose={() => setOpen(false)} title="挑战任务">
        <div className="space-y-5">
          {/* 进行中：进度 + 失败预警 */}
          {cur?.status === 'active' ? (
            <>
              <div className="rounded-2xl bg-slate-50 p-4">
                <p className="text-sm font-semibold text-slate-900">
                  {cur.kind === 'fullstar_21' ? '21天满星挑战' : '45天满星挑战'} · 进行中
                </p>
                <p className="mt-1 text-xs text-slate-500">
                  {formatMd(cur.started_on)} — {formatMd(cur.ends_on)} · 第 {cur.elapsed}/
                  {cur.window_days} 天
                </p>
                <div className="mt-3 flex items-end gap-6">
                  <div>
                    <p className="text-2xl font-bold tabular-nums text-slate-900">
                      {cur.fullstar_days}
                      <span className="text-base font-medium text-slate-400">
                        /{cur.required_fullstar}
                      </span>
                    </p>
                    <p className="text-xs text-slate-400">满星天数</p>
                  </div>
                  <div>
                    <p
                      className={cn(
                        'text-2xl font-bold tabular-nums',
                        cur.missed_days > cur.allowed_miss ? 'text-rose-600' : 'text-slate-900',
                      )}
                    >
                      {cur.missed_days}
                      <span className="text-base font-medium text-slate-400">
                        /{cur.allowed_miss}
                      </span>
                    </p>
                    <p className="text-xs text-slate-400">已漏 / 容错</p>
                  </div>
                  <div>
                    <p className="text-2xl font-bold tabular-nums text-slate-900">
                      {cur.remaining_days}
                    </p>
                    <p className="text-xs text-slate-400">剩余天数</p>
                  </div>
                </div>
              </div>

              {cur.failing ? (
                <div className="rounded-xl bg-rose-50 px-3.5 py-3">
                  <p className="text-sm font-medium text-rose-700">
                    已经漏了 {cur.missed_days} 天，超过容错 {cur.allowed_miss} 天
                  </p>
                  <p className="mt-1 text-xs text-rose-600">
                    剩下的天数不够凑满 {cur.required_fullstar} 天满星了，这次挑战要失败了。
                    {card && cur.latest_missed_day && (
                      <>
                        <br />
                        要不要买一张「{card.name}」补上 {formatMd(cur.latest_missed_day)}
                        ，让挑战继续？
                      </>
                    )}
                  </p>
                  {card && cur.latest_missed_day && (
                    <Button
                      size="sm"
                      className="mt-2.5"
                      disabled={rescue.isPending}
                      onClick={onRescue}
                    >
                      {rescue.isPending ? '处理中…' : `购买满星卡补救（${card.price} 分）`}
                    </Button>
                  )}
                  {!card && (
                    <p className="mt-2 text-xs text-slate-500">
                      商城里没有在售的补满星卡，先请家长上架一张。
                    </p>
                  )}
                </div>
              ) : (
                <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
                  每天把任务全部做完就是满星。凑满 {cur.required_fullstar} 天就能拿{' '}
                  {cur.reward_points} 分和{cur.reward_card_label}！
                </p>
              )}
            </>
          ) : (
            <>
              {cur?.status === 'succeeded' && (
                <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">
                  🎉 挑战成功！已到账 +{cur.reward_points} 分 · {cur.reward_card_label} ×1
                </p>
              )}
              {cur?.status === 'failed' && (
                <p className="rounded-xl bg-slate-100 px-3.5 py-2.5 text-sm text-slate-600">
                  这次挑战没达标，入场分不退。攒够了可以再开一次。
                </p>
              )}

              {state?.specs?.length ? (
                <div className="space-y-3">
                  {state.specs.map((s) => {
                    const afford = (me?.points_balance ?? 0) >= s.entry_fee
                    return (
                      <div
                        key={s.kind}
                        className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/60"
                      >
                        <div className="flex items-center justify-between">
                          <p className="text-sm font-semibold text-slate-900">{s.title}</p>
                          <span className="rounded-md bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-700">
                            入场 -{s.entry_fee} 分
                          </span>
                        </div>
                        <p className="mt-1.5 text-xs text-slate-500">
                          {s.window_days} 天内累计满星 ≥ {s.required_fullstar} 天
                          <br />
                          最多可以漏 {s.allowed_miss} 天，漏多了就补不回来了
                        </p>
                        <p className="mt-1.5 text-xs font-medium text-emerald-700">
                          成功奖励 +{s.reward_points} 分 · {s.reward_card_label} ×1
                        </p>
                        <Button
                          size="sm"
                          className="mt-3 w-full"
                          disabled={!afford || start.isPending}
                          onClick={() => onStart(s.kind)}
                        >
                          {afford
                            ? start.isPending
                              ? '开启中…'
                              : '开启挑战'
                            : `积分不够（还差 ${s.entry_fee - (me?.points_balance ?? 0)}）`}
                        </Button>
                      </div>
                    )
                  })}
                </div>
              ) : (
                <Empty emoji="🏆" title="挑战加载中" hint="稍等一下" />
              )}
            </>
          )}

          {err && (
            <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>
          )}
        </div>
      </Sheet>
    </>
  )
}
