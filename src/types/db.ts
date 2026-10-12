import type { Ymd } from '@/lib/date'

export type Role = 'parent' | 'child'
export type OccurrenceStatus = 'pending' | 'completed' | 'skipped' | 'missed'
export type TaskColor = 'sky' | 'violet' | 'emerald' | 'amber' | 'rose' | 'slate'

export interface Family {
  id: string
  name: string
  timezone: string
  day_cutoff_hour: number
  child_task_points_policy: 'free' | 'capped' | 'zero'
  child_task_points_cap: number
  child_daily_points_cap: number
  /** 多少积分换 1 元（现金商品按这个比率走）。家长可在「家长设置」里调 */
  cash_rate_points: number
}

export interface Member {
  id: string
  family_id: string
  user_id: string | null
  nickname: string
  role: Role
  avatar_emoji: string
  points_balance: number
  has_pin: boolean
  /** 当前使用的皮肤。null = 用默认皮肤。019 皮肤系统新增 */
  selected_skin_id?: string | null
  /** 正在试用的皮肤（023）。null = 没在试用 */
  trial_skin_id?: string | null
  /** 试用到期时间（023）。过期后自动回落到 selected_skin_id */
  trial_until?: string | null
  /** 今天的签到 / 活跃 / 满星。bootstrap_state 附带，老数据可能缺 */
  signed_today?: boolean
  active_today?: boolean
  fullstar_today?: boolean
}

/** 皮肤的配色（019）。前端直接读这些键套到 CSS 变量上 */
/** 皮肤 key。前端按它挑专属图标 / 背景图，和 skins.key 对齐 */
export type SkinKey = 'default' | 'eye_care' | 'pokemon' | 'line_dog' | 'hp_hermione'

export interface SkinTheme {
  bg: string
  surface: string
  surface2: string
  primary: string
  primaryHover: string
  onPrimary: string
  onPrimaryMuted: string
  text: string
  muted: string
  border: string
  navBg: string
  accent: string
  /** 背景图案 key：poke_dots / dog_lines / hp_stars，null = 无 */
  pattern: string | null
  /**
   * 皮肤专属大图（相对站点根的路径，如 '/skins/pokemon.png'）。
   * 用来做全局背景底图 + 日历页头图。文件不存在时这层会被浏览器忽略，
   * 自动退化成上面的 pattern，不会有副作用。
   */
  photo?: string | null
  /**
   * 头图横幅（如 '/skins/pokemon.webp'）。3:1 宽幅，用于日历页 / 今天页顶部。
   * 用 <img> 按原比例整张渲染，不走 background-size:cover，
   * 所以角色等主体不会被裁掉。没配就不渲染。
   */
  banner?: string | null
}

/** app.list_skins() 的一个元素。孩子/家长都能看 */
export interface Skin {
  id: string
  key: string
  name: string
  emoji: string
  description: string | null
  is_default: boolean
  theme: SkinTheme
  /** 当前家庭实际生效价（基础价或家长覆盖价） */
  price: number
  /** 是否已拥有（默认皮肤永远 true） */
  owned: boolean
  /** 是否当前正在使用（口径是"生效皮肤"：试用中的那张才算 current） */
  current: boolean
  /** 能否试用 1 天（付费 + 未拥有 + 本成员没试过） */
  can_trial: boolean
  /** 这张皮当前正在试用中 */
  trial_active: boolean
  /** 试用到期时间（ISO）；不试用为 null */
  trial_ends_at: string | null
  /** 试用剩余小时数；不在试用中为 null */
  trial_hours_left: number | null
}

/** app.list_skins_for_family() 的一个元素。家长定价用 */
export interface SkinForFamily {
  id: string
  key: string
  name: string
  emoji: string
  description: string | null
  is_default: boolean
  /** 系统基础价（皮肤本体，定价不改它） */
  base_price: number
  /** 家庭当前生效价（家长覆盖过则 ≠ base_price） */
  price: number
}

export interface Invite {
  id: string
  code: string
  role: Role
  member_id: string | null
  used_count: number
  max_uses: number
}

export interface BootstrapState {
  in_family: boolean
  today?: Ymd
  me_id?: string
  family?: Family
  members?: Member[]
  invites?: Invite[]
}

/** app.get_calendar() 的一行 */
export interface CalendarEntry {
  task_id: string
  occurrence_id: string | null
  occurrence_date: Ymd
  assignee_id: string
  title: string
  icon_emoji: string
  color: TaskColor
  status: OccurrenceStatus
  checkin_points: number
  completion_points: number
  checkin_count: number
  checkin_daily_limit: number
  window_start_time: string | null
  window_end_time: string | null
  due_time: string | null
  is_deadline_style: boolean
  archived: boolean
  is_virtual: boolean
  schedule_kind: 'once' | 'recurring'
}

export interface Task {
  id: string
  family_id: string
  assignee_id: string
  created_by: string
  title: string
  notes: string | null
  icon_emoji: string
  color: TaskColor
  schedule_kind: 'once' | 'recurring'
  recurrence: Recurrence
  starts_on: Ymd
  ends_on: Ymd | null
  max_occurrences: number | null
  window_start_time: string | null
  window_end_time: string | null
  due_time: string | null
  is_deadline_style: boolean
  checkin_points: number
  checkin_daily_limit: number
  completion_points: number
  version: number
  archived_at: string | null
}

export interface LedgerEntry {
  id: string
  member_id: string
  delta: number
  balance_after: number | null
  entry_kind: 'primary' | 'reversal'
  source_type: string
  source_id: string | null
  reverses_id: string | null
  reason: string | null
  capped_from: number | null
  occurrence_date: Ymd | null
  created_at: string
}

export type Recurrence =
  | { freq: 'once'; date: Ymd }
  | { freq: 'daily' }
  | { freq: 'weekly'; byweekday: number[] }
  | { freq: 'monthly'; bymonthday: number[]; month_overflow?: 'skip' | 'last_day' }

export interface ActionResult {
  occurrence_id: string
  points_awarded?: number
  capped_from?: number | null
  balance: number
  already?: boolean
  seq?: number
}

// ---------------------------------------------------------------------------
// 签到 / 连续 / 补签卡
// ---------------------------------------------------------------------------
export type StreakKind = 'signin' | 'active' | 'fullstar'
export type RetroCardKind = 'retro_signin' | 'retro_active' | 'retro_fullstar'

/** 三个维度共用同一个形状：连续天数、累计天数都是它 */
export type StreakMap = Record<StreakKind, number>

/** app.get_signin_summary() 的返回。签到卡整块界面就靠它 */
export interface SigninSummary {
  member_id: string
  today: Ymd
  signed_today: boolean
  active_today: boolean
  fullstar_today: boolean
  streak: StreakMap
  totals: StreakMap
  retro_cards: Record<RetroCardKind, number>
  awarded_tiers: { kind: StreakKind; tier: number; points: number }[]
}

export interface SigninResult {
  signed: boolean
  already: boolean
  points_awarded: number
  balance: number
  summary: SigninSummary
}

export interface RetroCardResult {
  ok: boolean
  kind: RetroCardKind
  date: Ymd
  /** 用完这张之后还剩几张 */
  remaining: number
  balance: number
  summary: SigninSummary
}

export interface AdjustResult {
  member_id: string
  delta: number
  entry_id: string | null
  balance: number
}

// ---------------------------------------------------------------------------
// 勋章
// ---------------------------------------------------------------------------
/**
 * 解锁规则。后端只认 kind / threshold / dimension 三个键，
 * 这里故意放宽成 Record —— 表单是动态拼出来的，收紧了只会让调用方到处 as。
 */
export type BadgeRule = Record<string, unknown>

/** app.list_badges_with_progress() 的一个元素。progress 已按 threshold 截断 */
export interface BadgeProgress {
  id: string
  badge_id: string
  code: string
  name: string
  emoji: string
  tier: string
  description: string | null
  rule: BadgeRule | null
  kind: string
  dimension: string | null
  progress: number
  /** 未截断的真实进度，用来显示"30/7"这种超额完成 */
  raw_progress: number
  threshold: number
  earned: boolean
  earned_at: string | null
  is_system: boolean
  /** 首次获得这枚勋章时额外发的积分（家长可调，系统勋章可被家庭覆盖） */
  points_bonus: number
}

/** app.list_family_badges() 的一个元素。系统内置勋章 is_system=true，不可改删 */
export interface FamilyBadge {
  id: string
  code: string
  name: string
  emoji: string
  tier: string
  description: string | null
  rule: BadgeRule | null
  sort_order: number
  is_system: boolean
  earned_count: number
  /** 系统勋章的家庭覆盖值；家庭自建勋章=本体值。家长看这俩决定可选范围 */
  base_bonus: number
  /** 当前家庭实际生效的奖励分（系统勋章取覆盖值，家庭勋章取本体值） */
  points_bonus: number
}
