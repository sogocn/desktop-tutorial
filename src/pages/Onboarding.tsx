import { useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Copy, Check, Trash2 } from 'lucide-react'
import { useState } from 'react'
import * as apiFns from '@/api'
import { Button, Card, Field, Input } from '@/components/ui'
import { BackendError } from '@/lib/backend/types'
import { celebrate } from '@/lib/celebrate'
import { cn } from '@/lib/cn'
import { useSession, type KnownUser } from '@/store/session'
import { qk } from '@/hooks/useApp'
import type { BootstrapState } from '@/types/db'

const AVATARS = ['🙂', '👦', '👧', '🐱', '🐶', '🦊', '🐼', '🦁', '🐧', '🦄', '🌟', '🚀']

// 把后端抛出的异常码翻译成用户能看懂的提示。
// 注意：BackendError 构造函数已把 'CODE: 人话' 拆成 code 与 message，
// message 里不含 CODE 前缀，所以这里必须按 e.code 精确匹配，不能 includes(e.message)。
function friendlyErr(e: BackendError): string {
  switch (e.code) {
    case 'INVITE_NOT_FOUND':
      return '邀请码不存在。请确认输入正确，或让家长在「我的 → 家庭成员」里重新查看邀请码'
    case 'INVITE_REVOKED':
      return '这个邀请码已作废，请让家长重新生成'
    case 'INVITE_EXPIRED':
      return '邀请码已过期，请让家长重新生成'
    case 'INVITE_USED_UP':
      return '这个邀请码已用完，请让家长重新生成'
    case 'ALREADY_IN_FAMILY':
      return '这个身份已经在家庭里了。请到「我的」页点「退出这个身份」，再重新输入邀请码加入'
    case 'NO_AUTH':
      return '身份丢失，请刷新页面后重试'
    case 'NICKNAME_REQUIRED':
      return '请填写昵称'
    case 'BAD_PIN':
      return 'PIN 必须是 4 位数字'
    default:
      return e.message || '出错了，请重试'
  }
}

type Step = 'welcome' | 'create' | 'join' | 'login' | 'done'

export default function Onboarding() {
  const [step, setStep] = useState<Step>('welcome')
  const [codes, setCodes] = useState<{ child: string; parent: string } | null>(null)

  return (
    <div className="pt-safe pb-safe mx-auto flex min-h-dvh w-full max-w-md flex-col px-6">
      {step === 'welcome' && <Welcome onPick={setStep} />}
      {step === 'create' && (
        <CreateFamily
          onBack={() => setStep('welcome')}
          onDone={(c) => {
            setCodes(c)
            setStep('done')
          }}
        />
      )}
      {step === 'join' && <JoinFamily onBack={() => setStep('welcome')} />}
      {step === 'login' && <Login onBack={() => setStep('welcome')} />}
      {step === 'done' && codes && <ShowCodes codes={codes} />}
    </div>
  )
}

function Welcome({ onPick }: { onPick: (s: Step) => void }) {
  const qc = useQueryClient()
  const knownUsers = useSession((s) => s.knownUsers)
  const setUserId = useSession((s) => s.setUserId)
  const removeKnownUser = useSession((s) => s.removeKnownUser)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [err, setErr] = useState('')

  /** 一键恢复：换回该身份的 userId → 通知后端 → 重查 bootstrap 进主壳 */
  async function restore(u: KnownUser) {
    if (busyId) return
    setBusyId(u.userId)
    setErr('')
    try {
      setUserId(u.userId)
      await apiFns.setIdentity(u.userId)
      // 必须等 bootstrap 真正重查完再判断：in_family=true → 进主壳；
      // 身份数据已被清空/失效（in_family=false）→ 给出提示，而不是静默卡在「切换中…」。
      // 注意：bootstrap"成功返回 in_family=false"不是异常，不能靠 catch 兜住，
      // 所以用 fetchQuery(staleTime: 0) 强制重查并直接拿到结果。
      const boot = await qc.fetchQuery<BootstrapState>({
        queryKey: qk.bootstrap,
        queryFn: apiFns.bootstrap,
        staleTime: 0,
      })
      if (!boot?.in_family) {
        // 指向空数据的身份卡留着只会继续误导，顺手从列表移除
        removeKnownUser(u.userId)
        setErr('这个身份的数据已被清空，无法恢复。请创建一个新家庭，或使用邀请码加入。')
      }
    } catch (e) {
      setErr(e instanceof BackendError ? friendlyErr(e) : String(e))
    } finally {
      // 任何路径都必须释放 busyId，否则所有身份卡会被冻住（点哪个都没反应）
      setBusyId(null)
    }
  }

  return (
    <div className="flex flex-1 flex-col justify-center py-10">
      <div className="mb-2 text-6xl">🏡</div>
      <h1 className="text-3xl font-bold tracking-tight text-slate-900">家庭任务板</h1>
      <p className="mt-2 leading-relaxed text-slate-500">
        把「今天该做什么」变成一件看得见、点得动、有回响的事。
      </p>

      <div className="mt-10 space-y-3">
        <Button size="lg" className="w-full" onClick={() => onPick('create')}>
          创建一个家庭
        </Button>
        <Button size="lg" variant="outline" className="w-full" onClick={() => onPick('join')}>
          我有邀请码
        </Button>
        <Button size="lg" variant="ghost" className="w-full" onClick={() => onPick('login')}>
          已有账号，登录
        </Button>
      </div>

      {knownUsers.length > 0 && (
        <section className="mt-8">
          <h2 className="px-1 text-sm font-semibold text-slate-900">本机已登录账号</h2>
          <p className="mb-2 px-1 text-xs leading-relaxed text-slate-400">
            这些是本机登录过的账号，点一下即可切换，无需重新输入用户名和密码。
          </p>
          <div className="space-y-2">
            {knownUsers.map((u) => (
              <Card
                key={u.userId}
                className={cn(
                  'flex cursor-pointer items-center gap-3 py-3 transition active:scale-[0.99]',
                  busyId === u.userId && 'pointer-events-none opacity-60',
                )}
                onClick={() => restore(u)}
              >
                <span className="text-2xl">{u.avatarEmoji ?? '🙂'}</span>
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium text-slate-900">
                    {u.nickname || '未命名'}
                    {busyId === u.userId && (
                      <span className="ml-1.5 text-xs text-slate-400">切换中…</span>
                    )}
                  </p>
                  <p className="text-xs text-slate-400">
                    {u.familyName ? `${u.familyName} · ` : ''}
                    {u.role === 'parent' ? '家长' : '孩子'}
                  </p>
                </div>
                <button
                  onClick={(e) => {
                    e.stopPropagation()
                    if (
                      !confirm(
                        `把「${u.nickname || '未命名'}」从本机身份列表移除吗？` +
                          '数据不会被删除，只是不再显示在这里。',
                      )
                    )
                      return
                    removeKnownUser(u.userId)
                  }}
                  className="shrink-0 rounded-full p-2 text-slate-300 transition hover:bg-rose-50 hover:text-rose-500"
                  aria-label={`删除 ${u.nickname || '未命名'}`}
                >
                  <Trash2 size={18} />
                </button>
              </Card>
            ))}
          </div>
        </section>
      )}

      {err && <p className="mt-4 rounded-xl bg-rose-50 px-3 py-2 text-sm text-rose-600">{err}</p>}

      <p className="mt-8 text-center text-xs leading-relaxed text-slate-400">
        数据保存在服务器，用用户名 + PIN 可在任意设备登录同一份家庭数据。
      </p>
    </div>
  )
}

function Header({ title, onBack }: { title: string; onBack: () => void }) {
  return (
    <div className="flex items-center gap-3 py-4">
      <button onClick={onBack} className="-ml-1 rounded-full p-1.5 text-slate-500 hover:bg-slate-100">
        <ArrowLeft size={22} />
      </button>
      <h1 className="text-xl font-semibold text-slate-900">{title}</h1>
    </div>
  )
}

function AvatarPicker({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <div className="grid grid-cols-6 gap-2">
      {AVATARS.map((a) => (
        <button
          key={a}
          type="button"
          onClick={() => onChange(a)}
          className={cn(
            'flex aspect-square items-center justify-center rounded-xl text-2xl transition',
            value === a ? 'bg-slate-900 ring-2 ring-slate-900' : 'bg-slate-100 active:scale-95',
          )}
        >
          {a}
        </button>
      ))}
    </div>
  )
}

function CreateFamily({
  onBack,
  onDone,
}: {
  onBack: () => void
  onDone: (c: { child: string; parent: string }) => void
}) {
  const ensureUserId = useSession((s) => s.ensureUserId)
  const addKnownUser = useSession((s) => s.addKnownUser)
  const [familyName, setFamilyName] = useState('')
  const [nickname, setNickname] = useState('')
  const [username, setUsername] = useState('')
  const [avatar, setAvatar] = useState('🙂')
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const pinOk = /^\d{4}$/.test(pin)
  const usernameOk = username.trim().length > 0
  const canSubmit = familyName.trim() && nickname.trim() && usernameOk && pinOk && !busy

  async function submit() {
    setBusy(true)
    setErr('')
    try {
      const uid = ensureUserId()
      await apiFns.setIdentity(uid)
      const r = await apiFns.createFamily({
        familyName: familyName.trim(),
        nickname: nickname.trim(),
        username: username.trim(),
        pin,
        avatar,
      })
      // 记录本机身份：创建家庭的家长，退出后可一键恢复
      addKnownUser({
        userId: r.user_id,
        nickname: nickname.trim(),
        role: 'parent',
        avatarEmoji: avatar,
        familyName: familyName.trim(),
        username: username.trim(),
      })
      // 注意：这里【不能】invalidate bootstrap —— 否则 bootstrap 立刻重查变成
      // in_family=true，App 根组件会抢先把 Onboarding 整个卸载，用户就看不到
      // 刚生成的邀请码页了。邀请码展示页（ShowCodes）的「开始使用」按钮
      // 点击时才 invalidate，让根组件切进主壳。
      celebrate('big')
      onDone({ child: r.child_invite_code, parent: r.parent_invite_code })
    } catch (e) {
      setErr(e instanceof BackendError ? friendlyErr(e) : String(e))
      setBusy(false)
    }
  }

  return (
    <>
      <Header title="创建家庭" onBack={onBack} />
      <div className="space-y-5 py-2">
        <Field label="家庭名称">
          <Input
            value={familyName}
            onChange={(e) => setFamilyName(e.target.value)}
            placeholder="比如：张家小院"
            maxLength={20}
          />
        </Field>

        <Field label="你的昵称" hint="孩子会看到这个称呼">
          <Input
            value={nickname}
            onChange={(e) => setNickname(e.target.value)}
            placeholder="妈妈 / 爸爸"
            maxLength={12}
          />
        </Field>

        <Field label="用户名" hint="其他设备上用它 + PIN 登录你的账号">
          <Input
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="例如 zhang_mama"
            maxLength={30}
            autoCapitalize="none"
          />
        </Field>

        <Field label="选个头像">
          <AvatarPicker value={avatar} onChange={setAvatar} />
        </Field>

        <Field
          label="家长 PIN（4 位数字，必填）"
          hint="用于登录和审批兑换，孩子拿到手机也改不了规则。"
        >
          <Input
            value={pin}
            onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
            placeholder="••••"
            inputMode="numeric"
            className={cn(!pinOk && 'border-rose-400')}
          />
        </Field>

        {err && <p className="rounded-xl bg-rose-50 px-3 py-2 text-sm text-rose-600">{err}</p>}

        <Button size="lg" className="w-full" disabled={!canSubmit} onClick={submit}>
          {busy ? '创建中…' : '创建'}
        </Button>
      </div>
    </>
  )
}

function JoinFamily({ onBack }: { onBack: () => void }) {
  const qc = useQueryClient()
  const ensureUserId = useSession((s) => s.ensureUserId)
  const addKnownUser = useSession((s) => s.addKnownUser)
  const [code, setCode] = useState('')
  const [username, setUsername] = useState('')
  const [pin, setPin] = useState('')
  const [nickname, setNickname] = useState('')
  const [avatar, setAvatar] = useState('👦')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const pinOk = /^\d{4}$/.test(pin)
  const usernameOk = username.trim().length > 0

  async function submit() {
    setBusy(true)
    setErr('')
    try {
      const uid = ensureUserId()
      await apiFns.setIdentity(uid)
      const r = await apiFns.joinFamily({
        code,
        username: username.trim(),
        pin,
        nickname: nickname.trim() || undefined,
        avatar,
      })
      // joinFamily 不返回 user_id —— 当前身份的 userId 就是 ensureUserId 生成的 uid。
      // 昵称留空时后端会用家长代建的名字，这里先占位，主壳 bootstrap 兜底会纠正。
      addKnownUser({
        userId: uid,
        nickname: nickname.trim() || '新成员',
        role: r.role,
        avatarEmoji: avatar,
      })
      await qc.invalidateQueries({ queryKey: qk.bootstrap })
      celebrate('big')
    } catch (e) {
      setErr(e instanceof BackendError ? friendlyErr(e) : String(e))
      setBusy(false)
    }
  }

  return (
    <>
      <Header title="加入家庭" onBack={onBack} />
      <div className="space-y-5 py-2">
        <Field label="邀请码" hint="问家长要，6 位字母数字">
          <Input
            value={code}
            onChange={(e) =>
              setCode(e.target.value.replace(/[^A-Za-z0-9]/g, '').toUpperCase().slice(0, 8))
            }
            placeholder="ABC123"
            autoCapitalize="characters"
            className="text-center font-mono text-xl tracking-[0.3em]"
          />
        </Field>

        <Field label="你的昵称" hint="如果家长已经帮你建好了，这里可以留空">
          <Input
            value={nickname}
            onChange={(e) => setNickname(e.target.value)}
            placeholder="小明"
            maxLength={12}
          />
        </Field>

        <Field label="用户名" hint="其他设备上用它 + PIN 登录你的账号">
          <Input
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="例如 xiaoming"
            maxLength={30}
            autoCapitalize="none"
          />
        </Field>

        <Field label="PIN（4 位数字）" hint="家长给你设置的，或你自己设的登录密码">
          <Input
            value={pin}
            onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
            inputMode="numeric"
            placeholder="••••"
            className="text-center text-xl tracking-[0.4em]"
          />
        </Field>

        <Field label="选个头像">
          <AvatarPicker value={avatar} onChange={setAvatar} />
        </Field>

        {err && <p className="rounded-xl bg-rose-50 px-3 py-2 text-sm text-rose-600">{err}</p>}

        <Button
          size="lg"
          className="w-full"
          disabled={code.length < 4 || !usernameOk || !pinOk || busy}
          onClick={submit}
        >
          {busy ? '加入中…' : '加入'}
        </Button>
      </div>
    </>
  )
}

function Login({ onBack }: { onBack: () => void }) {
  const qc = useQueryClient()
  const setUserId = useSession((s) => s.setUserId)
  const addKnownUser = useSession((s) => s.addKnownUser)
  const [username, setUsername] = useState('')
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  async function submit() {
    setBusy(true)
    setErr('')
    try {
      const r = await apiFns.login(username.trim(), pin)
      setUserId(r.userId)
      addKnownUser({
        userId: r.userId,
        nickname: r.nickname,
        role: r.role === 'parent' ? 'parent' : 'child',
        token: r.token,
      })
      await apiFns.setIdentity(r.userId)
      // 强制重查 bootstrap（带上新 JWT），身份进来后 App 自动切进主壳
      await qc.invalidateQueries({ queryKey: qk.bootstrap })
    } catch (e) {
      setErr(e instanceof BackendError ? e.message : String(e))
      setBusy(false)
    }
  }

  const pinOk = /^\d{4}$/.test(pin)
  const canSubmit = username.trim().length > 0 && pinOk && !busy

  return (
    <>
      <Header title="登录" onBack={onBack} />
      <div className="space-y-5 py-2">
        <Field label="用户名">
          <Input
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="用户名"
            maxLength={30}
            autoCapitalize="none"
          />
        </Field>

        <Field label="PIN（4 位数字）" hint="你创建/加入家庭时设置的密码">
          <Input
            value={pin}
            onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
            inputMode="numeric"
            placeholder="••••"
            className="text-center text-xl tracking-[0.4em]"
          />
        </Field>

        {err && <p className="rounded-xl bg-rose-50 px-3 py-2 text-sm text-rose-600">{err}</p>}

        <Button size="lg" className="w-full" disabled={!canSubmit} onClick={submit}>
          {busy ? '登录中…' : '登录'}
        </Button>
      </div>
    </>
  )
}

function CodeRow({ label, code, hint }: { label: string; code: string; hint: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <Card className="flex items-center gap-3">
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium text-slate-700">{label}</p>
        <p className="font-mono text-2xl font-bold tracking-[0.2em] text-slate-900">{code}</p>
        <p className="mt-0.5 text-xs text-slate-400">{hint}</p>
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
        {copied ? '已复制' : '复制'}
      </Button>
    </Card>
  )
}

function ShowCodes({ codes }: { codes: { child: string; parent: string } }) {
  const qc = useQueryClient()
  return (
    <div className="flex flex-1 flex-col justify-center py-10">
      <div className="animate-pop-in mb-2 text-6xl">🎉</div>
      <h1 className="text-2xl font-bold text-slate-900">家庭建好了</h1>
      <p className="mt-1.5 text-slate-500">把邀请码发给家人，他们在自己手机上输入就能加入。</p>

      <div className="mt-6 space-y-3">
        <CodeRow label="孩子邀请码" code={codes.child} hint="用这个码加入的人是孩子身份" />
        <CodeRow label="家长邀请码" code={codes.parent} hint="另一位家长用这个码" />
      </div>

      <p className="mt-5 rounded-xl bg-amber-50 px-3.5 py-3 text-sm leading-relaxed text-amber-800">
        随时可以在「我的 → 家庭成员」里再看到这两个码，现在记不住也没关系。
      </p>

      <Button
        size="lg"
        className="mt-6 w-full"
        onClick={() => qc.invalidateQueries({ queryKey: qk.bootstrap })}
      >
        开始使用
      </Button>
    </div>
  )
}
