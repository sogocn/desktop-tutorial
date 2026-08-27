/**
 * familyquest 端到端数据层验证（无浏览器）。
 * 直接加载真实迁移 SQL（local + migrations），用 PGlite 模拟应用运行时：
 *   - auth.uid() 身份模拟（和 pglite.adapter.ts 完全一致）
 *   - rpc() 调用（和 src/api/index.ts 的 rpc 包装一致）
 *   - parent_token 通过 verify_parent_pin 真实签发
 * 覆盖 5 项需求的数据流：积分撤销再完成 / 钱包切换+打赏扣除 / 家长配勋章 / 签到系统。
 */
import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const root = join(__dirname, '..')

const PG_TYPE_DATE = 1082
const dateParser = (v) => (v && v.length >= 10 ? v.slice(0, 10) : v)

const pg = await PGlite.create({
  dataDir: 'memory://familyquest-e2e',
  relaxedDurability: true,
  parsers: { [PG_TYPE_DATE]: dateParser },
})

let CURRENT_UID = null
// 仅记录当前身份；GUC 由 rpc 在每次调用时内联设置。
// 不在此做 reset role / set role（security definer 函数自身决定权限，
// 多余的 reset role 会干扰 PGlite exec 批的事务持久化）。
async function setIdentity(userId) {
  CURRENT_UID = userId
}

// rpc 用位置参数调用（和真实 app 的 rpc 包装一致）。
// 每次 rpc 前都先 setIdentity 刷新 GUC，规避 PGlite 参数化路径偶发丢 GUC。
// SQL 字面量转义（仅用于受控输入：uuid/int/date/json）
const sqlLit = (v) => {
  if (v === null) return 'null'
  if (typeof v === 'number') return String(v)
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  if (typeof v === 'object') return `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`
  return `'${String(v).replace(/'/g, "''")}'`
}

// 用 pg.exec（简单协议、单批多语句）把 set_config 和函数调用放在同一次执行里，
// 保证 GUC 对函数调用一定可见（规避 PGlite 参数化/简单协议混用导致的 GUC 偶发丢失）。
// 使用 named 参数记法（p_x => val），避免位置错配。
async function rpc(fn, args = {}) {
  const claims = JSON.stringify({ sub: CURRENT_UID, role: 'authenticated' }).replace(/'/g, "''")
  const call = Object.entries(args).map(([k, v]) => `${k} => ${sqlLit(v)}`).join(', ')
  const sql = `select set_config('request.jwt.claims', '${claims}', false);
    select app.${fn}(${call}) as result;`
  const res = await pg.exec(sql)
  const last = res[res.length - 1]
  const rows = last?.rows ?? []
  return rows[0]?.result
}

const read = (rel) => readFileSync(join(root, rel), 'utf8')
const migDir = join(root, 'db', 'migrations')
const localDir = join(root, 'db', 'local')
const localNames = readdirSync(localDir).filter((f) => f.endsWith('.sql')).sort()
const migNames = readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort()

await pg.exec('reset role;')
await pg.exec(`create table if not exists public.__migrations (name text primary key, applied_at timestamptz not null default now());`)
const files = [
  ...localNames.map((n) => ['local/' + n, read('db/local/' + n)]),
  ...migNames.map((n) => ['migrations/' + n, read('db/migrations/' + n)]),
]
for (const [name, sql] of files) {
  await pg.exec(sql)
  await pg.query('insert into public.__migrations (name) values ($1)', [name])
}

const results = []
const assert = (name, cond, detail = '') => {
  results.push({ name, ok: !!cond, detail })
  console.log(`${cond ? '✓' : '✗'} ${name}${detail ? ' — ' + detail : ''}`)
}
const uuid = () =>
  'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16)
  })

// ===== 引导：创建家庭（爸爸=家长，用 uuid 身份）=====
const parentUid = uuid()
await setIdentity(parentUid)
const createRes = await rpc('create_family', {
  p_family_name: 'E2E家庭',
  p_nickname: '爸爸',
})
const familyId = createRes.family_id
const parentId = createRes.member_id
const childCode = createRes.child_invite_code
assert('创建家庭成功', familyId && parentId, `family=${familyId} parent=${parentId}`)

// 加一个孩子（用另一个 uuid 身份 + 孩子邀请码）
const childAuthUid = uuid()
await setIdentity(childAuthUid)
const joinRes = await rpc('join_family', {
  p_code: childCode,
  p_nickname: '小明',
  p_avatar: '🧒',
})
const childId = joinRes.member_id          // member_id：作为任务 assignee / 调分对象
const childUserId = childAuthUid            // user_id = 加入时 auth.uid()，即本 harness 设定的孩子身份
assert('加入孩子成员', childId && childUserId, `child=${childId} user=${childUserId}`)

// 家长签发 parent_token：先 set_pin（应用实际流程：建家庭后家长设 PIN），再 verify_parent_pin
await setIdentity(parentUid)
const setPin = await rpc('set_pin', { p_pin: '1234' })
assert('家长设置PIN', setPin === true, `set_pin=${setPin}`)
const pinRes = await rpc('verify_parent_pin', { p_pin: '1234', p_member_id: parentId })
const parentToken = pinRes.token
assert('家长PIN验证签发token', parentToken, `token=${parentToken?.slice(0, 8)}…`)

// 余额读取辅助（没有 get_balance 函数，直接读 members 表）
async function balance(mid) {
  const r = await pg.query('select points_balance from app.members where id=$1', [mid])
  return r.rows[0]?.points_balance ?? 0
}

console.log('\n=== 需求1: 积分撤销再完成（核心bug修复）===')
{
  await setIdentity(childUserId)
  // 建一个孩子的任务（create_task 由家长或本人；孩子建自己名下的）
  const task = await rpc('create_task', {
    p_assignee_id: childId,
    p_title: 'E2E任务',
    p_icon_emoji: '⭐',
    p_color: 'sky',
    p_schedule_kind: 'once',
    p_starts_on: '2026-08-21',
    p_completion_points: 5,
  })
  const taskId = task.task_id || task.id || task
  const DATE = '2026-08-21'
  const b0 = await balance(childId)
  const c1 = await rpc('complete_occurrence', { p_task_id: taskId, p_date: DATE })
  const b1 = await balance(childId)
  const u1 = await rpc('uncomplete_occurrence', { p_task_id: taskId, p_date: DATE })
  const b2 = await balance(childId)
  const c2 = await rpc('complete_occurrence', { p_task_id: taskId, p_date: DATE })
  const b3 = await balance(childId)
  assert('完成任务发放+5', b1 === b0 + 5, `${b0}->${b1} (awarded=${c1.points_awarded})`)
  assert('撤销完成回退-5', b2 === b0, `${b1}->${b2}`)
  assert('再次完成二次发放+5(修复点)', b3 === b0 + 5 && b3 === b1, `${b2}->${b3} (关键bug)`)
  // 重复点完成幂等
  const c3 = await rpc('complete_occurrence', { p_task_id: taskId, p_date: DATE })
  const b4 = await balance(childId)
  assert('重复完成幂等不重复发分', c3.already === true && b4 === b3, `already=${c3.already} ${b3}->${b4}`)
  // 流水账只追加（铁律5）：重完成后应有 2 条 primary（seq 0、1），且撤销产生了 1 条 reversal
  const ledger = await pg.query(
    `select entry_kind, source_seq, source_id from app.point_ledger
      where member_id = $1 and (source_type='completion' or source_type='reversal')
      order by id`,
    [childId],
  )
  const primaries = ledger.rows.filter((r) => r.entry_kind === 'primary')
  const reversals = ledger.rows.filter((r) => r.entry_kind === 'reversal')
  assert('流水账只追加(2条primary+1条reversal)',
    primaries.length >= 2 && reversals.length >= 1,
    `primary=${primaries.length} reversal=${reversals.length} seqs=${primaries.map((p) => p.source_seq).join(',')}`)
}

console.log('\n=== 需求2/3: 钱包切换 + 家长打赏/扣除 ===')
{
  // 钱包切换是纯前端（setViewingMember），数据层验证：家长对指定 childId 调分
  await setIdentity(parentUid)
  const b0 = await balance(childId)
  const reward = await rpc('adjust_member_points', {
    p_parent_token: parentToken,
    p_member_id: childId,
    p_delta: 20,
    p_reason: '家长打赏',
  })
  const b1 = await balance(childId)
  const deduct = await rpc('adjust_member_points', {
    p_parent_token: parentToken,
    p_member_id: childId,
    p_delta: -10,
    p_reason: '家长扣除',
  })
  const b2 = await balance(childId)
  assert('家长打赏+20', b1 === b0 + 20, `${b0}->${b1} delta=${reward.delta}`)
  assert('家长扣除-10', b2 === b1 - 10, `${b1}->${b2} delta=${deduct.delta}`)
  // 家长不能给自己调分
  let selfErr = null
  try {
    await rpc('adjust_member_points', { p_parent_token: parentToken, p_member_id: parentId, p_delta: 5 })
  } catch (e) { selfErr = e.message }
  assert('家长不能给自己调分(防护)', /FORBIDDEN/.test(selfErr || ''), `err=${selfErr}`)
  // 余额不足不能超额扣
  let negErr = null
  try {
    await rpc('adjust_member_points', { p_parent_token: parentToken, p_member_id: childId, p_delta: -100000 })
  } catch (e) { negErr = e.message }
  assert('超额扣除被拦截', /NOT_ENOUGH_POINTS|balance/.test(negErr || ''), `err=${negErr}`)
}

console.log('\n=== 需求4: 家长配置勋章 ===')
{
  await setIdentity(parentUid)
  const rule = { kind: 'streak_days', dimension: 'active', threshold: 7 }
  const bid = await rpc('upsert_badge', {
    p_name: '连续7天活跃',
    p_rule: rule,
    p_parent_token: parentToken,
    p_emoji: '🔥',
    p_tier: 'silver',
    p_description: '连续7天每天至少完成一个任务',
  })
  assert('家长新建勋章(连续活跃7天)', bid, `badge_id=${bid}`)
  if (bid) {
    const list = await rpc('list_family_badges', { p_parent_token: parentToken })
    assert('勋章进入家庭列表', Array.isArray(list) && list.some((b) => b.id === bid),
      `count=${list?.length}`)
    const prog = await rpc('list_badges_with_progress', { p_member_id: childId })
    assert('孩子勋章墙能看到该勋章', Array.isArray(prog) && prog.some((b) => b.badge_id === bid),
      `wall count=${prog?.length}`)
    const del = await rpc('delete_badge', { p_id: bid, p_parent_token: parentToken })
    assert('家长删除勋章', del && (del.deleted === 1 || del.ok !== false), `del=${JSON.stringify(del)}`)
  }
  // 非法规则被拒
  let badRuleErr = null
  try {
    await rpc('upsert_badge', { p_name: '坏规则', p_rule: { kind: 'bogus' }, p_parent_token: parentToken })
  } catch (e) { badRuleErr = e.message }
  assert('非法勋章规则被拒', /BAD_BADGE_RULE/.test(badRuleErr || ''), `err=${badRuleErr}`)
}

console.log('\n=== 需求5: 签到系统 ===')
{
  await setIdentity(childUserId)
  // 签今天（family_today 由时区决定；用 get_signin_summary 拿今天）
  const sum0 = await rpc('get_signin_summary', { p_member_id: childId })
  const today = sum0.today
  const b0 = await balance(childId)
  const s = await rpc('do_signin', { p_date: today })
  const b1 = await balance(childId)
  assert('签到今日+2分', b1 === b0 + 2, `${b0}->${b1} awarded=${s.points_awarded}`)
  assert('签到返回结构正确', s.signed === true && s.summary, `signed=${s.signed}`)
  // 重复签今天幂等
  const s2 = await rpc('do_signin', { p_date: today })
  const b2 = await balance(childId)
  assert('重复签到幂等不重复发分', s2.already === true && b2 === b1, `already=${s2.already}`)
  // 完成≥1任务触发活跃
  const task = await rpc('create_task', {
    p_assignee_id: childId, p_title: '活跃任务', p_completion_points: 3, p_schedule_kind: 'once', p_starts_on: today,
  })
  const taskId = task.task_id || task.id
  await rpc('complete_occurrence', { p_task_id: taskId, p_date: today })
  const sumA = await rpc('get_signin_summary', { p_member_id: childId })
  assert('完成任务触发今日活跃', sumA.active_today === true, `active_today=${sumA.active_today}`)
  // 补签卡：先签连续天攒卡（需要 evaluate_streaks 给 7天奖励）
  // 直接给一张 retro_signin 卡来验证消耗路径（绕过攒卡依赖）
  await pg.exec(`insert into app.member_cards (member_id, kind, qty) values ('${childId}', 'retro_signin', 1) on conflict (member_id, kind) do update set qty = app.member_cards.qty + 1`)
  const retro = await rpc('use_retro_card', {
    p_kind: 'retro_signin', p_date: '2026-08-15', p_member_id: childId,
  })
  assert('补签卡消耗并补签到', retro && (retro.ok !== false), `retro=${JSON.stringify(retro)?.slice(0, 80)}`)
  const sumR = await rpc('get_signin_summary', { p_member_id: childId })
  assert('补签后补签卡库存-1', (sumR.retro_cards?.retro_signin ?? 0) === 0, `cards=${JSON.stringify(sumR.retro_cards)}`)
  // 连续奖励：构造连续3天签到，验证 evaluate_streaks 给分
  for (const d of ['2026-08-10', '2026-08-11', '2026-08-12']) {
    await rpc('do_signin', { p_date: d }).catch(() => {})
  }
  const sum3 = await rpc('get_signin_summary', { p_member_id: childId })
  assert('连续签到统计存在', sum3.streak && typeof sum3.streak.signin === 'number',
    `signin_streak=${sum3.streak?.signin}`)
}

const pass = results.filter((r) => r.ok).length
const fail = results.filter((r) => !r.ok).length
console.log(`\n==== E2E 结果: ${pass} 通过 / ${fail} 失败 / 共 ${results.length} ====`)
await pg.close()
process.exit(fail === 0 ? 0 : 1)
