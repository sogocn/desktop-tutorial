import confetti from 'canvas-confetti'

/**
 * 完成任务的即时反馈。
 * 这个东西看着是装饰，其实是产品的核心：对孩子来说，
 * "点完之后屏幕炸开花"比"+5 分"这三个字有效得多。
 */
export function celebrate(intensity: 'small' | 'big' = 'small') {
  if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return

  const base = {
    spread: intensity === 'big' ? 100 : 62,
    ticks: intensity === 'big' ? 180 : 110,
    gravity: 1.1,
    scalar: intensity === 'big' ? 1.1 : 0.9,
    colors: ['#38bdf8', '#a78bfa', '#34d399', '#fbbf24', '#fb7185'],
    disableForReducedMotion: true,
  }

  confetti({
    ...base,
    particleCount: intensity === 'big' ? 120 : 55,
    origin: { y: 0.62 },
  })

  if (intensity === 'big') {
    // 补两侧的斜射，中间那一炮显得单薄
    setTimeout(
      () => confetti({ ...base, particleCount: 45, angle: 60, origin: { x: 0, y: 0.7 } }),
      120,
    )
    setTimeout(
      () => confetti({ ...base, particleCount: 45, angle: 120, origin: { x: 1, y: 0.7 } }),
      120,
    )
  }
}

/** 轻震动。iOS Safari 不支持，静默失败即可 */
export function buzz(pattern: number | number[] = 12) {
  try {
    navigator.vibrate?.(pattern)
  } catch {
    /* 忽略 */
  }
}
