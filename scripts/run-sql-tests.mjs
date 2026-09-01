// 在内存 PGlite 上跑一遍 db/local + db/migrations + db/tests，验证 SQL 层。
// 不碰浏览器的 IndexedDB，每次都是全新数据库。
import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (p) => readFileSync(join(root, p), 'utf8')
const listSql = (dir) =>
  readdirSync(join(root, dir))
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((f) => `${dir}/${f}`)

const notices = []
const db = await PGlite.create()
db.onNotification?.(() => {})

async function run(label, sql) {
  try {
    await db.exec(sql, {
      onNotice: (n) => notices.push(n.message ?? String(n)),
    })
  } catch (err) {
    console.error(`\n✗ ${label}`)
    console.error(`  ${err.message}`)
    if (err.position) {
      const at = Number(err.position)
      const head = sql.slice(0, at)
      const line = head.split('\n').length
      console.error(`  位置：第 ${line} 行 → ${sql.split('\n')[line - 1]?.trim()}`)
    }
    process.exit(1)
  }
}

console.log('› 应用本地 shim 与迁移')
for (const f of [...listSql('db/local'), ...listSql('db/migrations')]) {
  await run(f, read(f))
  console.log(`  ✓ ${f}`)
}

console.log('\n› 运行断言')
notices.length = 0
// 每个文件自带 begin/rollback，互不污染。新增断言文件记得挂到这里。
const suites = ['db/tests/test_expand.sql', 'db/tests/test_signin.sql', 'db/tests/test_parent_multiusers.sql', 'db/tests/test_checkin_012.sql', 'db/tests/test_shop_badges_013.sql']
for (const f of suites) {
  console.log(`  › ${f}`)
  await run(f, read(f))
}
// PGlite 会把内部的 catalog / 事务回滚调试信息也当 notice 抛出来，滤掉
const noise = /^(#|rehashing|aborting transaction)/
for (const m of notices) if (!noise.test(m)) console.log(m)

console.log('\n✓ SQL 层全部通过')
await db.close()
