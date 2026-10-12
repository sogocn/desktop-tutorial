// 家长给皮肤定家庭价（019）。覆盖值走 skin_family_settings，皮肤本体不动。
//
// 抽成共享组件的原因：钱包 → 皮肤 是孩子和家长都会进的页面，以前改价入口
// 只藏在「我的 → 家长设置」里，家长反馈在商店里根本找不到。现在两处都能开。
import { useEffect, useState } from 'react'
import { SkinIcon } from '@/components/SkinIcon'
import { Button, Input, Sheet, Spinner } from '@/components/ui'
import { useSetSkinPrice, useSkinsForFamily } from '@/hooks/useApp'
import { BackendError } from '@/lib/backend/types'

export function SkinPriceSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { data, isLoading } = useSkinsForFamily()
  const setPrice = useSetSkinPrice()
  const [prices, setPrices] = useState<Record<string, string>>({})
  const [err, setErr] = useState('')
  const [ok, setOk] = useState(false)

  // 打开 / 数据回来时把输入框同步成当前生效价。
  // 原先写在 render 里 setState，且条件是「key 个数 != data 长度」，
  // 一旦外部价格变动就不再重同步（改完价重新打开还是旧值），改用 effect。
  useEffect(() => {
    if (!open || !data) return
    setErr('')
    setOk(false)
    const init: Record<string, string> = {}
    for (const s of data) init[s.id] = String(s.price)
    setPrices(init)
  }, [open, data])

  function setP(id: string, v: string) {
    setPrices((p) => ({ ...p, [id]: v.replace(/[^0-9]/g, '').slice(0, 6) }))
    setOk(false)
  }

  async function save() {
    setErr('')
    setOk(false)
    if (!data) return
    try {
      for (const s of data) {
        const raw = prices[s.id]
        // 空框 = 不想改这一项，跳过而不是当成 0 分
        if (raw === undefined || raw.trim() === '') continue
        const next = Number(raw)
        if (Number.isFinite(next) && next >= 0 && next <= 100000 && next !== s.price) {
          await setPrice.mutateAsync({ skinId: s.id, pricePoints: next })
        }
      }
      setOk(true)
      setTimeout(onClose, 900)
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  // 只以「输入框里是有效数字且和当前价不同」为准，
  // 不能用 Number(undefined) 去比——那会得到 NaN 恒不等于价格，按钮永远可点。
  const changed =
    data?.some((s) => {
      const raw = prices[s.id]
      return raw !== undefined && raw.trim() !== '' && Number(raw) !== s.price
    }) ?? false

  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="皮肤定价"
      footer={
        <Button
          size="lg"
          className="mb-1 w-full"
          disabled={!changed || setPrice.isPending}
          onClick={save}
        >
          {setPrice.isPending ? '保存中…' : '保存'}
        </Button>
      }
    >
      <div className="space-y-4">
        <p className="rounded-xl bg-app px-3.5 py-2.5 text-sm text-muted">
          皮肤是孩子能用积分兑换的装饰。这里定的价只影响本家庭，改完立刻生效；
          不填或与当前一致就不改。
        </p>

        {isLoading ? (
          <Spinner />
        ) : (
          <div className="space-y-2.5">
            {data?.map((s) => {
              const base = Number(prices[s.id] ?? s.price)
              const overridden = Number.isFinite(base) && base !== s.base_price
              return (
                <div
                  key={s.id}
                  className="flex items-center gap-3 rounded-2xl bg-surface p-3.5 shadow-sm ring-1 ring-slate-200/50"
                >
                  <SkinIcon skinKey={s.key} className="h-7 w-7 text-fg" />
                  <div className="min-w-0 flex-1">
                    <p className="font-medium text-fg">{s.name}</p>
                    <p className="text-xs text-muted">
                      基础价 {s.base_price} 分
                      {overridden && ` · 本家庭已改为 ${base} 分`}
                    </p>
                  </div>
                  <Input
                    type="number"
                    inputMode="numeric"
                    min={0}
                    value={prices[s.id] ?? String(s.price)}
                    onChange={(e) => setP(s.id, e.target.value)}
                    className="w-20 text-center text-sm"
                  />
                </div>
              )
            })}
          </div>
        )}

        {ok && (
          <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">已保存</p>
        )}
        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}
