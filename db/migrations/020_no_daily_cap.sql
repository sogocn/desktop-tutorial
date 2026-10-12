-- =============================================================================
-- 020：每日积分不再设上限
--
-- 需求：每日积分获取不要设置上限。
--
-- 做法：
--   1) families.child_daily_points_cap 的默认值 200 → 0
--   2) 存量家庭一律刷成 0
--
-- _post_ledger 里上限分支的条件是 `f.child_daily_points_cap > 0`，
-- 所以 0 即"不设上限"。这里刻意保留列和判断逻辑本身，
-- 将来若想按家庭重新开闸，只要把该家庭设回正数即可，不用再改代码。
--
-- 注意：child_task_points_cap（孩子自建任务的单项积分上限）不受影响，
-- 那是"单个任务能设多少分"，不是每日上限。
-- =============================================================================

alter table app.families
  alter column child_daily_points_cap set default 0;

update app.families
   set child_daily_points_cap = 0
 where child_daily_points_cap > 0;
