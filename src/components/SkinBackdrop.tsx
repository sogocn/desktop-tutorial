/**
 * 全屏皮肤背景层（024）
 *
 * 为什么不直接挂在 body 的 background-image 上：
 *   1) body 的高度随内容增长，`background-size: cover` 会把 1:1 的图拉成
 *      "整条滚动高度"那么高的超长条，越往下滑越离谱。
 *      `background-attachment: fixed` 能修，但 iOS Safari 不支持、会退化回拉伸。
 *   2) 主壳根节点原本有一层不透明的 `bg-app`，直接把 body 的图盖死 ——
 *      这正是"背景图只在登录界面有"的原因：登录页没有这层包装才看得见。
 *
 * 做法：一个独立的 `fixed inset-0` 层，尺寸恒等于视口，不随内容拉伸，各端表现一致；
 * 用 -z-10 沉到所有内容后面（#root 没有建立层叠上下文，所以能真正沉下去）。
 * 颜色 / 图案 / 大图全部从 :root 的 CSS 变量读，applyTheme() 一改这里立刻跟着变。
 *
 * 叠放顺序（前者在上）：皮肤图案 → 白色薄纱 → 皮肤大图 → 底色。
 * 薄纱不为美观，是为了压住角色图里较深的色块，保证正文对比度。
 */
export function SkinBackdrop() {
  return (
    <div
      aria-hidden
      className="pointer-events-none fixed inset-0 -z-10"
      style={{
        backgroundColor: 'var(--bg)',
        backgroundImage: [
          'var(--app-pattern, none)',
          'var(--skin-veil, none)',
          'var(--skin-photo, none)',
        ].join(', '),
        backgroundRepeat: 'repeat, no-repeat, no-repeat',
        backgroundPosition: '0 0, center, center top',
        backgroundSize: 'auto, cover, cover',
      }}
    />
  )
}
