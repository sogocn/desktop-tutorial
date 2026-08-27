/**
 * 勋章规则的前端元数据。
 *
 * 规则本体存在数据库里是一坨 jsonb，后端只认 kind / dimension / threshold 三个键。
 * 这个文件负责两件事：给家长的表单提供可选项，以及把 jsonb 翻回一句人话。
 * 纯逻辑无 React —— 放这里而不是组件文件里，是为了让勋章墙和管理抽屉共用同一套
 * 文案，避免"管理页写连续活跃 7 天、勋章墙写活跃连续 7 天"这种不一致。
 */

export type RuleKind =
  | 'streak_days'
  | 'total_completions'
  | 'total_points'
  | 'total_signin'
  | 'total_active'
  | 'total_fullstar'

export type RuleDimension = 'signin' | 'active' | 'fullstar'

export const RULE_KINDS: { key: RuleKind; label: string; unit: string }[] = [
  { key: 'streak_days', label: '连续天数', unit: '天' },
  { key: 'total_completions', label: '累计完成任务', unit: '个' },
  { key: 'total_points', label: '累计积分', unit: '分' },
  { key: 'total_signin', label: '累计签到', unit: '天' },
  { key: 'total_active', label: '累计活跃', unit: '天' },
  { key: 'total_fullstar', label: '累计满星', unit: '天' },
]

export const RULE_DIMENSIONS: { key: RuleDimension; label: string }[] = [
  { key: 'signin', label: '签到' },
  { key: 'active', label: '活跃' },
  { key: 'fullstar', label: '满星' },
]

export const BADGE_TIERS: { key: string; label: string; emoji: string }[] = [
  { key: 'bronze', label: '铜', emoji: '🥉' },
  { key: 'silver', label: '银', emoji: '🥈' },
  { key: 'gold', label: '金', emoji: '🥇' },
  { key: 'special', label: '特别', emoji: '✨' },
]

/**
 * jsonb / numeric 过来的数字可能是字符串，统一收一下。
 * 少了这层，"连续 7 天"会变成 "连续 NaN 天"。
 */
export function toNum(v: unknown): number {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

/** 等级对应的描边色。Tailwind 要静态类名，所以只能写全，不能拼字符串 */
export function tierRing(tier: string | null | undefined): string {
  switch (tier) {
    case 'gold':
      return 'ring-amber-300'
    case 'silver':
      return 'ring-slate-300'
    case 'bronze':
      return 'ring-orange-300'
    case 'special':
      return 'ring-violet-300'
    default:
      return 'ring-slate-200/60'
  }
}

export function tierLabel(tier: string | null | undefined): string {
  return BADGE_TIERS.find((t) => t.key === tier)?.label ?? ''
}

/** 把 jsonb 规则翻成一句人话。管理列表和勋章墙共用 */
export function ruleSummary(rule: unknown): string {
  const r = (rule ?? {}) as Record<string, unknown>
  const kind = String(r.kind ?? '')
  const threshold = toNum(r.threshold)
  const meta = RULE_KINDS.find((k) => k.key === kind)
  if (!meta) return '未设置达成条件'
  if (kind === 'streak_days') {
    const dim = String(r.dimension ?? 'signin')
    const dimLabel = RULE_DIMENSIONS.find((d) => d.key === dim)?.label ?? dim
    return `连续${dimLabel} ${threshold} 天`
  }
  return `${meta.label} ${threshold} ${meta.unit}`
}

/** 表单拼出的 rule 对象。streak_days 多带一个维度，其余只有阈值 */
export function buildRule(
  kind: RuleKind,
  threshold: number,
  dimension: RuleDimension,
): Record<string, unknown> {
  return kind === 'streak_days' ? { kind, dimension, threshold } : { kind, threshold }
}
