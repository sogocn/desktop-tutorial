import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { pool } from './db'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')

/**
 * 服务端一次性迁移运行器。
 * 顺序：先 db/local/000_shim.sql（自建 raw Postgres 没有 anon/authenticated
 * 角色和 auth.uid()/auth.jwt()，必须由 shim 补出来），再按文件名排序跑
 * db/migrations/*.sql。已应用的文件名记在 public.__migrations，幂等。
 *
 * 注意：shim 注释说"不要上传到 CloudBase/Supabase"——那是因为那两家自带这些。
 * 我们走自托管 raw Postgres，shim 必须跑。
 */
async function main() {
  const client = await pool.connect()
  try {
    await client.query(`
      create table if not exists public.__migrations (
        name text primary key,
        applied_at timestamptz not null default now()
      );
    `)

    const files: [string, string][] = []
    const shim = path.join(ROOT, 'db/local/000_shim.sql')
    if (fs.existsSync(shim)) files.push([shim, fs.readFileSync(shim, 'utf8')])
    const migDir = path.join(ROOT, 'db/migrations')
    for (const f of fs.readdirSync(migDir).sort()) {
      if (f.endsWith('.sql')) {
        files.push([path.join(migDir, f), fs.readFileSync(path.join(migDir, f), 'utf8')])
      }
    }

    for (const [p, sql] of files) {
      const name = path.basename(p)
      const { rows } = await client.query(
        'select count(*)::int as n from public.__migrations where name=$1',
        [name],
      )
      if (rows[0].n > 0) {
        console.log(`skip  ${name}`)
        continue
      }
      console.log(`apply ${name}`)
      await client.query(sql)
      await client.query('insert into public.__migrations (name) values ($1)', [name])
    }
    console.log('migrations done')
  } finally {
    client.release()
    await pool.end()
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
