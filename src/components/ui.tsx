import { X } from 'lucide-react'
import { useEffect, type ReactNode } from 'react'
import { cn } from '@/lib/cn'
import type { TaskColor } from '@/types/db'

// ---------------------------------------------------------------------------
// 颜色映射。Tailwind 要静态类名才能被扫到，所以只能写全，不能拼字符串。
// ---------------------------------------------------------------------------
export const TASK_COLORS: Record<TaskColor, { bg: string; text: string; dot: string; ring: string }> =
  {
    sky: { bg: 'bg-sky-100', text: 'text-sky-700', dot: 'bg-sky-500', ring: 'ring-sky-300' },
    violet: {
      bg: 'bg-violet-100',
      text: 'text-violet-700',
      dot: 'bg-violet-500',
      ring: 'ring-violet-300',
    },
    emerald: {
      bg: 'bg-emerald-100',
      text: 'text-emerald-700',
      dot: 'bg-emerald-500',
      ring: 'ring-emerald-300',
    },
    amber: { bg: 'bg-amber-100', text: 'text-amber-700', dot: 'bg-amber-500', ring: 'ring-amber-300' },
    rose: { bg: 'bg-rose-100', text: 'text-rose-700', dot: 'bg-rose-500', ring: 'ring-rose-300' },
    slate: { bg: 'bg-slate-100', text: 'text-slate-600', dot: 'bg-slate-400', ring: 'ring-slate-300' },
  }

export function colorOf(c: string): (typeof TASK_COLORS)[TaskColor] {
  return TASK_COLORS[(c as TaskColor) in TASK_COLORS ? (c as TaskColor) : 'sky']
}

// ---------------------------------------------------------------------------
export function Button({
  variant = 'primary',
  size = 'md',
  className,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'ghost' | 'outline' | 'danger'
  size?: 'sm' | 'md' | 'lg'
}) {
  return (
    <button
      className={cn(
        'inline-flex items-center justify-center gap-1.5 rounded-xl font-medium transition',
        'active:scale-[0.97] disabled:pointer-events-none disabled:opacity-40',
        size === 'sm' && 'h-8 px-3 text-sm',
        size === 'md' && 'h-11 px-4 text-[15px]',
        size === 'lg' && 'h-13 px-5 text-base',
        variant === 'primary' && 'bg-slate-900 text-white shadow-sm hover:bg-slate-800',
        variant === 'outline' && 'border border-slate-300 bg-white text-slate-700',
        variant === 'ghost' && 'text-slate-600 hover:bg-slate-100',
        variant === 'danger' && 'bg-rose-500 text-white',
        className,
      )}
      {...props}
    />
  )
}

export function Input({ className, ...props }: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        'h-12 w-full rounded-xl border border-slate-200 bg-white px-3.5 text-slate-900',
        'placeholder:text-slate-400 focus:border-slate-900 focus:outline-none',
        className,
      )}
      {...props}
    />
  )
}

export function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-sm font-medium text-slate-700">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-xs text-slate-400">{hint}</span>}
    </label>
  )
}

export function Card({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('rounded-2xl border border-slate-200/70 bg-white p-4 shadow-sm', className)}
      {...props}
    />
  )
}

/** 底部抽屉。移动端上表单一律走这个，不用居中弹窗 —— 单手够不着 */
export function Sheet({
  open,
  onClose,
  title,
  children,
  footer,
}: {
  open: boolean
  onClose: () => void
  title: string
  children: ReactNode
  footer?: ReactNode
}) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', onKey)
    // 抽屉打开时锁住背景滚动，否则手指一滑底下的日历跟着动
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [open, onClose])

  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end">
      <div className="absolute inset-0 animate-fade-in bg-slate-900/40" onClick={onClose} />
      <div className="animate-sheet-up relative flex max-h-[92vh] flex-col rounded-t-3xl bg-white">
        <div className="flex shrink-0 items-center justify-between border-b border-slate-100 px-5 py-4">
          <h2 className="text-lg font-semibold text-slate-900">{title}</h2>
          <button onClick={onClose} className="rounded-full p-1.5 text-slate-400 hover:bg-slate-100">
            <X size={20} />
          </button>
        </div>
        <div className="no-scrollbar flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="pb-safe shrink-0 border-t border-slate-100 px-5 pt-3">{footer}</div>}
      </div>
    </div>
  )
}

export function Chip({
  active,
  className,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { active?: boolean }) {
  return (
    <button
      type="button"
      className={cn(
        'rounded-full px-3.5 py-2 text-sm font-medium transition active:scale-95',
        active ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600',
        className,
      )}
      {...props}
    />
  )
}

export function Empty({ emoji, title, hint }: { emoji: string; title: string; hint?: string }) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
      <div className="mb-3 text-5xl">{emoji}</div>
      <p className="font-medium text-slate-700">{title}</p>
      {hint && <p className="mt-1 text-sm text-slate-400">{hint}</p>}
    </div>
  )
}

export function Spinner({ label }: { label?: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-16">
      <div className="size-7 animate-spin rounded-full border-2 border-slate-200 border-t-slate-900" />
      {label && <p className="text-sm text-slate-400">{label}</p>}
    </div>
  )
}
