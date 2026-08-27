import { Minus, Plus, Settings2 } from 'lucide-react'
import { useState } from 'react'
import { BadgeManageSheet } from '@/components/BadgeManageSheet'
import { Button, Card, Chip, Empty, Field, Input, Sheet, Spinner } from '@/components/ui'
import {
  useAdjust,
  useBadgesWithProgress,
  useBootstrap,
  useLedger,
  useMe,
  useRedeem,
  useShop,
  useViewingMember,
} from '@/hooks/useApp'
import type { RewardItem } from '@/api'
import { ruleSummary, tierLabel, tierRing, toNum } from '@/lib/badgeRules'
import { BackendError } from '@/lib/backend/types'
import { celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { useSession } from '@/store/session'
import type { Member } from '@/types/db'

type Tab = 'shop' | 'history' | 'badges'

/** 家长调分的方向。null = 抽屉关着 */
type AdjustMode = 'add' | 'sub' | null

export default function WalletPage() {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const viewing = useViewingMember()
  const setViewingMember = useSession((s) => s.setViewingMember)
  const [tab, setTab] = useState<Tab>('shop')
  const [item, setItem] = useState<RewardItem | null>(null)
  const [adjust, setAdjust] = useState<AdjustMode>(null)

  const balance = viewing?.points_balance ?? 0
  const isParent = me?.role === 'parent'
  const children = boot?.members?.filter((m) => m.role === 'child') ?? []
  // 家长给自己调分后端会 FORBIDDEN，所以看自己时干脆不给入口
  const canAdjust = isParent && !!viewing && viewing.id !== me?.id

  return (
    <div className="mx-auto w-full max-w-md">
      <div className="pt-safe px-4 pb-3">
        {/* 成员切换。只有一个孩子时切换没有意义，不占一行 */}
        {isParent && children.length > 1 && (
          <div className="no-scrollbar -mx-4 mt-2 flex gap-2 overflow-x-auto px-4 pb-1">
            {children.map((c) => (
              <button
                key={c.id}
                onClick={() => setViewingMember(c.id)}
                className={cn(
                  'flex shrink-0 items-center gap-1.5 rounded-full py-1.5 pl-1.5 pr-3 text-sm font-medium transition',
                  viewing?.id === c.id ? 'bg-slate-900 text-white' : 'bg-white text-slate-600',
                )}
              >
                <span className="text-base">{c.avatar_emoji}</span>
                {c.nickname}
              </button>
            ))}
          </div>
        )}

        {/* 余额卡 */}
        <div className="mt-2 rounded-3xl bg-gradient-to-br from-slate-900 to-slate-700 p-5 text-white shadow-lg">
          <p className="text-sm text-slate-300">
            {viewing?.avatar_emoji} {viewing?.nickname} 的积分
          </p>
          <p className="mt-1 text-4xl font-bold tabular-nums tracking-tight">{balance}</p>
          <p className="mt-1 text-xs text-slate-400">
            {boot?.family?.name} · 攒够了就能换东西
          </p>
        </div>

        {/* 家长操作：打赏 / 扣除 */}
        {canAdjust && (
          <div className="mt-2.5 flex gap-2">
            <Button variant="outline" className="flex-1" onClick={() => setAdjust('add')}>
              <Plus size={16} /> 打赏积分
            </Button>
            <Button variant="outline" className="flex-1" onClick={() => setAdjust('sub')}>
              <Minus size={16} /> 扣除积分
            </Button>
          </div>
        )}
      </div>

      {/* 分段 */}
      <div className="sticky top-0 z-20 flex gap-2 bg-slate-50/85 px-4 py-2 backdrop-blur-lg">
        <Chip active={tab === 'shop'} onClick={() => setTab('shop')}>
          能换什么
        </Chip>
        <Chip active={tab === 'history'} onClick={() => setTab('history')}>
          积分明细
        </Chip>
        <Chip active={tab === 'badges'} onClick={() => setTab('badges')}>
          勋章
        </Chip>
      </div>

      <div className="px-4 pb-28">
        {tab === 'shop' && <ShopList balance={balance} onPick={setItem} />}
        {tab === 'history' && <LedgerList memberId={viewing?.id ?? null} />}
        {tab === 'badges' && <BadgeGrid memberId={viewing?.id ?? ''} isParent={isParent} />}
      </div>

      <RedeemSheet item={item} balance={balance} onClose={() => setItem(null)} />
      <AdjustSheet mode={adjust} member={viewing} onClose={() => setAdjust(null)} />
    </div>
  )
}

function priceOf(item: RewardItem, qty: number): number {
  return Math.ceil(
    item.pricing_mode === 'fixed' ? (item.price_points ?? 0) * qty : (item.rate_points ?? 0) * qty,
  )
}

function ShopList({ balance, onPick }: { balance: number; onPick: (i: RewardItem) => void }) {
  const { data, isLoading } = useShop()
  if (isLoading) return <Spinner />
  if (!data?.length) return <Empty emoji="🛒" title="商城还空着" hint="让家长添加可以兑换的东西" />

  return (
    <div className="space-y-2.5">
      {data.map((item) => {
        const unit = priceOf(item, item.min_quantity)
        const affordable = balance >= unit
        return (
          <Card
            key={item.id}
            className={cn('flex items-center gap-3', !affordable && 'opacity-55')}
          >
            <span className="text-3xl">{item.emoji}</span>
            <div className="min-w-0 flex-1">
              <p className="font-medium text-slate-900">{item.name}</p>
              <p className="text-xs text-slate-400">
                {item.pricing_mode === 'rate'
                  ? `${item.rate_points} 分 = 1 ${item.unit_label}`
                  : `${item.price_points} 分`}
                {item.stock !== null && ` · 剩 ${item.stock}`}
                {item.requires_approval && ' · 需家长确认'}
              </p>
            </div>
            <Button size="sm" disabled={!affordable} onClick={() => onPick(item)}>
              {affordable ? '兑换' : `差 ${unit - balance}`}
            </Button>
          </Card>
        )
      })}
    </div>
  )
}

function RedeemSheet({
  item,
  balance,
  onClose,
}: {
  item: RewardItem | null
  balance: number
  onClose: () => void
}) {
  const redeem = useRedeem()
  const [qty, setQty] = useState(1)
  const [err, setErr] = useState('')
  const [msg, setMsg] = useState('')

  if (!item) return null

  const cost = priceOf(item, qty)
  const step = Number(item.step_quantity) || 1
  const min = Number(item.min_quantity) || 1
  const maxByBalance = Math.floor(balance / priceOf(item, 1))
  const canAdd = qty + step <= maxByBalance && (item.stock === null || qty + step <= item.stock)

  return (
    <Sheet
      open={!!item}
      onClose={() => {
        setQty(1)
        setErr('')
        setMsg('')
        onClose()
      }}
      title={`兑换 ${item.name}`}
      footer={
        <Button
          size="lg"
          className="mb-1 w-full"
          disabled={cost > balance || redeem.isPending}
          onClick={async () => {
            setErr('')
            try {
              const r = await redeem.mutateAsync({ itemId: item.id, quantity: qty })
              celebrate('big')
              setMsg(r.message)
              // 成功后短暂展示结果提示，然后自动关闭 sheet 并清空表单，
              // 避免停留在旧界面上显示已经过期的「兑换后剩余」推算值。
              setTimeout(() => {
                setQty(1)
                setErr('')
                setMsg('')
                onClose()
              }, 700)
            } catch (e) {
              setErr(e instanceof BackendError ? e.message : String(e))
            }
          }}
        >
          {redeem.isPending ? '处理中…' : `用 ${cost} 分兑换`}
        </Button>
      }
    >
      <div className="space-y-5">
        <div className="flex flex-col items-center py-3">
          <span className="text-6xl">{item.emoji}</span>
          <p className="mt-2 text-lg font-semibold text-slate-900">{item.name}</p>
          {item.description && <p className="mt-1 text-sm text-slate-500">{item.description}</p>}
        </div>

        <div className="flex items-center justify-between rounded-2xl bg-slate-50 p-4">
          <span className="text-sm font-medium text-slate-700">
            数量{item.unit_label ? `（${item.unit_label}）` : ''}
          </span>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setQty(Math.max(min, qty - step))}
              className="size-10 rounded-xl bg-white text-xl text-slate-600 shadow-sm active:scale-90"
            >
              −
            </button>
            <span className="w-12 text-center text-xl font-semibold tabular-nums">{qty}</span>
            <button
              onClick={() => setQty(qty + step)}
              disabled={!canAdd}
              className="size-10 rounded-xl bg-white text-xl text-slate-600 shadow-sm active:scale-90 disabled:opacity-30"
            >
              +
            </button>
          </div>
        </div>

        <div className="flex items-baseline justify-between px-1">
          <span className="text-sm text-slate-500">需要</span>
          <span className="text-2xl font-bold tabular-nums text-slate-900">{cost} 分</span>
        </div>
        <div className="flex items-baseline justify-between px-1 text-sm">
          <span className="text-slate-400">兑换后剩余</span>
          <span className={cn('tabular-nums', balance - cost < 0 ? 'text-rose-500' : 'text-slate-500')}>
            {balance - cost} 分
          </span>
        </div>

        {item.requires_approval && (
          <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
            这个需要家长确认。积分会先扣掉，家长不同意的话会自动退回。
          </p>
        )}
        {msg && (
          <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">{msg}</p>
        )}
        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}

// ---------------------------------------------------------------------------
// 家长打赏 / 扣除
// ---------------------------------------------------------------------------
const ADJUST_REASONS: Record<'add' | 'sub', string[]> = {
  add: ['表现特别好', '主动帮忙', '额外加练'],
  sub: ['违反约定', '说好的没做', '需要提醒'],
}

const QUICK_AMOUNTS = [5, 10, 20, 50]

/**
 * 外层只做守卫。真正的表单放在内层组件里，这样抽屉一关就整个卸载 ——
 * 状态自然归零，不用手写 reset，也不会下次打开时残留上一次的分值和理由。
 */
function AdjustSheet({
  mode,
  member,
  onClose,
}: {
  mode: AdjustMode
  member: Member | null
  onClose: () => void
}) {
  if (!mode || !member) return null
  return <AdjustForm mode={mode} member={member} onClose={onClose} />
}

function AdjustForm({
  mode,
  member,
  onClose,
}: {
  mode: 'add' | 'sub'
  member: Member
  onClose: () => void
}) {
  const adjust = useAdjust()
  const [amount, setAmount] = useState('10')
  const [reason, setReason] = useState('')
  const [err, setErr] = useState('')
  const [msg, setMsg] = useState('')

  const isAdd = mode === 'add'
  const n = Number(amount)
  const amountOk = Number.isFinite(n) && n > 0
  const reasonOk = reason.trim().length > 0
  // 扣分不允许扣成负数：后端也会拦，但让家长先看到更友好
  const overdraft = !isAdd && amountOk && n > member.points_balance

  async function submit() {
    setErr('')
    setMsg('')
    try {
      await adjust.mutateAsync({
        memberId: member.id,
        delta: isAdd ? n : -n,
        reason: reason.trim(),
      })
      if (isAdd) celebrate('small')
      setMsg(`${isAdd ? '已打赏' : '已扣除'} ${n} 分`)
      setTimeout(onClose, 800)
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <Sheet
      open
      onClose={onClose}
      title={`${isAdd ? '打赏' : '扣除'} ${member.nickname} 的积分`}
      footer={
        <Button
          size="lg"
          className="mb-1 w-full"
          variant={isAdd ? 'primary' : 'danger'}
          disabled={!amountOk || !reasonOk || overdraft || adjust.isPending}
          onClick={submit}
        >
          {adjust.isPending ? '处理中…' : `确认${isAdd ? '打赏' : '扣除'} ${amountOk ? n : 0} 分`}
        </Button>
      }
    >
      <div className="space-y-4">
        <div className="flex items-center gap-3 rounded-2xl bg-slate-50 p-3.5">
          <span className="text-3xl">{member.avatar_emoji}</span>
          <div className="min-w-0 flex-1">
            <p className="font-medium text-slate-900">{member.nickname}</p>
            <p className="text-xs text-slate-400">当前 {member.points_balance} 分</p>
          </div>
          <span
            className={cn(
              'text-lg font-bold tabular-nums',
              isAdd ? 'text-emerald-600' : 'text-rose-500',
            )}
          >
            {isAdd ? '+' : '−'}
            {amountOk ? n : 0}
          </span>
        </div>

        <Field label="分值">
          <Input
            type="number"
            inputMode="numeric"
            min={1}
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/\D/g, '').slice(0, 5))}
            placeholder="10"
          />
        </Field>
        <div className="flex gap-2">
          {QUICK_AMOUNTS.map((v) => (
            <Chip key={v} active={n === v} onClick={() => setAmount(String(v))}>
              {v}
            </Chip>
          ))}
        </div>

        <Field label="理由" hint="会写进积分明细，孩子能看到">
          <Input
            value={reason}
            onChange={(e) => setReason(e.target.value.slice(0, 30))}
            placeholder={isAdd ? '如：主动收拾了客厅' : '如：约定的阅读没做'}
          />
        </Field>
        <div className="flex flex-wrap gap-2">
          {ADJUST_REASONS[mode].map((r) => (
            <Chip key={r} active={reason === r} onClick={() => setReason(r)}>
              {r}
            </Chip>
          ))}
        </div>

        {overdraft && (
          <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-sm text-amber-800">
            比现有的 {member.points_balance} 分还多，扣不了这么多。
          </p>
        )}
        {!reasonOk && (
          <p className="text-xs text-slate-400">
            理由是必填的 —— 明细里只有数字没有原因，过两天谁都记不起来为什么。
          </p>
        )}
        {msg && (
          <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">{msg}</p>
        )}
        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}

// ---------------------------------------------------------------------------
// 积分明细
// ---------------------------------------------------------------------------
const SOURCE_LABELS: Record<string, string> = {
  checkin: '打卡',
  completion: '完成任务',
  milestone: '阶段奖励',
  badge: '勋章',
  manual: '家长调整',
  redemption: '兑换',
  reversal: '撤销',
  signin: '签到',
  streak: '连续奖励',
}

function LedgerList({ memberId }: { memberId: string | null }) {
  const { data, isLoading } = useLedger(memberId)
  if (isLoading) return <Spinner />
  if (!data?.length) return <Empty emoji="📒" title="还没有积分记录" hint="完成一个任务试试" />

  return (
    <div className="space-y-1.5">
      {data.map((e) => (
        <div
          key={e.id}
          className="flex items-center gap-3 rounded-xl bg-white px-3.5 py-3 shadow-sm ring-1 ring-slate-200/50"
        >
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-slate-800">
              {e.snap_title ?? e.reason ?? SOURCE_LABELS[e.source_type] ?? e.source_type}
            </p>
            <p className="text-xs text-slate-400">
              {SOURCE_LABELS[e.source_type] ?? e.source_type}
              {e.entry_kind === 'reversal' && ' · 已撤销'}
              {' · '}
              {new Date(e.created_at).toLocaleString('zh-CN', {
                month: 'numeric',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
              })}
            </p>
            {e.capped_from != null && (
              <p className="text-xs text-amber-600">今日已达上限，原本 +{e.capped_from}</p>
            )}
          </div>
          <span
            className={cn(
              'shrink-0 text-base font-semibold tabular-nums',
              e.delta > 0 ? 'text-emerald-600' : 'text-slate-500',
            )}
          >
            {e.delta > 0 ? '+' : ''}
            {e.delta}
          </span>
        </div>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------
// 勋章墙（带进度）
// ---------------------------------------------------------------------------
function BadgeGrid({ memberId, isParent }: { memberId: string; isParent: boolean }) {
  const { data, isLoading } = useBadgesWithProgress(memberId)
  const [manage, setManage] = useState(false)

  const list = data ?? []
  const earnedCount = list.filter((b) => !!b.earned).length

  return (
    <div>
      <div className="mb-2.5 flex items-center justify-between px-1">
        <p className="text-xs text-slate-400">
          已获得 {earnedCount} / {list.length}
        </p>
        {isParent && (
          <button
            onClick={() => setManage(true)}
            className="flex items-center gap-1 rounded-lg px-1.5 py-1 text-xs font-medium text-slate-600 active:bg-slate-200"
          >
            <Settings2 size={14} /> 管理勋章
          </button>
        )}
      </div>

      {isLoading ? (
        <Spinner />
      ) : list.length === 0 ? (
        <Empty
          emoji="🏅"
          title="还没有勋章"
          hint={isParent ? '点右上角「管理勋章」建一个' : '让家长设几个目标'}
        />
      ) : (
        <div className="space-y-2">
          {list.map((b) => {
            const got = !!b.earned
            const threshold = toNum(b.threshold)
            const progress = Math.min(toNum(b.progress), threshold || Infinity)
            const pct = got ? 100 : threshold > 0 ? (progress / threshold) * 100 : 0
            return (
              <div
                key={b.badge_id}
                className={cn(
                  'flex items-center gap-3 rounded-2xl bg-white px-3.5 py-3 shadow-sm ring-1',
                  got ? tierRing(b.tier) : 'ring-slate-200/50',
                )}
              >
                <span className={cn('shrink-0 text-3xl', !got && 'opacity-40 grayscale')}>
                  {b.emoji}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline gap-1.5">
                    <p
                      className={cn(
                        'truncate text-[15px] font-medium',
                        got ? 'text-slate-900' : 'text-slate-500',
                      )}
                    >
                      {b.name}
                    </p>
                    {tierLabel(b.tier) && (
                      <span className="shrink-0 text-[11px] text-slate-400">
                        {tierLabel(b.tier)}
                      </span>
                    )}
                  </div>
                  <p className="truncate text-[11px] text-slate-400">{ruleSummary(b.rule)}</p>
                  {!got && threshold > 0 && (
                    <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-slate-100">
                      <div
                        className="h-full rounded-full bg-sky-400 transition-all duration-500"
                        style={{ width: `${pct}%` }}
                      />
                    </div>
                  )}
                </div>
                <span
                  className={cn(
                    'shrink-0 text-xs font-medium tabular-nums',
                    got ? 'text-emerald-600' : 'text-slate-400',
                  )}
                >
                  {got ? '已获得' : threshold > 0 ? `${progress}/${threshold}` : '—'}
                </span>
              </div>
            )
          })}
        </div>
      )}

      {isParent && <BadgeManageSheet open={manage} onClose={() => setManage(false)} />}
    </div>
  )
}
