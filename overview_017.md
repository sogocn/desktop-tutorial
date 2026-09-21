# 017 增量交付总结 · 挑战按「类」互斥、可重复开始

## 结论
规则从「一人同时只能有一个挑战」改成「**同一类同时只能有一个，不同类可并行，结束后可再开**」：
- 类 = `fullstar`（连续满星，含 21 天 / 45 天）与 `signin`（连续签到）。
- 21 天与 45 天同属 fullstar 类，**仍互相互斥**；将来上线的签到类可与满星类同时进行。
- 成功/失败后（终局）的记录不再占用名额 → 同类可重复开始，入场分照付。

## 改动清单
| 层 | 文件 | 内容 |
| -- | -- | -- |
| DB 迁移 | `db/migrations/017_challenge_category.sql` | `challenges.category` 列 + 回填；索引改 `(member_id, category) where status='active'`；`_challenge_category` / `_challenge_category_label`；`start_challenge` 按类互斥；抽 `_challenge_eval`（按类复用）；`challenge_state` 返回 `currents`（每类一条）+ spec 的 `busy` 标记；`kind` 校验放宽为 `^(fullstar\|signin)_[0-9]+$` |
| DB 测试 | `db/tests/test_challenge_category_017.sql` | T1 同类互斥 / T2 跨类并行 / T3 索引兜底 / T4 成功后可重开 / T5 失败后可重开（同类仍唯一）/ T6 读数带 category·busy / T7 `current` 兼容字段 |
| API | `src/api/index.ts` | 新增 `ChallengeCategory`；`ChallengeSpec` 加 `category`/`category_label`/`busy`；`ChallengeCurrent` 加 `category`/`category_label`；`ChallengeState` 加 `currents` |
| 前端 | `src/components/ChallengeCard.tsx` | 改为按类渲染：每张进行中的挑战一块（各自进度 + 各自补救入口）；`busy` 的类禁用开启按钮并标注「XX挑战进行中」 |
| 测试挂接 | `scripts/run-sql-tests.mjs` | 追加 017 套件 |

## 验证
- `npm run db:test`：全绿（016 的 S0–S8 与 017 的 T1–T7 均通过，RC=0）。
- `tsc --noEmit` exit 0；`vite build` exit 0，产物 `dist/assets/index-BV3IAMbR.js`。

## 设计要点
1. **双保险互斥**：应用层 `start_challenge` 检查 + 数据库部分唯一索引 `(member_id, category) where status='active'`——绕过函数直接插也会被拦。
2. **category 由 kind 前缀派生**并落库（不依赖触发器），`kind` 的 check 放宽成前缀+天数模式，**将来加签到类只需改 `_challenge_spec`，不用再动表结构**。
3. **读路径容错**：`_challenge_eval` 遇到没有对应规格的 kind（如规格还没上线的类）返回 null 跳过，避免一条认不出的历史行让整个 `challenge_state` 报错；开启侧仍然严格校验。
4. **兼容字段**：`challenge_state` 保留 `current`（= `currents` 里优先 active 的那条），单类场景的旧断言/调用不受影响。
5. **前端不判定**：只画后端算好的数字，`busy` 由后端给出。

## 回滚
- 代码：`git checkout -f <上一提交>` + 还原 `dist_bak_*`。
- DB：017 为纯增量 + 索引替换，回退需把索引改回 `challenge_one_active_uq`（跨类互斥）或直接保留新索引（语义更宽松，数据仍安全）。
