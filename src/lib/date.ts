/**
 * 业务日期一律用 'YYYY-MM-DD' 字符串表示，绝不转成 Date。
 *
 * 为什么这么轴：new Date('2026-08-12') 在浏览器里被解析成 UTC 午夜，
 * 在东八区取 getDate() 拿到的还是 12 号没错，但一旦有人用了本地时区构造，
 * 或者用户在西半球，就会稳定地差一天。日历应用差一天等于全盘错误。
 *
 * 内部计算全部走 Date.UTC + getUTC*，Date 对象不出这个文件。
 */
export type Ymd = string

const pad = (n: number) => String(n).padStart(2, '0')

function toUtc(s: Ymd): Date {
  const [y, m, d] = s.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d))
}

function fromUtc(dt: Date): Ymd {
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`
}

export function isYmd(s: unknown): s is Ymd {
  return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s)
}

export function addDays(s: Ymd, n: number): Ymd {
  const dt = toUtc(s)
  dt.setUTCDate(dt.getUTCDate() + n)
  return fromUtc(dt)
}

export function addMonths(s: Ymd, n: number): Ymd {
  const [y, m] = s.split('-').map(Number)
  const total = y * 12 + (m - 1) + n
  return `${Math.floor(total / 12)}-${pad((total % 12) + 1)}-01`
}

export function diffDays(a: Ymd, b: Ymd): number {
  return Math.round((toUtc(a).getTime() - toUtc(b).getTime()) / 86400000)
}

/** ISO 星期：1=周一 … 7=周日，和数据库里的 byweekday 编号一致 */
export function isoWeekday(s: Ymd): number {
  const w = toUtc(s).getUTCDay()
  return w === 0 ? 7 : w
}

export function dayOfMonth(s: Ymd): number {
  return Number(s.slice(8, 10))
}

export function monthOf(s: Ymd): string {
  return s.slice(0, 7)
}

export function startOfMonth(s: Ymd): Ymd {
  return `${s.slice(0, 7)}-01`
}

export function endOfMonth(s: Ymd): Ymd {
  return addDays(addMonths(startOfMonth(s), 1), -1)
}

/** 月视图网格：从包含 1 号的那个周一开始，铺满整周 */
export function monthGrid(anchor: Ymd): { days: Ymd[]; from: Ymd; to: Ymd } {
  const first = startOfMonth(anchor)
  const last = endOfMonth(anchor)
  const from = addDays(first, -(isoWeekday(first) - 1))
  const to = addDays(last, 7 - isoWeekday(last))
  const days: Ymd[] = []
  for (let d = from; d <= to; d = addDays(d, 1)) days.push(d)
  return { days, from, to }
}

const WEEK_CN = ['一', '二', '三', '四', '五', '六', '日']
export const WEEKDAY_LABELS = WEEK_CN

export function weekdayLabel(s: Ymd): string {
  return `周${WEEK_CN[isoWeekday(s) - 1]}`
}

export function formatMd(s: Ymd): string {
  return `${Number(s.slice(5, 7))}月${Number(s.slice(8, 10))}日`
}

export function formatFull(s: Ymd): string {
  return `${s.slice(0, 4)}年${formatMd(s)} ${weekdayLabel(s)}`
}

export function formatMonth(s: Ymd): string {
  return `${s.slice(0, 4)}年${Number(s.slice(5, 7))}月`
}

/** 只用于展示"几点几分"这类墙上时间，输入是 Postgres 的 time 字符串 */
export function formatTime(t: string | null | undefined): string {
  if (!t) return ''
  return t.slice(0, 5)
}

/** 展示相对天数：今天 / 明天 / 还有 N 天 / 已过期 */
export function relativeDay(target: Ymd, today: Ymd): string {
  const n = diffDays(target, today)
  if (n === 0) return '今天'
  if (n === 1) return '明天'
  if (n === 2) return '后天'
  if (n < 0) return `已过 ${-n} 天`
  return `还有 ${n} 天`
}
