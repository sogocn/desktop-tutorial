# 016 增量交付总结 · 满星挑战（21 天 / 45 天）

## 结论
孩子花积分开一场「满星挑战」：窗口内累计满星达标即成功，发积分 + 送一张补签/补满星卡；漏太多先给**失败预警**，可买商城的补满星卡把漏掉那天补成满星，挑战自动继续。
判定**全部从 `member_day.fullstar` 派生**，挑战表只存窗口与终局结论——买卡补漏后满星数自然回升，不需要额外的「复活」接口。

## 规格（后端 `_challenge_spec` 单一真相源）
| 挑战 | 窗口 | 达标满星 | 容错 | 入场费 | 成功奖励 |
| -- | -- | -- | -- | -- | -- |
| 21 天满星 | 21 天 | 20 天 | 漏 1 天 | 20 分 | +100 分 · 补签卡 ×1 |
| 45 天满星 | 45 天 | 42 天 | 漏 3 天 | 30 分 | +300 分 · 补满星卡 ×1 |

- 入场费**不退**；失败判定 = 漏 ≥ (窗口 − 达标) + 1 天（21 天漏 2 天、45 天漏 4 天）。
- 补救用的「补满星卡」沿用 013 商城既有商品（默认 120 分），未新增价格体系。

## 改动清单
| 层 | 文件 | 内容 |
| -- | -- | -- |
| DB 迁移 | `db/migrations/016_challenge.sql` | `app.challenges` 表 + 部分唯一索引（一人仅一条 active）+ RLS；`_challenge_spec` / `start_challenge` / `challenge_state`；`point_ledger` 枚举加 `challenge` |
| DB 测试 | `db/tests/test_challenge_016.sql` | S0–S8 九组断言（已挂入 `run-sql-tests.mjs`） |
| API | `src/api/index.ts` | `ChallengeKind` / `ChallengeSpec` / `ChallengeCurrent` / `ChallengeState` 类型 + `challengeState()` / `startChallenge(kind)` |
| Hook | `src/hooks/useApp.ts` | `useChallengeState()`、`useStartChallenge()`、`useRescueChallenge()`；任务动作与打卡后 invalidate `challenge` |
| 前端 | `src/components/ChallengeCard.tsx`（新） | 挑战卡 + 进度条 + 失败预警 + 「购买满星卡补救」 |
| 前端 | `src/pages/TodayPage.tsx` | 今天视图、且仅孩子角色渲染 `ChallengeCard` |

## 验证
- `npm run db:test`：全绿（含 016 的 S0–S8）。
- `tsc --noEmit` exit 0；`npm run build` exit 0，产物 `dist/assets/index-CGqz84kf.js`。
- 部署 `lhins-5ykh5hf2`（175.24.138.109）：迁移 `apply 016_challenge.sql` RC=0；`dist/index.html` 已引用新产物。
- 接口级回归 `regress_016_api.mjs`：**14/14 PASS**（规格数值、开启扣费 200→180、进度回落、开当天不误判失败、剩余天数、进行中互斥 CHALLENGE_ACTIVE、商城补满星卡在售）。

## 设计要点
1. **两级失败**：`failing` 是派生预警（可买卡补救），只有窗口结束仍未达标才落 `status='failed'`（终局）。
2. **今天不算漏**：`days_done` 上界取 `min(昨天, 窗口末)`，避免当天下午被误判失败。
3. **惰性发奖**：`challenge_state()` 读取时判定成功并落账发分/发卡；`uq_ledger_source` 唯一约束 + `update where status='active'` 双保险防重发。
4. **原子隔离**：取「当前挑战」按 `(status='active') desc, created_at desc` 排序规避事务内 `now()` 撞出相同 `created_at`。
5. **零新增购买逻辑**：补救 = 013 商城 `redeem`（买补满星卡）+ 010 `use_retro_card`（补漏那天）。
6. **孩子可见性**：与签到卡同模式，家长「视孩子」看不到孩子的挑战（须用孩子会话登录）。

## 回滚
- 代码：`git checkout -f <上一提交>` + 还原 `dist_bak_*`。
- DB：016 为纯增量（新表 + 新函数 + 枚举值），`drop table app.challenges` 与 `drop function` 即可，不影响既有数据。
