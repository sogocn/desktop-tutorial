import type { SkinTheme } from '@/types/db'

/** 默认皮肤的配色（和 019_skins.sql 里 default 的 theme 保持一致，避免首屏闪一下） */
export const DEFAULT_THEME: SkinTheme = {
  bg: '#f8fafc',
  surface: '#ffffff',
  surface2: '#f1f5f9',
  primary: '#0f172a',
  primaryHover: '#1e293b',
  onPrimary: '#ffffff',
  onPrimaryMuted: 'rgba(255,255,255,0.7)',
  text: '#0f172a',
  muted: '#64748b',
  border: 'rgba(226,232,240,0.7)',
  navBg: 'rgba(255,255,255,0.9)',
  accent: '#0ea5e9',
  pattern: null,
  // 未登录 / 皮肤列表还没回来时用默认皮肤自己那张背景图，
  // 与 022 迁移写进库的 default.theme.photo 保持一致（首屏与登录页都有底图）
  photo: '/skins/default-bg.webp',
}

/** 把图案 key 变成一张可平铺的 SVG data-URI（材质感背景，放在 body 上，超低透明度） */
export function patternUrl(pattern: string | null, accent: string): string | null {
  if (!pattern) return null
  const a = encodeURIComponent(accent)
  if (pattern === 'poke_dots') {
    const svg =
      `<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'>` +
      `<circle cx='10' cy='10' r='4' fill='${a}' fill-opacity='0.10'/>` +
      `<circle cx='30' cy='30' r='4' fill='${a}' fill-opacity='0.10'/>` +
      `</svg>`
    return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`
  }
  if (pattern === 'dog_lines') {
    const svg =
      `<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>` +
      `<path d='M6 8 q9 7 18 0' stroke='${a}' stroke-opacity='0.12' fill='none' stroke-width='2' stroke-linecap='round'/>` +
      `<path d='M24 28 q9 7 18 0' stroke='${a}' stroke-opacity='0.12' fill='none' stroke-width='2' stroke-linecap='round'/>` +
      `<circle cx='40' cy='10' r='3' fill='${a}' fill-opacity='0.12'/>` +
      `</svg>`
    return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`
  }
  if (pattern === 'hp_stars') {
    const svg =
      `<svg xmlns='http://www.w3.org/2000/svg' width='52' height='52'>` +
      `<text x='8' y='20' font-size='16' fill='${a}' fill-opacity='0.12'>✦</text>` +
      `<text x='34' y='44' font-size='12' fill='${a}' fill-opacity='0.10'>✧</text>` +
      `</svg>`
    return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`
  }
  return null
}

const VARS: (keyof SkinTheme)[] = [
  'bg',
  'surface',
  'surface2',
  'primary',
  'primaryHover',
  'onPrimary',
  'onPrimaryMuted',
  'text',
  'muted',
  'border',
  'navBg',
  'accent',
]

/** 把皮肤配色写到 document 根节点的 CSS 变量上，整页配色随之切换 */
export function applyTheme(theme: SkinTheme | null | undefined) {
  const t = theme ?? DEFAULT_THEME
  const root = document.documentElement
  for (const k of VARS) {
    root.style.setProperty(`--${cssName(k)}`, String(t[k] ?? DEFAULT_THEME[k]))
  }
  const pu = patternUrl(t.pattern ?? null, t.accent)
  if (pu) root.style.setProperty('--app-pattern', pu)
  else root.style.removeProperty('--app-pattern')

  // 专属大图叠在 pattern 之上。图还没配（或路径失效）时这一层会被浏览器
  // 直接忽略，画面自然退化成 pattern，不会白屏也不会报错。
  if (t.photo) {
    root.style.setProperty('--skin-photo', `url("${t.photo}")`)
    // 大图现在铺满整屏（024），正文会直接压在角色图的深色块上，
    // 加一层白纱把对比度拉回来；0.25 是"看得见图又不吃字"的平衡点。
    root.style.setProperty(
      '--skin-veil',
      'linear-gradient(rgba(255,255,255,0.25), rgba(255,255,255,0.25))',
    )
  } else {
    root.style.removeProperty('--skin-photo')
    root.style.removeProperty('--skin-veil')
  }
}

/** 大图作为 CSS 背景的值，给需要 inline style 的地方用（日历页头图等） */
export function photoBg(photo?: string | null): string | undefined {
  return photo ? `url("${photo}")` : undefined
}

/** SkinTheme 的驼峰键 → CSS 变量名（如 primaryHover → primary-hover） */
function cssName(k: keyof SkinTheme): string {
  if (k === 'primaryHover') return 'primary-hover'
  if (k === 'onPrimary') return 'on-primary'
  if (k === 'onPrimaryMuted') return 'on-primary-muted'
  if (k === 'navBg') return 'nav'
  return k
}
