import { useQueryClient } from '@tanstack/react-query'
import { Check, ChevronRight, Copy, Download, Lock, LogOut, ShieldCheck, Trash2 } from 'lucide-react'
import { useState } from 'react'
import * as api from '@/api'
import { Button, Card, Empty, Field, Input, Sheet, Spinner } from '@/components/ui'
import { qk, useBootstrap, useMe, useRedemptions } from '@/hooks/useApp'
import { getBackend } from '@/lib/backend'
import { BackendError } from '@/lib/backend/types'
import { cn } from '@/lib/cn'
import { useSession } from '@/store/session'

export default function MePage() {
  const { data: boot } = useBootstrap()
  const me = useMe()
  const qc = useQueryClient()
  const signOut = useSession((s) => s.signOut)
  const removeAllKnownUsers = useSession((s) => s.removeAllKnownUsers)
  const [pinSheet, setPinSheet] = useState(false)
  const [approvals, setApprovals] = useState(false)

  if (!boot?.in_family || !me) return <Spinner />
  const isParent = me.role === 'parent'
  const pendingCount = 0 // 由 ApprovalsSheet 内部统计，这里只做入口

  return (
    <div className="mx-auto w-full max-w-md">
      <div className="pt-safe px-4 pb-3">
        <div className="mt-2 flex items-center gap-3.5">
          <span className="flex size-16 items-center justify-center rounded-2xl bg-white text-3xl shadow-sm">
            {me.avatar_emoji}
          </span>
          <div className="min-w-0">
            <h1 className="text-xl font-bold text-slate-900">{me.nickname}</h1>
            <p className="text-sm text-slate-500">
              {boot.family?.name} · {isParent ? '家长' : '成员'}
              {me.role === 'child' && ` · ${me.points_balance} 分`}
            </p>
          </div>
        </div>
      </div>

      <div className="space-y-5 px-4 pb-28">
        {/* 成员 */}
        <section>
          <h2 className="mb-2 px-1 text-sm font-semibold text-slate-900">家庭成员</h2>
          <div className="space-y-2">
            {boot.members?.map((m) => (
              <Card key={m.id} className="flex items-center gap-3 py-3">
                <span className="text-2xl">{m.avatar_emoji}</span>
                <div className="min-w-0 flex-1">
                  <p className="font-medium text-slate-900">
                    {m.nickname}
                    {m.id === me.id && <span className="ml-1.5 text-xs text-slate-400">（我）</span>}
                  </p>
                  <p className="text-xs text-slate-400">
                    {m.role === 'parent' ? '家长' : '孩子'}
                    {m.role === 'child' && ` · ${m.points_balance} 分`}
                    {m.role === 'parent' && m.has_pin && ' · 已设 PIN'}
                    {!m.user_id && ' · 待认领'}
                  </p>
                </div>
              </Card>
            ))}
          </div>
        </section>

        {/* 邀请码 */}
        {(boot.invites?.length ?? 0) > 0 && (
          <section>
            <h2 className="mb-2 px-1 text-sm font-semibold text-slate-900">邀请码</h2>
            <div className="space-y-2">
              {boot.invites?.map((i) => (
                <InviteRow key={i.id} code={i.code} role={i.role} claim={!!i.member_id} />
              ))}
            </div>
          </section>
        )}

        {/* 家长专区 */}
        {isParent && (
          <section>
            <h2 className="mb-2 px-1 text-sm font-semibold text-slate-900">家长设置</h2>
            <div className="space-y-2">
              <RowButton
                icon={<Lock size={18} />}
                label={me.has_pin ? '修改家长 PIN' : '设置家长 PIN'}
                hint={me.has_pin ? '改任务、审批兑换时需要' : '还没设置，任何人都能改任务'}
                warn={!me.has_pin}
                onClick={() => setPinSheet(true)}
              />
              <RowButton
                icon={<ShieldCheck size={18} />}
                label="兑换审批"
                hint={pendingCount > 0 ? `${pendingCount} 笔待处理` : '查看孩子的兑换申请'}
                onClick={() => setApprovals(true)}
              />
            </div>
          </section>
        )}

        {/* 数据 */}
        <section>
          <h2 className="mb-2 px-1 text-sm font-semibold text-slate-900">数据</h2>
          <div className="space-y-2">
            {import.meta.env.VITE_BACKEND !== 'server' && (
              <RowButton
                icon={<Download size={18} />}
                label="导出备份"
                hint="下载整个数据库文件，换设备时可以带走"
                onClick={async () => {
                  const be = await getBackend()
                  const blob = await be.dump()
                  const url = URL.createObjectURL(blob)
                  const a = document.createElement('a')
                  a.href = url
                  a.download = `familyquest-${new Date().toISOString().slice(0, 10)}.tar.gz`
                  a.click()
                  URL.revokeObjectURL(url)
                }}
              />
            )}
            <RowButton
              icon={<LogOut size={18} />}
              label="退出这个身份"
              hint="数据在服务器上，退出后用用户名 + PIN 可随时登录回来"
              onClick={() => {
                if (!confirm('退出后需要重新输入用户名 + PIN 才能回到这个家庭，确定吗？')) return
                signOut()
                // 用 invalidateQueries 而不是 qc.clear()：clear() 会把 bootstrap
                // 查询从缓存里整个删掉，而 React Query v5 里已挂载的 observer
                // 不会因查询被删而重新拉取，界面就停在主壳（要手动刷新才回欢迎页）。
                // invalidate 会让仍挂载的 bootstrap 立即重查，identity 已是 null，
                // 返回 in_family=false，App 根组件自动切回 Onboarding。
                api.setIdentity(null).then(() => qc.invalidateQueries())
              }}
            />
            {import.meta.env.VITE_BACKEND !== 'server' && (
              <RowButton
                icon={<Trash2 size={18} />}
                label="清空所有数据"
                hint="不可恢复。建议先导出备份"
                danger
                onClick={async () => {
                  if (!confirm('所有任务、积分、勋章都会被永久删除，确定吗？')) return
                  if (!confirm('真的确定？这个操作没法撤销。')) return
                  const be = await getBackend()
                  await be.reset()
                  // 数据库都清了，本机身份列表里的旧身份指向空数据，一并清掉，
                  // 否则欢迎页会残留身份卡，点恢复只会得到"数据已被清空"
                  removeAllKnownUsers()
                  signOut()
                  location.reload()
                }}
              />
            )}
          </div>
        </section>

        <p className="pt-2 text-center text-xs text-slate-400">
          数据保存在服务器，用用户名 + PIN 可在任意设备登录同一份家庭数据
        </p>
      </div>

      <PinSheet open={pinSheet} onClose={() => setPinSheet(false)} hasPin={me.has_pin} />
      <ApprovalsSheet open={approvals} onClose={() => setApprovals(false)} />
    </div>
  )
}

function RowButton({
  icon,
  label,
  hint,
  onClick,
  danger,
  warn,
}: {
  icon: React.ReactNode
  label: string
  hint?: string
  onClick: () => void
  danger?: boolean
  warn?: boolean
}) {
  return (
    <button
      onClick={onClick}
      className="flex w-full items-center gap-3 rounded-2xl border border-slate-200/70 bg-white p-3.5 text-left shadow-sm active:scale-[0.99]"
    >
      <span
        className={cn(
          'flex size-9 shrink-0 items-center justify-center rounded-xl',
          danger ? 'bg-rose-50 text-rose-500' : warn ? 'bg-amber-50 text-amber-600' : 'bg-slate-100 text-slate-600',
        )}
      >
        {icon}
      </span>
      <span className="min-w-0 flex-1">
        <span className={cn('block font-medium', danger ? 'text-rose-600' : 'text-slate-900')}>
          {label}
        </span>
        {hint && <span className="block text-xs text-slate-400">{hint}</span>}
      </span>
      <ChevronRight size={18} className="shrink-0 text-slate-300" />
    </button>
  )
}

function InviteRow({ code, role, claim }: { code: string; role: string; claim: boolean }) {
  const [copied, setCopied] = useState(false)
  return (
    <Card className="flex items-center gap-3 py-3">
      <div className="min-w-0 flex-1">
        <p className="font-mono text-lg font-bold tracking-[0.2em] text-slate-900">{code}</p>
        <p className="text-xs text-slate-400">
          {claim ? '认领码（指定成员专用）' : role === 'parent' ? '家长邀请码' : '孩子邀请码'}
        </p>
      </div>
      <Button
        variant="outline"
        size="sm"
        onClick={() => {
          navigator.clipboard?.writeText(code)
          setCopied(true)
          setTimeout(() => setCopied(false), 1600)
        }}
      >
        {copied ? <Check size={16} /> : <Copy size={16} />}
      </Button>
    </Card>
  )
}

function PinSheet({ open, onClose, hasPin }: { open: boolean; onClose: () => void; hasPin: boolean }) {
  const qc = useQueryClient()
  const [oldPin, setOldPin] = useState('')
  const [pin, setPin] = useState('')
  const [err, setErr] = useState('')
  const [ok, setOk] = useState(false)

  return (
    <Sheet
      open={open}
      onClose={() => {
        setOldPin('')
        setPin('')
        setErr('')
        setOk(false)
        onClose()
      }}
      title={hasPin ? '修改 PIN' : '设置 PIN'}
      footer={
        <Button
          size="lg"
          className="mb-1 w-full"
          disabled={!/^\d{4}$/.test(pin)}
          onClick={async () => {
            setErr('')
            try {
              await api.setPin(pin, hasPin ? oldPin : null)
              await qc.invalidateQueries({ queryKey: qk.bootstrap })
              setOk(true)
              setTimeout(onClose, 900)
            } catch (e) {
              setErr(e instanceof BackendError ? e.message : String(e))
            }
          }}
        >
          保存
        </Button>
      }
    >
      <div className="space-y-4">
        {hasPin && (
          <Field label="当前 PIN">
            <Input
              value={oldPin}
              onChange={(e) => setOldPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
              inputMode="numeric"
              placeholder="••••"
              className="text-center text-xl tracking-[0.4em]"
            />
          </Field>
        )}
        <Field label="新 PIN（4 位数字）">
          <Input
            value={pin}
            onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
            inputMode="numeric"
            placeholder="••••"
            className="text-center text-xl tracking-[0.4em]"
          />
        </Field>
        <p className="rounded-xl bg-slate-50 px-3.5 py-2.5 text-sm leading-relaxed text-slate-500">
          连续输错 5 次会锁 15 分钟。PIN 只有 4 位，真正管用的是这个限制。
        </p>
        {ok && <p className="rounded-xl bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-700">已保存</p>}
        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}

function ApprovalsSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  const qc = useQueryClient()
  const { data } = useRedemptions(null)
  const validToken = useSession((s) => s.validParentToken)
  const setParentToken = useSession((s) => s.setParentToken)
  const [pin, setPin] = useState('')
  const [err, setErr] = useState('')

  const pending = (data ?? []).filter((r) => r.status === 'pending')
  const token = validToken()

  async function decide(id: string, decision: 'approved' | 'rejected') {
    setErr('')
    try {
      let t = validToken()
      if (!t) {
        const v = await api.verifyPin(pin)
        setParentToken(v.token, v.expires_at)
        t = v.token
      }
      await api.decideRedemption(id, decision, t)
      await qc.invalidateQueries({ queryKey: ['redemptions'] })
      await qc.invalidateQueries({ queryKey: qk.bootstrap })
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
    }
  }

  return (
    <Sheet open={open} onClose={onClose} title="兑换审批">
      <div className="space-y-4">
        {!token && (
          <Field label="先输入家长 PIN" hint="审批需要验证身份，30 分钟内不用重复输">
            <Input
              value={pin}
              onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
              inputMode="numeric"
              placeholder="••••"
              className="text-center text-xl tracking-[0.4em]"
            />
          </Field>
        )}

        {pending.length === 0 ? (
          <Empty emoji="✅" title="没有待处理的申请" />
        ) : (
          <div className="space-y-2.5">
            {pending.map((r) => (
              <Card key={r.id} className="space-y-3">
                <div className="flex items-center gap-3">
                  <span className="text-2xl">{r.snap_emoji}</span>
                  <div className="min-w-0 flex-1">
                    <p className="font-medium text-slate-900">
                      {r.snap_name} × {Number(r.quantity)}
                    </p>
                    <p className="text-xs text-slate-400">
                      {r.points_cost} 分 ·{' '}
                      {new Date(r.requested_at).toLocaleString('zh-CN', {
                        month: 'numeric',
                        day: 'numeric',
                        hour: '2-digit',
                        minute: '2-digit',
                      })}
                    </p>
                  </div>
                </div>
                <div className="flex gap-2">
                  <Button
                    size="sm"
                    className="flex-1"
                    disabled={!token && !/^\d{4}$/.test(pin)}
                    onClick={() => decide(r.id, 'approved')}
                  >
                    同意
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    className="flex-1"
                    disabled={!token && !/^\d{4}$/.test(pin)}
                    onClick={() => decide(r.id, 'rejected')}
                  >
                    驳回并退分
                  </Button>
                </div>
              </Card>
            ))}
          </div>
        )}

        {err && <p className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-600">{err}</p>}
      </div>
    </Sheet>
  )
}
