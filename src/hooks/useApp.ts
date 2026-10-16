import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useMemo } from 'react'
import * as api from '@/api'
import { monthGrid, type Ymd } from '@/lib/date'
import { useSession } from '@/store/session'
import type { CalendarEntry, Member, RetroCardKind } from '@/types/db'

export const qk = {
  bootstrap: ['bootstrap'] as const,
  calendar: (from: Ymd, to: Ymd, m: string | null) => ['calendar', from, to, m] as const,
  ledger: (m: string) => ['ledger', m] as const,
  badges: (m: string) => ['badges', m] as const,
  shop: ['shop'] as const,
  redemptions: (m: string | null) => ['redemptions', m] as const,
  tasks: (m: string | null) => ['tasks', m] as const,
  /** 签到卡：当天三态 + 三条连续链 + 补签卡库存 */
  signin: (m: string | null) => ['signin', m] as const,
  /** 家长的勋章管理列表（与孩子的勋章墙 badges 分开，失效互不影响） */
  familyBadges: ['familyBadges'] as const,
  /** 满星挑战（016）：进度 + 可开规格 + 商城补满星卡 */
  challenge: ['challenge'] as const,
  /** 皮肤商店（019）：列表带 owned/current/price，按 viewing 成员查 */
  skins: (m: string | null) => ['skins', m] as const,
  /** 家长皮肤定价（019）：基础价 + 家庭生效价 */
  skinsFamily: ['skinsFamily'] as const,
}

/**
 * 家长令牌只在内存里（铁律 6），过期就当没有。
 * 014 起它已经不是必需品：后端只看 role='parent'，没 token 也放行。
 * 保留这层是为了"曾经输过 PIN 的会话"继续带着有效 token 走严格分支。
 */
function parentToken(): string | null {
  return useSession.getState().validParentToken()
}

/** 启动状态。它是所有页面的地基，拿不到就什么都别渲染 */
export function useBootstrap() {
  return useQuery({
    queryKey: qk.bootstrap,
    queryFn: api.bootstrap,
    staleTime: 30_000,
  })
}

/** 当前登录的这个人 */
export function useMe(): Member | null {
  const { data } = useBootstrap()
  if (!data?.in_family || !data.me_id) return null
  return data.members?.find((m) => m.id === data.me_id) ?? null
}

/**
 * 当前"正在看谁"。
 * 家长可以切到任一孩子；孩子永远只能是自己 —— 这在 UI 上就不给入口，
 * 真正的防线在 RLS。
 */
export function useViewingMember(): Member | null {
  const { data } = useBootstrap()
  const me = useMe()
  const viewingId = useSession((s) => s.viewingMemberId)

  return useMemo(() => {
    if (!me) return null
    if (me.role !== 'parent') return me
    if (!viewingId) {
      // 家长默认看第一个孩子，没有孩子就看自己
      return data?.members?.find((m) => m.role === 'child') ?? me
    }
    return data?.members?.find((m) => m.id === viewingId) ?? me
  }, [data?.members, me, viewingId])
}

export function useCalendar(from: Ymd, to: Ymd, memberId?: string | null) {
  return useQuery({
    queryKey: qk.calendar(from, to, memberId ?? null),
    queryFn: () => api.getCalendar(from, to, memberId),
    staleTime: 5_000,
  })
}

/** 月视图：一次性把整个网格（含上下月补白）的数据取回来，翻月不闪 */
export function useMonthCalendar(anchor: Ymd, memberId?: string | null) {
  const grid = useMemo(() => monthGrid(anchor), [anchor])
  const q = useCalendar(grid.from, grid.to, memberId)

  const byDate = useMemo(() => {
    const map = new Map<Ymd, CalendarEntry[]>()
    for (const e of q.data ?? []) {
      const arr = map.get(e.occurrence_date)
      if (arr) arr.push(e)
      else map.set(e.occurrence_date, [e])
    }
    return map
  }, [q.data])

  return { ...q, grid, byDate }
}

export function useLedger(memberId: string | null) {
  return useQuery({
    queryKey: qk.ledger(memberId ?? ''),
    queryFn: () => api.getLedger(memberId!),
    enabled: !!memberId,
  })
}

export function useBadges(memberId: string | null) {
  return useQuery({
    queryKey: qk.badges(memberId ?? ''),
    queryFn: () => api.listBadges(memberId!),
    enabled: !!memberId,
  })
}

/** 勋章墙（带进度）。元素形状见 types/db.ts 的 BadgeProgress */
export function useBadgesWithProgress(memberId: string | null) {
  return useQuery({
    queryKey: qk.badges(memberId ?? ''),
    queryFn: () => api.listBadgesWithProgress(memberId!),
    enabled: !!memberId,
  })
}

/** 签到卡的数据源。memberId 为空时不发请求（地基还没到位） */
export function useSigninSummary(memberId: string | null) {
  return useQuery({
    queryKey: qk.signin(memberId ?? ''),
    queryFn: () => api.getSigninSummary(memberId!),
    enabled: !!memberId,
    staleTime: 5_000,
  })
}

/** 家长的勋章管理列表 */
export function useFamilyBadges() {
  return useQuery({
    queryKey: qk.familyBadges,
    queryFn: () => api.listFamilyBadges(parentToken()),
  })
}

export function useShop() {
  return useQuery({ queryKey: qk.shop, queryFn: api.listRewardItems })
}

export function useRedemptions(memberId: string | null) {
  return useQuery({
    queryKey: qk.redemptions(memberId),
    queryFn: () => api.listRedemptions(memberId),
  })
}

/** 家长拉取待批请假申请（015 流程，并入审批中心）。 */
export function useSkipRequests() {
  return useQuery({
    queryKey: ['skipRequests'],
    queryFn: () => api.listSkipRequests(),
  })
}

/**
 * 做任务的四个动作共用一套失效逻辑。
 * 一次操作可能同时改变日历、余额、勋章 —— 少刷一个界面就对不上。
 */
export function useTaskActions() {
  const qc = useQueryClient()

  const invalidate = useCallback(() => {
    qc.invalidateQueries({ queryKey: ['calendar'] })
    qc.invalidateQueries({ queryKey: ['ledger'] })
    qc.invalidateQueries({ queryKey: ['badges'] })
    // 活跃 / 满星是"完成任务"这一下才变的：不刷它，孩子做完任务
    // 签到卡上的「活跃」还是灰的，连续天数也停在昨天
    qc.invalidateQueries({ queryKey: ['signin'] })
    // 满星是挑战的计分依据（016）：不刷挑战，进度条会停在昨天
    qc.invalidateQueries({ queryKey: qk.challenge })
    qc.invalidateQueries({ queryKey: qk.bootstrap })
  }, [qc])

  const checkin = useMutation({
    mutationFn: (v: { taskId: string; date: Ymd }) => api.checkin(v.taskId, v.date),
    onSuccess: invalidate,
  })
  const complete = useMutation({
    mutationFn: (v: { taskId: string; date: Ymd }) => api.complete(v.taskId, v.date),
    onSuccess: invalidate,
  })
  const uncomplete = useMutation({
    mutationFn: (v: { taskId: string; date: Ymd }) => api.uncomplete(v.taskId, v.date),
    onSuccess: invalidate,
  })
  const skip = useMutation({
    mutationFn: (v: { taskId: string; date: Ymd }) => api.skip(v.taskId, v.date),
    onSuccess: invalidate,
  })
  const requestSkip = useMutation({
    mutationFn: (v: { taskId: string; date: Ymd }) => api.requestSkip(v.taskId, v.date),
    onSuccess: () => {
      // 请假申请不改变 occurrence，无需刷日历；只刷审批列表相关
      qc.invalidateQueries({ queryKey: ['skipRequests'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
  const completeAll = useMutation({
    mutationFn: (v: { taskId: string; uptoDate?: Ymd | null }) =>
      api.completeAll(v.taskId, v.uptoDate),
    onSuccess: invalidate,
  })

  return { checkin, complete, uncomplete, skip, requestSkip, completeAll, invalidate }
}

export function useCreateTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: api.createTask,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['calendar'] })
      qc.invalidateQueries({ queryKey: ['tasks'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/** 家长编辑任务（含整组副本同步） */
export function useUpdateTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: api.updateTask,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['calendar'] })
      qc.invalidateQueries({ queryKey: ['tasks'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/** 删除任务：scope='once' 删某一次，scope='all' 软删整条（含同组副本） */
export function useDeleteTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: api.deleteTask,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['calendar'] })
      qc.invalidateQueries({ queryKey: ['tasks'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/** 皮肤商店（019）：孩子/家长都能看，带 owned/current/price。memberId 省略=自己 */
export function useSkins(memberId: string | null) {
  return useQuery({
    queryKey: qk.skins(memberId),
    queryFn: () => api.listSkins(memberId),
  })
}

/**
 * 当前正在使用的那张皮肤（含 theme.photo），日历页头图用。
 * 列表还没回来时返回 null，页面按需不渲染头图即可，不会闪。
 */
export function useCurrentSkin() {
  const me = useMe()
  const { data: skins } = useSkins(me?.id ?? null)
  const list = skins ?? []
  return list.find((s) => s.current) ?? null
}

/** 家长皮肤定价列表（019） */
export function useSkinsForFamily() {
  return useQuery({
    queryKey: qk.skinsFamily,
    queryFn: api.listSkinsForFamily,
  })
}

/** 兑换皮肤（019）。mutateAsync 收 skinId；成功后刷 skin 列表 + 余额 */
export function useRedeemSkin() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (skinId: string) => api.redeemSkin(skinId),
    onSuccess: () => {
      // 必须按前缀失效：列表的键是 ['skins', <memberId>]，而成员 id 是真实 uuid，
      // 失效 ['skins', null] 根本打不到它 —— 这正是兑换后列表不刷新的原因。
      qc.invalidateQueries({ queryKey: ['skins'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/** 切换皮肤（019）。mutateAsync 收 skinId；成功后刷 skin 列表 + bootstrap（selected_skin_id） */
export function useSetMemberSkin() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (skinId: string) => api.setMemberSkin(skinId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['skins'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/**
 * 试用皮肤 1 天（023）。mutateAsync 收 skinId。
 * 成功后列表里的 current 会指到试用中的皮肤，ThemeApplier 自动套用，
 * 到期后同一套逻辑自然回落到原来选中的皮肤。
 */
export function useStartSkinTrial() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (skinId: string) => api.startSkinTrial(skinId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['skins'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/** 提前结束试用（023），回到原来选中的皮肤 */
export function useEndSkinTrial() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => api.endSkinTrial(),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['skins'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/**
 * 家长皮肤定价（019）。mutateAsync 收 { skinId, pricePoints }
 * token 固定传 null：014 起 _parent_guard 没 token 时只看 role='parent' 就放行，
 * 这里若传会话里的旧 token 反而会走 require_parent 严格校验，一旦过期就被拒。
 */
export function useSetSkinPrice() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { skinId: string; pricePoints: number }) =>
      api.setSkinPrice(null, v.skinId, v.pricePoints),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.skinsFamily })
      // 家庭价变了，孩子侧 skin 列表的 price 也要刷新
      qc.invalidateQueries({ queryKey: ['skins'] })
    },
  })
}

export function useRedeem() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { itemId: string; quantity: number }) => api.redeem(v.itemId, v.quantity),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['ledger'] })
      qc.invalidateQueries({ queryKey: ['redemptions'] })
      qc.invalidateQueries({ queryKey: qk.shop })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/**
 * 签到一下会连带改：余额（+2 和连续奖励）、当天三态、连续天数、勋章进度。
 * 余额卡读的是 bootstrap.members[].points_balance，所以 bootstrap 必须一起刷 ——
 * 少了它就会出现"流水里有分、上面的数字没动"。
 */
function useSigninInvalidate() {
  const qc = useQueryClient()
  return useCallback(() => {
    qc.invalidateQueries({ queryKey: qk.bootstrap })
    qc.invalidateQueries({ queryKey: ['calendar'] })
    qc.invalidateQueries({ queryKey: ['ledger'] })
    qc.invalidateQueries({ queryKey: ['signin'] })
    qc.invalidateQueries({ queryKey: ['badges'] })
    qc.invalidateQueries({ queryKey: qk.challenge })
  }, [qc])
}

/** 每日签到。mutateAsync 收一个 'YYYY-MM-DD'，只能是今天 */
export function useSignin() {
  const invalidate = useSigninInvalidate()
  return useMutation({
    mutationFn: (date: Ymd) => api.doSignin(date),
    onSuccess: invalidate,
  })
}

/** 用补签卡。mutateAsync 收 { kind, date }，memberId 省略 = 自己 */
export function useRetroCard() {
  const invalidate = useSigninInvalidate()
  return useMutation({
    mutationFn: (v: { kind: RetroCardKind; date: Ymd; memberId?: string | null }) =>
      api.applyRetroCard(v.kind, v.date, v.memberId ?? null),
    onSuccess: invalidate,
  })
}

/** 满星挑战（016）：可开的挑战规格 + 当前挑战进度 + 商城补满星卡 */
export function useChallengeState() {
  return useQuery({
    queryKey: qk.challenge,
    queryFn: api.challengeState,
    staleTime: 5_000,
  })
}

/** 开启挑战。付入场分（后端扣），成功后刷新挑战 / 余额 / 流水 */
export function useStartChallenge() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (kind: api.ChallengeKind) => api.startChallenge(kind),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.challenge })
      qc.invalidateQueries({ queryKey: ['ledger'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/**
 * 失败预警后的补救：买一张"该类对应的补卡" + 立刻补在漏掉那天。
 * 两步都是既有能力（013 商城 redeem / 010 use_retro_card），这里只是串起来 ——
 * 补完那天对应维度（满星/签到/活跃）回升，挑战进度在下次读取时自动恢复可行。
 * 补卡类型按挑战类走：满星→retro_fullstar、签到→retro_signin、活跃→retro_active
 * （之前这里写死 retro_fullstar，签到/活跃类补救会补错维度，027 起按 kind 传入）。
 */
export function useRescueChallenge() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { itemId: string; day: Ymd; kind: RetroCardKind }) => {
      await api.redeem(v.itemId, 1)
      await api.applyRetroCard(v.kind, v.day)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.challenge })
      qc.invalidateQueries({ queryKey: ['signin'] })
      qc.invalidateQueries({ queryKey: ['ledger'] })
      qc.invalidateQueries({ queryKey: ['redemptions'] })
      qc.invalidateQueries({ queryKey: qk.bootstrap })
    },
  })
}

/** 家长手动调分。mutateAsync 收 { memberId, delta, reason }，delta 负数是扣除 */
export function useAdjust() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { memberId: string; delta: number; reason: string }) =>
      api.adjustPoints(v.memberId, v.delta, v.reason, parentToken()),
    onSuccess: () => {
      // 余额卡读 bootstrap，流水页读 ledger，「累计积分」类勋章读 badges
      qc.invalidateQueries({ queryKey: qk.bootstrap })
      qc.invalidateQueries({ queryKey: ['ledger'] })
      qc.invalidateQueries({ queryKey: ['badges'] })
    },
  })
}

/** 新建 / 修改家庭勋章。不带 id 是新建，带 id 是改 */
export function useUpsertBadge() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: Omit<api.UpsertBadgeInput, 'parentToken'>) =>
      api.upsertBadge({ ...v, parentToken: parentToken() }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.familyBadges })
      // 勋章墙按 viewing.id 缓存，这里不知道是谁，整棵 badges 一起失效
      qc.invalidateQueries({ queryKey: ['badges'] })
    },
  })
}

/** 删除家庭勋章。mutateAsync 收 badge id；系统内置勋章后端会拒 */
export function useDeleteBadge() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => api.deleteBadge(id, parentToken()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.familyBadges })
      qc.invalidateQueries({ queryKey: ['badges'] })
    },
  })
}

/** 家长调节现金兑换比率（多少积分换 1 元）。改完同步本家庭所有现金商品 */
export function useSetFamilySettings() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { cashRatePoints: number }) =>
      api.setFamilySettings(parentToken(), v.cashRatePoints),
    onSuccess: () => {
      // cash_rate_points 在 bootstrap.family 里，比率商品在 shop 里
      qc.invalidateQueries({ queryKey: qk.bootstrap })
      qc.invalidateQueries({ queryKey: qk.shop })
    },
  })
}

/** 家长调某一枚勋章的奖励分。家庭勋章改本体，系统勋章走覆盖值 */
export function useSetBadgeBonus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { badgeId: string; pointsBonus: number }) =>
      api.setBadgeBonus(parentToken(), v.badgeId, v.pointsBonus),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.familyBadges })
      qc.invalidateQueries({ queryKey: ['badges'] })
    },
  })
}
