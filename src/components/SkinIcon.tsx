// 每个皮肤一枚专属图标。
//
// 为什么不用 emoji：emoji 在各平台字形不一致（安卓/iOS/Windows 长得都不一样），
// 也不算"专属"。这里改成内联 SVG：
//   - 跟随 currentColor，随皮肤配色自动变色
//   - 体积小、任意清晰度、可直接改
//   - 全部原创线条稿，不搬运受版权保护的角色，规避上架风险
import type { SkinKey } from '@/types/db'
import { cn } from '@/lib/cn'

type Props = { skinKey: string; className?: string; title?: string }

const STROKE = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2 as const,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

/** 小五角星，魔法类皮肤复用 */
function Sparkle({ x, y, s = 1, o = 1 }: { x: number; y: number; s?: number; o?: number }) {
  return (
    <path
      d={`M${x} ${y}l.55 1.35L${x + 1.9} ${y + 1.35}l-1.35.55L${x} ${y + 2.9}l-.55-1L${x - 1.9} ${y + 1.9}l1.35-.55Z`}
      fill="currentColor"
      opacity={o}
      transform={`scale(${s})`}
    />
  )
}

export function SkinIcon({ skinKey, className, title }: Props) {
  const common = {
    viewBox: '0 0 24 24',
    className,
    'aria-hidden': title ? undefined : true,
    role: title ? ('img' as const) : undefined,
  }

  switch (skinKey as SkinKey) {
    // 默认：一只调色盘
    case 'default':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="8.5" {...STROKE} />
          <circle cx="9" cy="9" r="1.25" fill="currentColor" />
          <circle cx="15" cy="9.3" r="1.25" fill="currentColor" />
          <circle cx="10" cy="14.6" r="1.25" fill="currentColor" />
        </svg>
      )

    // 护眼：一片叶子
    case 'eye_care':
      return (
        <svg {...common}>
          <path
            d="M4.5 20c-.4-8.5 5.2-14.5 14.5-15.5C20 13.6 14.8 19.6 7.6 19.6c-1.1 0-2.2-.2-3.1-.4Z"
            {...STROKE}
          />
          <path d="M4.8 19.6c3.6-4 6.6-7 10.2-9.4" {...STROKE} strokeWidth={1.5} opacity={0.65} />
        </svg>
      )

    // 宝可梦：精灵球
    case 'pokemon':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="8.6" {...STROKE} />
          <path d="M3.4 12a8.6 8.6 0 0 1 17.2 0Z" fill="currentColor" opacity={0.85} />
          <path d="M3.4 12h17.2" {...STROKE} />
          <circle cx="12" cy="12" r="2.5" {...STROKE} />
        </svg>
      )

    // 线条小狗：简笔狗脸
    case 'line_dog':
      return (
        <svg {...common}>
          <path
            d="M4.5 9.2C4.5 6.1 6.8 3.6 10 3.6h4c3.2 0 5.5 2.5 5.5 5.6 0 3.9-1.7 6.4-3.9 8.6H8.4c-2.2-2.2-3.9-4.7-3.9-8.6Z"
            {...STROKE}
          />
          <circle cx="9.3" cy="10.2" r="1" fill="currentColor" />
          <circle cx="14.7" cy="10.2" r="1" fill="currentColor" />
          <path d="M12 12.4v1.6" {...STROKE} strokeWidth={1.6} />
          <path d="M10.3 16.1c.9.6 2.1.6 3 0" {...STROKE} strokeWidth={1.6} />
        </svg>
      )

    // 哈利波特：魔杖 + 星光
    case 'hp_hermione':
      return (
        <svg {...common}>
          <path d="M4.6 19.4 17.4 6.6" {...STROKE} strokeWidth={2.2} />
          <Sparkle x={18.4} y={3.2} o={0.95} />
          <Sparkle x={20} y={10.2} s={0.75} o={0.7} />
          <Sparkle x={4.2} y={7.4} s={0.75} o={0.7} />
        </svg>
      )

    // 兜底：未识别的皮肤 key，给一个中性圆环
    default:
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="8.6" {...STROKE} strokeWidth={1.6} />
        </svg>
      )
  }
}

/**
 * 皮肤专属「记号」，专门用在图表/进度里当刻度点。
 * 同样是内联 SVG：实心=已达成，描边=未达成，颜色跟随 currentColor，
 * 所以自动就是该皮肤的强调色。
 */
export function SkinMotif({
  skinKey,
  filled = true,
  className,
}: {
  skinKey?: string | null
  filled?: boolean
  className?: string
}) {
  const paint = filled
    ? { fill: 'currentColor', stroke: 'none' }
    : { fill: 'none', stroke: 'currentColor', strokeWidth: 1.3 }

  const box = {
    viewBox: '0 0 12 12',
    className: cn(className, !filled && 'opacity-45'),
    'aria-hidden': true as const,
  }

  switch (skinKey as SkinKey) {
    // 默认：小圆点
    case 'default':
      return (
        <svg {...box}>
          <circle cx="6" cy="6" r="3.4" {...paint} />
        </svg>
      )

    // 护眼：小叶子
    case 'eye_care':
      return (
        <svg {...box}>
          <path
            d="M2.8 9.4C2.4 5.3 5 2.6 9.4 2.2c.4 4.4-2.5 7.2-6 7.2-.2 0-.4 0-.6 0Z"
            {...paint}
          />
        </svg>
      )

    // 宝可梦：闪电
    case 'pokemon':
      return (
        <svg {...box}>
          <path d="M6.9 1 3.1 6.7h2.3L4.2 11l4.7-6.1H6.1Z" {...paint} />
        </svg>
      )

    // 线条小狗：肉垫爪印
    case 'line_dog':
      return (
        <svg {...box}>
          <ellipse cx="6" cy="7.7" rx="2.7" ry="2.2" {...paint} />
          <circle cx="3.1" cy="4.3" r="1.05" {...paint} />
          <circle cx="6" cy="3.3" r="1.05" {...paint} />
          <circle cx="8.9" cy="4.3" r="1.05" {...paint} />
        </svg>
      )

    // 哈利波特：四角星光
    case 'hp_hermione':
      return (
        <svg {...box}>
          <path d="M6 1.3 7.1 4.9 10.7 6 7.1 7.1 6 10.7 4.9 7.1 1.3 6 4.9 4.9Z" {...paint} />
        </svg>
      )

    default:
      return (
        <svg {...box}>
          <circle cx="6" cy="6" r="3" {...paint} />
        </svg>
      )
  }
}
