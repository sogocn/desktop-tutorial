import { getBackend } from '@/lib/backend'
import type { Ymd } from '@/lib/date'
import type {
  ActionResult,
  AdjustResult,
  BadgeProgress,
  BadgeRule,
  BootstrapState,
  CalendarEntry,
  FamilyBadge,
  LedgerEntry,
  Recurrence,
  RetroCardKind,
  RetroCardResult,
  SigninResult,
  SigninSummary,
  Task,
} from '@/types/db'

// 这一层只做一件事：把 SQL 函数的参数名和前端的驼峰隔开。
// 参数名写错了 TS 不会报错（是运行时拼的 SQL），所以只在这里出现一次。

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const be = await getBackend()
  return be.rpc<T>(fn, args)
}

async function query<T>(sql: string, params: unknown[] = []): Promise<T[]> {
  const be = await getBackend()
  return be.query<T>(sql, params)
}

/** 切换当前身份。传 null = 变成"游客" */
export async function setIdentity(userId: string | null) {
  const be = await getBackend()
  await be.setIdentity(userId)
}

/** 用户名 + PIN 登录。返回该成员的 userId / token / nickname / role */
export interface LoginResult {
  userId: string
  token: string
  nickname: string
  role: 'parent' | 'child'
}
export const login = (username: string, pin: string) =>
  getBackend().then((be) => be.login(username.trim(), pin))

// ---------------------------------------------------------------------------
// 启动 / 家庭
// ---------------------------------------------------------------------------
export const bootstrap = () => rpc<BootstrapState>('bootstrap_state')

export const createFamily = (p: {
  familyName: string
  nickname: string
  username: string
  pin: string
  avatar?: string
  timezone?: string
}) =>
  rpc<{
    family_id: string
    member_id: string
    user_id: string
    child_invite_code: string
    parent_invite_code: string
  }>('create_family', {
    p_family_name: p.familyName,
    p_nickname: p.nickname,
    p_username: p.username.trim().toLowerCase(),
    p_pin: p.pin,
    p_avatar: p.avatar ?? '🙂',
    p_timezone: p.timezone ?? 'Asia/Shanghai',
  })

export const joinFamily = (p: {
  code: string
  username: string
  pin: string
  nickname?: string
  avatar?: string
}) =>
  rpc<{ member_id: string; family_id: string; role: 'parent' | 'child'; username?: string }>(
    'join_family',
    {
      p_code: p.code.trim().toUpperCase(),
      p_username: p.username.trim().toLowerCase(),
      p_pin: p.pin,
      p_nickname: p.nickname ?? null,
      p_avatar: p.avatar ?? '🙂',
    },
  )

export const addMember = (p: {
  nickname: string
  avatar: string
  role: 'parent' | 'child'
  parentToken: string
}) =>
  rpc<{ member_id: string; user_id: string; claim_code: string }>('add_member', {
    p_nickname: p.nickname,
    p_avatar: p.avatar,
    p_role: p.role,
    p_parent_token: p.parentToken,
  })

// ---------------------------------------------------------------------------
// 家长 PIN
// ---------------------------------------------------------------------------
export const setPin = (pin: string, oldPin?: string | null) =>
  rpc<boolean>('set_pin', { p_pin: pin, p_old_pin: oldPin ?? null })

export const verifyPin = (pin: string, memberId?: string | null) =>
  rpc<{ token: string; member_id: string; expires_at: string }>('verify_parent_pin', {
    p_pin: pin,
    p_member_id: memberId ?? null,
  })

// ---------------------------------------------------------------------------
// 日历
// ---------------------------------------------------------------------------
export const getCalendar = (from: Ymd, to: Ymd, memberId?: string | null) =>
  query<CalendarEntry>('select * from app.get_calendar($1::date, $2::date, $3::uuid)', [
    from,
    to,
    memberId ?? null,
  ])

export const getToday = () => query<{ d: Ymd }>('select app.today() as d').then((r) => r[0].d)

// ---------------------------------------------------------------------------
// 任务
// ---------------------------------------------------------------------------
export interface CreateTaskInput {
  /** 多选指派人：为每个孩子各建一份独立任务副本 */
  assigneeIds: string[]
  title: string
  iconEmoji?: string
  color?: string
  scheduleKind?: 'once' | 'recurring'
  recurrence?: Recurrence
  startsOn?: Ymd | null
  endsOn?: Ymd | null
  maxOccurrences?: number | null
  windowStart?: string | null
  windowEnd?: string | null
  dueTime?: string | null
  isDeadline?: boolean
  checkinPoints?: number
  checkinLimit?: number
  completionPoints?: number
}

export const createTask = (p: CreateTaskInput) =>
  rpc<{ task_ids: string[]; group_id: string | null; starts_on: Ymd }>('create_task', {
    p_assignee_ids: p.assigneeIds,
    p_title: p.title,
    p_icon_emoji: p.iconEmoji ?? '⭐',
    p_color: p.color ?? 'sky',
    p_schedule_kind: p.scheduleKind ?? 'once',
    p_recurrence: p.recurrence ?? { freq: 'once' },
    p_starts_on: p.startsOn ?? null,
    p_ends_on: p.endsOn ?? null,
    p_max_occurrences: p.maxOccurrences ?? null,
    p_window_start: p.windowStart ?? null,
    p_window_end: p.windowEnd ?? null,
    p_due_time: p.dueTime ?? null,
    p_is_deadline: p.isDeadline ?? false,
    p_checkin_points: p.checkinPoints ?? 0,
    p_checkin_limit: p.checkinLimit ?? 1,
    p_completion_points: p.completionPoints ?? 0,
  })

export interface UpdateTaskInput {
  taskId: string
  title?: string
  iconEmoji?: string
  color?: string
  scheduleKind?: 'once' | 'recurring'
  recurrence?: Recurrence
  startsOn?: Ymd | null
  endsOn?: Ymd | null
  windowStart?: string | null
  windowEnd?: string | null
  dueTime?: string | null
  isDeadline?: boolean
  checkinPoints?: number
  checkinLimit?: number
  completionPoints?: number
}

export const updateTask = (p: UpdateTaskInput) =>
  rpc<{ task_id: string; updated: boolean }>('update_task', {
    p_task_id: p.taskId,
    p_title: p.title ?? null,
    p_icon_emoji: p.iconEmoji ?? null,
    p_color: p.color ?? null,
    p_schedule_kind: p.scheduleKind ?? null,
    p_recurrence: p.recurrence ?? null,
    p_starts_on: p.startsOn ?? null,
    p_ends_on: p.endsOn ?? null,
    p_window_start: p.windowStart ?? null,
    p_window_end: p.windowEnd ?? null,
    p_due_time: p.dueTime ?? null,
    p_is_deadline: p.isDeadline ?? null,
    p_checkin_points: p.checkinPoints ?? null,
    p_checkin_limit: p.checkinLimit ?? null,
    p_completion_points: p.completionPoints ?? null,
  })

export const deleteTask = (p: { taskId: string; scope: 'once' | 'all'; date?: Ymd | null }) =>
  rpc<{ task_id: string; scope: string; group_id?: string | null }>('delete_task', {
    p_task_id: p.taskId,
    p_scope: p.scope,
    p_date: p.date ?? null,
  })

export const getTask = (id: string) =>
  query<Task>('select * from app.tasks where id = $1', [id]).then((r) => r[0] ?? null)

export const listTasks = (memberId?: string | null) =>
  query<Task>(
    `select * from app.tasks
      where archived_at is null and ($1::uuid is null or assignee_id = $1::uuid)
      order by created_at desc`,
    [memberId ?? null],
  )

/** 归档 = 软删。历史实例仍留在日历上（灰色），孩子挣过的分不会凭空消失 */
export const archiveTask = (id: string) =>
  query('update app.tasks set archived_at = now() where id = $1', [id])

// ---------------------------------------------------------------------------
// 做任务
// ---------------------------------------------------------------------------
export const checkin = (taskId: string, date: Ymd, note?: string) =>
  rpc<ActionResult>('record_checkin', { p_task_id: taskId, p_date: date, p_note: note ?? null })

export const complete = (taskId: string, date: Ymd, note?: string) =>
  rpc<ActionResult>('complete_occurrence', {
    p_task_id: taskId,
    p_date: date,
    p_note: note ?? null,
  })

export const uncomplete = (taskId: string, date: Ymd) =>
  rpc<ActionResult>('uncomplete_occurrence', { p_task_id: taskId, p_date: date })

export const skip = (taskId: string, date: Ymd, note?: string) =>
  rpc<ActionResult>('skip_occurrence', { p_task_id: taskId, p_date: date, p_note: note ?? null })

// ---------------------------------------------------------------------------
// 钱包
// ---------------------------------------------------------------------------
export const getLedger = (memberId: string, limit = 60) =>
  query<LedgerEntry & { snap_title?: string }>(
    `select l.*, o.snap_title
       from app.point_ledger l
       left join app.task_occurrences o on o.id = l.source_id
      where l.member_id = $1
      order by l.created_at desc
      limit $2`,
    [memberId, limit],
  )

export interface RewardItem {
  id: string
  name: string
  emoji: string
  description: string | null
  pricing_mode: 'fixed' | 'rate'
  price_points: number | null
  rate_points: number | null
  unit_label: string | null
  min_quantity: number
  step_quantity: number
  stock: number | null
  requires_approval: boolean
}

export const listRewardItems = () =>
  query<RewardItem>(
    'select * from app.reward_items where active order by sort_order, created_at',
  )

export const redeem = (itemId: string, quantity = 1, note?: string) =>
  rpc<{
    redemption_id: string
    points_spent: number
    balance: number
    pending: boolean
    message: string
  }>('redeem', { p_item_id: itemId, p_quantity: quantity, p_note: note ?? null })

export interface Redemption {
  id: string
  member_id: string
  quantity: number
  points_cost: number
  snap_name: string
  snap_emoji: string
  status: 'pending' | 'approved' | 'rejected' | 'delivered' | 'cancelled'
  requested_at: string
  note: string | null
}

export const listRedemptions = (memberId?: string | null) =>
  query<Redemption>(
    `select * from app.redemptions
      where ($1::uuid is null or member_id = $1::uuid)
      order by requested_at desc limit 50`,
    [memberId ?? null],
  )

export const decideRedemption = (id: string, decision: string, parentToken: string) =>
  rpc<{ redemption_id: string; status: string; balance: number }>('decide_redemption', {
    p_redemption_id: id,
    p_decision: decision,
    p_parent_token: parentToken,
  })

/**
 * 家长手动调分。delta 正数是打赏、负数是扣除，一样只追加流水。
 * parentToken 传 null 也能过 —— 没设 PIN 的家庭本来就拿不到 token，
 * 后端 _parent_guard 会按"设过 PIN 就必须验"来判。
 */
export const adjustPoints = (
  memberId: string,
  delta: number,
  reason: string,
  parentToken?: string | null,
) =>
  rpc<AdjustResult>('adjust_member_points', {
    p_parent_token: parentToken ?? null,
    p_member_id: memberId,
    p_delta: delta,
    p_reason: reason,
  })

// ---------------------------------------------------------------------------
// 签到 / 连续 / 补签卡
// ---------------------------------------------------------------------------
/** 只能签今天。补以前的日子要用补签卡（后端会拦） */
export const doSignin = (date: Ymd) => rpc<SigninResult>('do_signin', { p_date: date })

export const getSigninSummary = (memberId: string) =>
  rpc<SigninSummary>('get_signin_summary', { p_member_id: memberId })

/**
 * 用一张补签卡把某天的签到 / 活跃 / 满星补上。
 * memberId 省略 = 自己；家长可以替孩子用。
 */
export const applyRetroCard = (kind: RetroCardKind, date: Ymd, memberId?: string | null) =>
  rpc<RetroCardResult>('use_retro_card', {
    p_kind: kind,
    p_date: date,
    p_member_id: memberId ?? null,
  })

// ---------------------------------------------------------------------------
// 勋章管理（家长）
// ---------------------------------------------------------------------------
export interface UpsertBadgeInput {
  /** 不传 = 新建，传了 = 改这一枚 */
  id?: string | null
  name: string
  emoji?: string
  tier?: string
  description?: string | null
  rule: BadgeRule
  sortOrder?: number
  parentToken?: string | null
}

export const upsertBadge = (p: UpsertBadgeInput) =>
  rpc<string>('upsert_badge', {
    p_parent_token: p.parentToken ?? null,
    p_id: p.id ?? null,
    p_name: p.name,
    p_emoji: p.emoji ?? '🏅',
    p_tier: p.tier ?? 'bronze',
    p_description: p.description ?? null,
    p_rule: p.rule,
    p_sort_order: p.sortOrder ?? 0,
  })

export const deleteBadge = (id: string, parentToken?: string | null) =>
  rpc<{ deleted: number }>('delete_badge', {
    p_id: id,
    p_parent_token: parentToken ?? null,
  })

export const listFamilyBadges = (parentToken?: string | null) =>
  rpc<FamilyBadge[]>('list_family_badges', { p_parent_token: parentToken ?? null })

// ---------------------------------------------------------------------------
// 勋章
// ---------------------------------------------------------------------------
/**
 * 勋章墙。先在后端评估一遍再返回，保证进度和刚做完的动作对得上。
 * 元素形状见 BadgeProgress（注意主键字段叫 badge_id，id 也一并给了）。
 */
export const listBadgesWithProgress = (memberId: string) =>
  rpc<BadgeProgress[]>('list_badges_with_progress', { p_member_id: memberId })

/**
 * 旧名字，保留给还没换过来的调用方。
 * 原来那句手写 SQL 读的是 mb.earned_at —— 表里其实叫 awarded_at，一调就报错，
 * 顺手指到新函数上，字段是超集（多了 progress / threshold / earned）。
 */
export const listBadges = listBadgesWithProgress
