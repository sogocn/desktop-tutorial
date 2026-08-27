# CLAUDE.md — 家庭任务日历

本地优先的家庭任务应用（家长派任务 / 孩子自建任务，日历展示，积分·勋章·商城奖励）。
数据存在每台设备的浏览器里（PGlite = 浏览器内 WASM Postgres + IndexedDB），**不做任何上传**。

## 六条铁律（改动前先读）

1. **测试先行。** 所有 SQL 业务逻辑先写断言再写实现。入口 `scripts/run-sql-tests.mjs`
   （`npm run db:test`）。断言包在 `begin/rollback` 里按段执行，目前 117 项全绿
   （A 展开引擎 / B 排期校验 / C materialize / D 业务动作 / E 记账 / F 阶段奖励 / G 建任务 / H 商城）。
   动 `db/` 下任何文件后，先跑测试再谈别的。

2. **零迁移。** `db/migrations/*.sql` 是本地和将来上云**唯一一份** DDL，双方共用。
   本地独有差异（如 PGlite shim）只允许收敛在 `db/local/`，绝不动迁移文件去迁就本地。

3. **RLS 从第一天。** 关键表对 `authenticated` 角色只开放 `SELECT`；所有写操作只经
   `SECURITY DEFINER` 函数（`app.*` schema）。PGlite 默认是超级用户、会绕过 RLS，
   所以 adapter 每次查询前必须：`reset role` → `set_config('request.jwt.claims', …)` →
   `set role authenticated`。本地不验证 RLS，上云才暴露越权——这一步省不得。

4. **时间用字符串。** `occurrence_date` 类型是 `date`；JS 侧永远是 `'YYYY-MM-DD'` 字符串，
   **绝不** `new Date('2026-08-13')` 之类（时区会炸）。跨时区计算统一用 `Date.UTC`。
   见 `src/lib/date.ts`。

5. **不可变流水账。** `point_ledger` 只追加，不更新不删除。撤销 = 追加一条反向
   `reversal` 记录。余额允许有缓存列（`points_balance`），但**必须由流水兜底**，
   任何逻辑都不得直接改余额列而不写流水。对账口径：流水合计 === 余额缓存（测试 H16）。

6. **本地身份模拟。** 没有 auth 服务。用 `crypto.randomUUID()` 冒充 `auth.uid()` 的
   `sub`（`src/store/session.ts`）。`parentToken` **绝不落盘**（刷新需重输 PIN）。
   上云时这套身份直接换成真实 JWT，业务代码不改。

## 架构要点

- 数据层只有 `src/lib/backend` 一个出口。业务代码 `import { getBackend }`，**禁止**直接
  `import @electric-sql/pglite`。换后端（如 M5 上云）只换 adapter 实现，上层零改动。
- 迁移 SQL 通过 `import.meta.glob('/db/...', {query:'?raw', eager:true})` 在打包时内联，
  所以 `dist/` 自带全部 DDL，离线也能建库。
- 前端：React 19 + TS + Vite 7 + Tailwind v4。状态用 Zustand（persist 只落 userId /
  viewingMemberId）；服务端数据用 TanStack React Query（queryKey 失效策略见 `src/hooks/useApp.ts`）。

## 常用命令

```
npm install        # 首次
npm run dev        # 本地开发，默认 http://localhost:5173
npm run db:test    # SQL 117 项断言
npm run build      # tsc -b && vite build → dist/
npm run preview    # 预览生产构建
```

## 安全红线

- 不引入任何会向外部发请求的逻辑（家庭数据不上云是本应用前提）。
- 新增写操作必须走 `app.*` 函数 + RLS，不允许前端拼任意 SQL 直写表。
