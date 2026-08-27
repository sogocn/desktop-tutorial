/**
 * 复制文本到剪贴板，兼容 HTTP 非安全上下文。
 *
 * navigator.clipboard 只在「安全上下文」（HTTPS / localhost）存在；
 * 项目以 http://<公网IP> 部署时它是 undefined，直接调用会静默失败
 * （页面还显示"已复制"，实际什么都没复制）。
 * 这里退回 document.execCommand('copy') + 临时 textarea 的老办法。
 *
 * @returns 是否真的复制成功 —— 调用方据此决定要不要显示"已复制"。
 */
export async function copyText(text: string): Promise<boolean> {
  // 优先走现代 API（HTTPS 下可用，权限提示体验也更好）
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text)
      return true
    }
  } catch {
    // 权限被拒等情形，落到兜底方案
  }

  // 兜底：execCommand 虽已标记 deprecated，但所有主流浏览器都还支持，
  // 且不要求安全上下文。
  try {
    const ta = document.createElement('textarea')
    ta.value = text
    // 移出可视区 + 透明，避免页面闪一下；fixed 定位防止页面滚动
    ta.style.position = 'fixed'
    ta.style.top = '0'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.focus()
    ta.select()
    ta.setSelectionRange(0, text.length)
    const ok = document.execCommand('copy')
    document.body.removeChild(ta)
    return ok
  } catch {
    return false
  }
}
