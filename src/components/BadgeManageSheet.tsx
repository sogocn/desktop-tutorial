import { Pencil, Plus, Trash2 } from 'lucide-react'
import { useState } from 'react'
import { Button, Empty, Field, Input, Sheet, Spinner } from '@/components/ui'
import { useDeleteBadge, useFamilyBadges, useSetBadgeBonus, useUpsertBadge } from '@/hooks/useApp'
import {
  BADGE_TIERS,
  buildRule,
  RULE_DIMENSIONS,
  RULE_KINDS,
  ruleSummary,
  tierLabel,
  tierRing,
  toNum,
  type RuleDimension,
  type RuleKind,
} from '@/lib/badgeRules'
import { BackendError } from '@/lib/backend/types'
import { cn } from '@/lib/cn'

/**
 * 家长的勋章管理。
 *
 * 勋章 = 名字 + 图标 + 等级 + 一条达成规则。规则是 jsonb，这里负责把表单拼成
 * 后端认识的形状；除了 streak_days 需要额外挑一个维度，其余都只有一个阈值。
 * 规则种类刻意收得很窄 —— 多一种就多一处前后端对不上的机会。
 */

type FamilyBadge = NonNullable<ReturnType<typeof useFamilyBadges>['data']>[number]

interface FormState {
  id?: string
  name: string
  emoji: string
  tier: string
  description: string
  kind: RuleKind
  dimension: RuleDimension
  threshold: string
  /** 这枚勋章首次获得时额外发的积分。家庭勋章存本体，系统勋章走家庭覆盖值 */
  pointsBonus: string
  /** 是否系统内置勋章。系统勋章只能调奖励分，其余字段后端不允许改 */
  isSystem: boolean
}

const EMPTY_FORM: FormState = {
  name: '',
  emoji: '🏅',
  tier: 'bronze',
  description: '',
  kind: 'streak_days',
  dimension: 'active',
  threshold: '7',
  pointsBonus: '0',
  isSystem: false,
}

/** 把一枚已有勋章摊平成表单状态。规则里认不出来的 kind 一律回落到默认值 */
function toForm(b: FamilyBadge): FormState {
  const r = (b.rule ?? {}) as Record<string, unknown>
  const kind = String(r.kind ?? '')
  const dim = String(r.dimension ?? '')
  return {
    id: b.id,
    name: b.name ?? '',
    emoji: b.emoji || '🏅',
    tier: b.tier ?? 'bronze',
    description: b.description ?? '',
    kind: RULE_KINDS.some((k) => k.key === kind) ? (kind as RuleKind) : 'streak_days',
    dimension: RULE_DIMENSIONS.some((d) => d.key === dim) ? (dim as RuleDimension) : 'active',
    threshold: String(toNum(r.threshold) || 7),
    pointsBonus: String(toNum(b.points_bonus) || 0),
    isSystem: b.is_system,
  }
}

export function BadgeManageSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { data, isLoading } = useFamilyBadges()
  const del = useDeleteBadge()
  const [form, setForm] = useState<FormState | null>(null)
  const [err, setErr] = useState('')

  async function remove(b: FamilyBadge) {
    if (!confirm(`删除「${b.name}」？已经拿到这枚勋章的记录也会一起消失。`)) return
    setErr('')
    try {
      await del.mutateAsync(b.id)
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <>
      {/* 表单打开时把列表这层收起来，两层抽屉叠在一起看不清 */}
      <Sheet
        open={open && !form}
        onClose={onClose}
        title="管理勋章"
        footer={
          <Button size="lg" className="mb-1 w-full" onClick={() => setForm({ ...EMPTY_FORM })}>
            <Plus size={18} /> 新建勋章
          </Button>
        }
      >
        {isLoading ? (
          <Spinner />
        ) : !data?.length ? (
          <Empty emoji="🏅" title="还没有勋章" hint="点下面的按钮建一个" />
        ) : (
          <div className="space-y-2">
            {data.map((b) => (
              <div
                key={b.id}
                className={cn(
                  'flex items-center gap-3 rounded-2xl bg-white px-3.5 py-3 shadow-sm ring-1',
                  tierRing(b.tier),
                )}
              >
                <span className="shrink-0 text-2xl">{b.emoji}</span>
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium text-slate-900">
                    {b.name}
                    {tierLabel(b.tier) && (
                      <span className="ml-1.5 text-xs font-normal text-slate-400">
                        {tierLabel(b.tier)}
                      </span>
                    )}
                  </p>
                  <p className="truncate text-xs text-slate-400">{ruleSummary(b.rule)}</p>
                  <p className="truncate text-[11px] text-emerald-600">
                    奖励 +{toNum(b.points_bonus)} 分
                    {b.is_system && toNum(b.points_bonus) !== toNum(b.base_bonus) && ' · 已覆盖'}
                  </p>
                </div>
                <button
                  onClick={() => setForm(toForm(b))}
                  className="shrink-0 rounded-lg p-2 text-slate-400 active:bg-slate-100"
                  aria-label="编辑"
                >
                  <Pencil size={16} />
                </button>
                <button
                  onClick={() => remove(b)}
                  disabled={del.isPending}
                  className="shrink-0 rounded-lg p-2 text-rose-400 active:bg-rose-50 disabled:opacity-40"
                  aria-label="删除"
                >
                  <Trash2 size={16} />
                </button>
              </div>
            ))}
          </div>
        )}

        {err && (
          <p className="mt-3 rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>
        )}
      </Sheet>

      {form && <BadgeForm form={form} onChange={setForm} onClose={() => setForm(null)} />}
    </>
  )
}

function BadgeForm({
  form,
  onChange,
  onClose,
}: {
  form: FormState
  onChange: (f: FormState) => void
  onClose: () => void
}) {
  const upsert = useUpsertBadge()
  const setBonus = useSetBadgeBonus()
  const [err, setErr] = useState('')
  const [ok, setOk] = useState(false)

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    onChange({ ...form, [key]: value })

  const threshold = toNum(form.threshold)
  const bonus = toNum(form.pointsBonus)
  const nameOk = form.name.trim().length > 0
  const bonusOk = Number.isFinite(bonus) && bonus >= 0
  const saving = upsert.isPending || setBonus.isPending
  const canSave = nameOk && threshold > 0 && bonusOk && !saving
  const unit = RULE_KINDS.find((k) => k.key === form.kind)?.unit ?? ''

  async function save() {
    setErr('')
    try {
      if (form.isSystem) {
        // 系统内置勋章只能调奖励分，其余字段后端不允许改
        await setBonus.mutateAsync({ badgeId: form.id!, pointsBonus: bonus })
      } else {
        await upsert.mutateAsync({
          // 新建时不带 id，让后端生成；编辑时带上就是 update
          ...(form.id ? { id: form.id } : {}),
          name: form.name.trim(),
          emoji: form.emoji.trim() || '🏅',
          tier: form.tier,
          description: form.description.trim(),
          rule: buildRule(form.kind, threshold, form.dimension),
          pointsBonus: bonus,
        })
      }
      setOk(true)
      setTimeout(onClose, 700)
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <Sheet
      open
      onClose={onClose}
      title={form.id ? '编辑勋章' : '新建勋章'}
      footer={
        <Button size="lg" className="mb-1 w-full" disabled={!canSave} onClick={save}>
          {saving ? '保存中…' : '保存'}
        </Button>
      }
    >
      <div className="space-y-4">
        {/* 预览：家长边填边看孩子会看到什么 */}
        <div className="flex flex-col items-center rounded-2xl bg-slate-50 py-4">
          <span className="text-5xl">{form.emoji || '🏅'}</span>
          <p className="mt-1.5 font-semibold text-slate-900">{form.name.trim() || '未命名勋章'}</p>
          <p className="text-xs text-slate-400">
            {tierLabel(form.tier)} ·{' '}
            {ruleSummary(buildRule(form.kind, threshold, form.dimension))}
          </p>
        </div>

        {/* 系统内置勋章只能调奖励分，其余字段统一不可改：整体置灰 + 禁交互 */}
        <div className={cn(form.isSystem && 'pointer-events-none opacity-50')}>
        <div className="flex gap-3">
          <div className="w-20 shrink-0">
            <Field label="图标">
              <Input
                value={form.emoji}
                onChange={(e) => set('emoji', e.target.value.slice(0, 4))}
                className="text-center text-xl"
                placeholder="🏅"
              />
            </Field>
          </div>
          <div className="min-w-0 flex-1">
            <Field label="名字">
              <Input
                value={form.name}
                onChange={(e) => set('name', e.target.value.slice(0, 20))}
                placeholder="如：一周不断更"
              />
            </Field>
          </div>
        </div>

        <Field label="等级">
          <div className="grid grid-cols-4 gap-2">
            {BADGE_TIERS.map((t) => (
              <button
                key={t.key}
                type="button"
                onClick={() => set('tier', t.key)}
                className={cn(
                  'flex flex-col items-center rounded-xl py-2 transition active:scale-95',
                  form.tier === t.key ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600',
                )}
              >
                <span className="text-lg leading-none">{t.emoji}</span>
                <span className="mt-1 text-xs font-medium">{t.label}</span>
              </button>
            ))}
          </div>
        </Field>

        <Field label="说明" hint="孩子在勋章墙上看到的一句话">
          <Input
            value={form.description}
            onChange={(e) => set('description', e.target.value.slice(0, 40))}
            placeholder="如：连续 7 天每天都有任务做完"
          />
        </Field>

        <Field label="达成条件">
          <select
            value={form.kind}
            onChange={(e) => set('kind', e.target.value as RuleKind)}
            className="h-12 w-full rounded-xl border border-slate-200 bg-white px-3 text-slate-900 focus:border-slate-900 focus:outline-none"
          >
            {RULE_KINDS.map((k) => (
              <option key={k.key} value={k.key}>
                {k.label}
              </option>
            ))}
          </select>
        </Field>

        {form.kind === 'streak_days' && (
          <Field label="连续哪一项">
            <div className="grid grid-cols-3 gap-2">
              {RULE_DIMENSIONS.map((d) => (
                <button
                  key={d.key}
                  type="button"
                  onClick={() => set('dimension', d.key)}
                  className={cn(
                    'rounded-xl py-2.5 text-sm font-medium transition active:scale-95',
                    form.dimension === d.key
                      ? 'bg-slate-900 text-white'
                      : 'bg-slate-100 text-slate-600',
                  )}
                >
                  {d.label}
                </button>
              ))}
            </div>
          </Field>
        )}

        <Field label={`阈值（${unit}）`}>
          <Input
            type="number"
            inputMode="numeric"
            min={1}
            value={form.threshold}
            onChange={(e) => set('threshold', e.target.value.replace(/\D/g, '').slice(0, 5))}
            placeholder="7"
          />
        </Field>
        </div>

        {form.isSystem && (
          <p className="rounded-xl bg-slate-50 px-3.5 py-2.5 text-sm text-slate-500">
            系统内置勋章只能调整「奖励积分」，名字 / 规则由系统统一设定，不可改。
          </p>
        )}

        <Field label="奖励积分" hint="孩子首次获得这枚勋章时额外发的积分（按获取难度给个参考值）">
          <Input
            type="number"
            inputMode="numeric"
            min={0}
            value={form.pointsBonus}
            onChange={(e) => set('pointsBonus', e.target.value.replace(/[^0-9]/g, '').slice(0, 6))}
            placeholder="0"
          />
        </Field>

        {!nameOk && <p className="text-xs text-slate-400">名字不能空着。</p>}
        {ok && (
          <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">已保存</p>
        )}
        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}
