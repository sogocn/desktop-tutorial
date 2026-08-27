// 复现脚本：只加载 shim + 迁移 + test_repro_join.sql，验证「创建家庭→邀请码→加入」真实链路。
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

async function run(label, sql) {
  try {
    await db.exec(sql, { onNotice: (n) => notices.push(n.message ?? String(n)) })
  } catch (err) {
    console.error(`\n✗ ${label}`)
    console.error(`  ${err.message}`)
    process.exit(1)
  }
}

console.log('› 应用本地 shim 与迁移')
for (const f of [...listSql('db/local'), ...listSql('db/migrations')]) {
  await run(f, read(f))
  console.log(`  ✓ ${f}`)
}

console.log('\n› 复现 create_family → join_family 链路')
notices.length = 0
await run('db/tests/test_repro_join.sql', read('db/tests/test_repro_join.sql'))
const noise = /^(#|rehashing|aborting transaction)/
for (const m of notices) if (!noise.test(m)) console.log(m)

console.log('\n✓ 复现链路通过')
await db.close()
