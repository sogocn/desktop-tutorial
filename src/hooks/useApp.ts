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
}

/**
 * 家长令牌只在内存里（铁律 6），过期就当没有。
 * 这里不抛错：没设 PIN 的家庭本来就拿不到 token，让后端 _parent_guard 去判 ——
 * 判断规则只写一处，前端跟着走。
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
  const completeAll = useMutation({
    mutationFn: (v: { taskId: string; uptoDate?: Ymd | null }) =>
      api.completeAll(v.taskId, v.uptoDate),
    onSuccess: invalidate,
  })

  return { checkin, complete, uncomplete, skip, completeAll, invalidate }
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
