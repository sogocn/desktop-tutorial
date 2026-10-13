import { Minus, Plus, Settings2 } from 'lucide-react'
import { useState } from 'react'
import { BadgeManageSheet } from '@/components/BadgeManageSheet'
import { SkinPriceSheet } from '@/components/SkinPriceSheet'
import { SkinIcon } from '@/components/SkinIcon'
import { Button, Card, Chip, Empty, Field, Input, Sheet, Spinner } from '@/components/ui'
import {
  useAdjust,
  useBadgesWithProgress,
  useBootstrap,
  useLedger,
  useMe,
  useRedeem,
  useRedeemSkin,
  useSetMemberSkin,
  useShop,
  useSkins,
  useStartSkinTrial,
  useEndSkinTrial,
  useViewingMember,
} from '@/hooks/useApp'
import type { RewardItem } from '@/api'
import { ruleSummary, tierLabel, tierRing, toNum } from '@/lib/badgeRules'
import { BackendError } from '@/lib/backend/types'
import { celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { useSession } from '@/store/session'
import { applyTheme, patternUrl, photoBg } from '@/lib/theme'
import type { Member, Skin } from '@/types/db'

type Tab = 'shop' | 'history' | 'badges' | 'skins'

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
                  viewing?.id === c.id ? 'bg-primary text-white' : 'bg-surface text-muted',
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
          <p className="text-sm text-muted">
            {viewing?.avatar_emoji} {viewing?.nickname} 的积分
          </p>
          <p className="mt-1 text-4xl font-bold tabular-nums tracking-tight">{balance}</p>
          <p className="mt-1 text-xs text-muted">
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
      <div className="sticky top-0 z-20 flex gap-2 bg-app/85 px-4 py-2 backdrop-blur-lg">
        <Chip active={tab === 'shop'} onClick={() => setTab('shop')}>
          能换什么
        </Chip>
        <Chip active={tab === 'history'} onClick={() => setTab('history')}>
          积分明细
        </Chip>
        <Chip active={tab === 'badges'} onClick={() => setTab('badges')}>
          勋章
        </Chip>
        <Chip active={tab === 'skins'} onClick={() => setTab('skins')}>
          皮肤
        </Chip>
      </div>

      <div className="px-4 pb-28">
        {tab === 'shop' && <ShopList balance={balance} onPick={setItem} />}
        {tab === 'history' && <LedgerList memberId={viewing?.id ?? null} />}
        {tab === 'badges' && <BadgeGrid memberId={viewing?.id ?? ''} isParent={isParent} />}
        {tab === 'skins' && <SkinShop />}
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
              <p className="font-medium text-fg">{item.name}</p>
              <p className="text-xs text-muted">
                {item.pricing_mode === 'rate'
                  ? `${item.rate_points} 分 = 1 ${item.unit_label}`
                  : `${item.price_points} 分`}
                {item.stock !== null && ` · 剩 ${item.stock}`}
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
          <p className="mt-2 text-lg font-semibold text-fg">{item.name}</p>
          {item.description && <p className="mt-1 text-sm text-muted">{item.description}</p>}
        </div>

        <div className="flex items-center justify-between rounded-2xl bg-app p-4">
          <span className="text-sm font-medium text-fg">
            数量{item.unit_label ? `（${item.unit_label}）` : ''}
          </span>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setQty(Math.max(min, qty - step))}
              className="size-10 rounded-xl bg-surface text-xl text-muted shadow-sm active:scale-90"
            >
              −
            </button>
            <span className="w-12 text-center text-xl font-semibold tabular-nums">{qty}</span>
            <button
              onClick={() => setQty(qty + step)}
              disabled={!canAdd}
              className="size-10 rounded-xl bg-surface text-xl text-muted shadow-sm active:scale-90 disabled:opacity-30"
            >
              +
            </button>
          </div>
        </div>

        <div className="flex items-baseline justify-between px-1">
          <span className="text-sm text-muted">需要</span>
          <span className="text-2xl font-bold tabular-nums text-fg">{cost} 分</span>
        </div>
        <div className="flex items-baseline justify-between px-1 text-sm">
          <span className="text-muted">兑换后剩余</span>
          <span className={cn('tabular-nums', balance - cost < 0 ? 'text-rose-500' : 'text-muted')}>
            {balance - cost} 分
          </span>
        </div>

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
        <div className="flex items-center gap-3 rounded-2xl bg-app p-3.5">
          <span className="text-3xl">{member.avatar_emoji}</span>
          <div className="min-w-0 flex-1">
            <p className="font-medium text-fg">{member.nickname}</p>
            <p className="text-xs text-muted">当前 {member.points_balance} 分</p>
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
          <p className="text-xs text-muted">
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
  fullstar: '满星',
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
          className="flex items-center gap-3 rounded-xl bg-surface px-3.5 py-3 shadow-sm ring-1 ring-slate-200/50"
        >
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-fg">
              {e.snap_title ?? e.reason ?? SOURCE_LABELS[e.source_type] ?? e.source_type}
            </p>
            <p className="text-xs text-muted">
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
              e.delta > 0 ? 'text-emerald-600' : 'text-muted',
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
        <p className="text-xs text-muted">
          已获得 {earnedCount} / {list.length}
        </p>
        {isParent && (
          <button
            onClick={() => setManage(true)}
            className="flex items-center gap-1 rounded-lg px-1.5 py-1 text-xs font-medium text-muted active:bg-surface2"
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
                  'flex items-center gap-3 rounded-2xl bg-surface px-3.5 py-3 shadow-sm ring-1',
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
                        got ? 'text-fg' : 'text-muted',
                      )}
                    >
                      {b.name}
                    </p>
                    {tierLabel(b.tier) && (
                      <span className="shrink-0 text-[11px] text-muted">
                        {tierLabel(b.tier)}
                      </span>
                    )}
                  </div>
                  <p className="truncate text-[11px] text-muted">{ruleSummary(b.rule)}</p>
                  {toNum(b.points_bonus) > 0 && (
                    <p className="truncate text-[11px] text-emerald-600">
                      奖励 +{toNum(b.points_bonus)} 分
                    </p>
                  )}
                  {!got && threshold > 0 && (
                    <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-surface2">
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
                    got ? 'text-emerald-600' : 'text-muted',
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

// ---------------------------------------------------------------------------
// 皮肤商店（019）
// 基于「当前登录成员」自己的皮肤与积分：列表里的 owned/current 都是这个人的，
// 兑换/切换走的也是这个人的身份（后端 require_member 锁定的是登录者）。
// ---------------------------------------------------------------------------
/** 「结束试用」没有对应的卡片 id，用这个哨兵值占住 busyId，避免误伤卡片按钮 */
const END_TRIAL_BUSY = '__end_trial__'

/** 试用剩余时长：24 小时制，不足 1 小时就说"不到 1 小时"，免得显示 0 小时让人以为已经没了 */
function trialLeft(hours: number | null | undefined): string {
  if (hours == null) return ''
  if (hours <= 0) return '不到 1 小时'
  return `${Math.min(hours, 24)} 小时`
}

/** 把后端异常码翻成家长/孩子看得懂的话（BackendError 的 message 已不含 CODE 前缀） */
function friendlySkinErr(e: unknown): string {
  if (!(e instanceof BackendError)) return String(e)
  switch (e.code) {
    case 'NOT_ENOUGH_POINTS':
      return '积分不够啦，先去完成任务攒一攒'
    case 'SKIN_OWNED':
      return '这个皮肤你已经有了'
    case 'SKIN_DEFAULT_FREE':
      return '默认皮肤免费，直接点「使用」就行'
    case 'SKIN_NOT_OWNED':
      return '还没有这个皮肤，先兑换吧'
    case 'SKIN_TRIAL_USED':
      return '这个皮肤你已经试用过了，喜欢就兑换吧'
    case 'SKIN_TRIAL_ACTIVE':
      return '一次只能试用一张，先点「结束试用」再换别的'
    case 'SKIN_NOT_FOUND':
      return '这个皮肤不存在，刷新一下再试'
    default:
      return e.message || '出错了，请重试'
  }
}

function SkinShop() {
  const me = useMe()
  const { data: skins, isLoading } = useSkins(me?.id ?? null)
  const redeemSkin = useRedeemSkin()
  const setMemberSkin = useSetMemberSkin()
  const startSkinTrial = useStartSkinTrial()
  const endSkinTrial = useEndSkinTrial()
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [priceOpen, setPriceOpen] = useState(false)

  if (isLoading) return <Spinner />
  if (!me) return null

  const balance = me.points_balance
  const list = skins ?? []
  const isParent = me.role === 'parent'

  async function onRedeem(s: Skin) {
    if (s.is_default) return
    setMsg(null)
    setBusyId(s.id)
    try {
      const r = await redeemSkin.mutateAsync(s.id)
      // 兑换完直接换上：主题立刻变，按下去就有肉眼可见的反馈，不用再点一次「使用」
      applyTheme(s.theme)
      await setMemberSkin.mutateAsync(s.id)
      celebrate('big')
      setMsg({ kind: 'ok', text: `已兑换并换上「${s.name}」，花掉 ${r.points_spent} 分` })
    } catch (e) {
      setMsg({ kind: 'err', text: friendlySkinErr(e) })
    } finally {
      setBusyId(null)
    }
  }

  async function onUse(s: Skin) {
    setMsg(null)
    setBusyId(s.id)
    // 不等服务端返回就先把主题画上去，点击瞬间就有反应，请求失败再回滚成当前皮肤
    const prev = list.find((x) => x.current)?.theme
    applyTheme(s.theme)
    try {
      await setMemberSkin.mutateAsync(s.id)
      celebrate('small')
      setMsg({ kind: 'ok', text: `已切换到「${s.name}」` })
    } catch (e) {
      applyTheme(prev)
      setMsg({ kind: 'err', text: friendlySkinErr(e) })
    } finally {
      setBusyId(null)
    }
  }

  /** 试用 1 天：不扣积分，也不算拥有；24 小时后后端自动回落到原来那张 */
  async function onTrial(s: Skin) {
    setMsg(null)
    setBusyId(s.id)
    const prev = list.find((x) => x.current)?.theme
    applyTheme(s.theme)
    try {
      await startSkinTrial.mutateAsync(s.id)
      celebrate('small')
      setMsg({
        kind: 'ok',
        text: `已开始试用「${s.name}」：不扣积分，24 小时后自动回到原来那张。喜欢就点「兑换保留」。`,
      })
    } catch (e) {
      applyTheme(prev)
      setMsg({ kind: 'err', text: friendlySkinErr(e) })
    } finally {
      setBusyId(null)
    }
  }

  /** 提前结束试用，回到自己选的那张（没有就回默认皮肤） */
  async function onEndTrial() {
    setMsg(null)
    setBusyId(END_TRIAL_BUSY)
    const back =
      list.find((x) => x.id === me?.selected_skin_id) ?? list.find((x) => x.is_default)
    applyTheme(back?.theme)
    try {
      await endSkinTrial.mutateAsync()
      setMsg({ kind: 'ok', text: `试用已结束，回到「${back?.name ?? '默认皮肤'}」` })
    } catch (e) {
      applyTheme(list.find((x) => x.current)?.theme)
      setMsg({ kind: 'err', text: friendlySkinErr(e) })
    } finally {
      setBusyId(null)
    }
  }

  const trialing = list.find((s) => s.trial_active) ?? null

  return (
    <div className="space-y-3">
      <p className="px-1 text-xs text-muted">
        用积分兑换皮肤，换上后整页背景、配色、按钮都跟着变。当前 {me.nickname} 有{' '}
        <span className="font-semibold text-fg">{balance}</span> 分。
        {list.some((s) => !s.is_default) && ' 收费皮肤都能先免费试用 1 天，到期自动回到原来那张。'}
      </p>

      {/* 正在试用时给一条全局提醒，免得孩子在别的 Tab 里忘了这回事 */}
      {trialing && (
        <p className="rounded-xl bg-amber-50 px-3.5 py-2.5 text-xs text-amber-800">
          正在试用「{trialing.name}」，还剩 {trialLeft(trialing.trial_hours_left)}
          {trialing.trial_ends_at &&
            `（到 ${new Date(trialing.trial_ends_at).toLocaleString('zh-CN', {
              month: 'numeric',
              day: 'numeric',
              hour: '2-digit',
              minute: '2-digit',
            })}）`}
          。到期会自动回到原来那张，也可以现在就结束；一次只能试用一张，想换别的请先结束。
        </p>
      )}

      {/* 家长专属：就地改价，省得还要跑到「我的」里找 */}
      {isParent && (
        <button
          type="button"
          onClick={() => setPriceOpen(true)}
          className="w-full rounded-2xl bg-surface px-3.5 py-2.5 text-sm font-medium text-fg shadow-sm ring-1 ring-line"
        >
          调整皮肤价格（家长）
        </button>
      )}

      {msg && (
        <p
          className={cn(
            'rounded-xl px-3.5 py-2.5 text-sm',
            msg.kind === 'ok' ? 'bg-emerald-50 text-emerald-700' : 'bg-rose-50 text-rose-600',
          )}
        >
          {msg.text}
        </p>
      )}

      {list.map((s) => {
        const affordable = balance >= s.price
        return (
          <div
            key={s.id}
            className="overflow-hidden rounded-2xl border border-line bg-surface shadow-sm"
          >
            {/* 预览：直接用这张皮肤自己的配色渲染，一眼看出差别 */}
            <div
              className="relative h-24 w-full"
              style={{
                background: s.theme.bg,
                // 头图横幅打底 + pattern 叠加，预览和真正换上后看到的一致
                backgroundImage:
                  [photoBg(s.theme.banner), patternUrl(s.theme.pattern, s.theme.accent)]
                    .filter(Boolean)
                    .join(', ') || undefined,
                backgroundSize: 'cover, auto',
              }}
            >
              <div
                className="flex h-8 items-center gap-1.5 px-3 text-sm font-semibold"
                style={{ background: s.theme.primary, color: s.theme.onPrimary }}
              >
                <SkinIcon skinKey={s.key} className="h-4 w-4" />
                {s.name}
              </div>
              <div
                className="m-3 flex items-center justify-between rounded-lg px-3 py-2 text-sm"
                style={{ background: s.theme.surface, color: s.theme.text }}
              >
                <span>今日任务</span>
                <span
                  className="rounded-full px-2 py-0.5 text-xs font-semibold"
                  style={{ background: s.theme.accent, color: '#fff' }}
                >
                  +10
                </span>
              </div>
            </div>

            <div className="flex items-center gap-3 p-3.5">
              <div className="min-w-0 flex-1">
                <p className="font-medium text-fg">{s.name}</p>
                <p className="truncate text-xs text-muted">{s.description}</p>
                <p className="mt-0.5 text-xs text-muted">
                  {s.is_default ? '默认皮肤 · 免费' : `${s.price} 分`}
                  {s.owned && !s.current && ' · 已拥有'}
                  {s.trial_active && (
                    <span className="text-amber-600">
                      {' '}
                      · 试用中，剩 {trialLeft(s.trial_hours_left)}
                    </span>
                  )}
                </p>
              </div>

              {/* 主操作在上、次要操作在下（文字链），一行塞两个按钮在小屏上会挤 */}
              <div className="flex shrink-0 flex-col items-end gap-1">
                {s.trial_active ? (
                  // 试用中：主按钮变成"兑换保留"，点了就正式拥有并顺势结束试用
                  <Button
                    size="sm"
                    disabled={busyId === s.id || !affordable}
                    onClick={() => onRedeem(s)}
                  >
                    {busyId === s.id ? '兑换中…' : affordable ? '兑换保留' : `差 ${s.price - balance}`}
                  </Button>
                ) : s.current ? (
                  <span className="rounded-full bg-surface2 px-3 py-2 text-sm font-medium text-muted">
                    使用中
                  </span>
                ) : s.owned ? (
                  <Button size="sm" disabled={busyId === s.id} onClick={() => onUse(s)}>
                    {busyId === s.id ? '切换中…' : '使用'}
                  </Button>
                ) : (
                  <Button
                    size="sm"
                    disabled={busyId === s.id || !affordable}
                    onClick={() => onRedeem(s)}
                  >
                    {busyId === s.id ? '兑换中…' : affordable ? '兑换' : `差 ${s.price - balance}`}
                  </Button>
                )}

                {s.trial_active ? (
                  <button
                    type="button"
                    disabled={busyId !== null}
                    onClick={onEndTrial}
                    className="text-xs font-medium text-primary underline-offset-2 disabled:opacity-40 active:underline"
                  >
                    {busyId === END_TRIAL_BUSY ? '结束中…' : '结束试用'}
                  </button>
                ) : (
                  // 已经有别的皮肤在试用时干脆不给入口：后端会拒（SKIN_TRIAL_ACTIVE），
                  // 但与其点了才报错，不如直接不显示；想换先「结束试用」
                  s.can_trial &&
                  !trialing && (
                    <button
                      type="button"
                      disabled={busyId !== null}
                      onClick={() => onTrial(s)}
                      className="text-xs font-medium text-primary underline-offset-2 disabled:opacity-40 active:underline"
                    >
                      {busyId === s.id ? '试用中…' : '试用 1 天'}
                    </button>
                  )
                )}
              </div>
            </div>
          </div>
        )
      })}

      <SkinPriceSheet open={priceOpen} onClose={() => setPriceOpen(false)} />
    </div>
  )
}
