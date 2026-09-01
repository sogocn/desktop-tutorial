-- =============================================================================
-- test_expand.sql —— 展开引擎 + 记账核心断言
-- =============================================================================
-- 跑法：npm run db:test（scripts/run-sql-tests.mjs 里在内存 PGlite 上跑一遍）
-- 整个脚本包在一个事务里，最后 ROLLBACK，不会留下任何数据。
--
-- 展开引擎是这个项目最容易错、又最难被用户发现错的地方：
-- 少展开一天 = 孩子少一次挣分机会，谁都不会去核对日历。
-- 所以这里的断言只增不减。
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 固定数据
-- ---------------------------------------------------------------------------
insert into app.families (id, name, timezone, day_cutoff_hour)
values ('11111111-1111-1111-1111-111111111111', '测试之家', 'Asia/Shanghai', 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   '2a222222-2222-2222-2222-222222222222', '爸爸', 'parent'),
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
   '3a333333-3333-3333-3333-333333333333', '小明', 'child'),
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111',
   '4a444444-4444-4444-4444-444444444444', '小红', 'child');

insert into app.tasks
  (id, family_id, assignee_id, created_by, title, schedule_kind, recurrence,
   starts_on, ends_on, max_occurrences, completion_points, checkin_points, checkin_daily_limit)
values
  -- T1 每日
  ('00000000-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '每日阅读', 'recurring', '{"freq":"daily"}', '2026-01-01', null, null, 5, 2, 3),
  -- T2 工作日
  ('00000000-0000-4000-8000-000000000002', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '写作业', 'recurring', '{"freq":"weekly","byweekday":[1,2,3,4,5]}', '2026-01-01', null, null, 3, 0, 1),
  -- T3 周末
  ('00000000-0000-4000-8000-000000000003', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '大扫除', 'recurring', '{"freq":"weekly","byweekday":[6,7]}', '2026-01-01', null, null, 3, 0, 1),
  -- T4 每月 31 号，skip
  ('00000000-0000-4000-8000-000000000004', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '月底整理(skip)', 'recurring',
   '{"freq":"monthly","bymonthday":[31],"month_overflow":"skip"}', '2024-01-01', null, null, 3, 0, 1),
  -- T5 每月 31 号，last_day
  ('00000000-0000-4000-8000-000000000005', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '月底整理(last_day)', 'recurring',
   '{"freq":"monthly","bymonthday":[31],"month_overflow":"last_day"}', '2024-01-01', null, null, 3, 0, 1),
  -- T6 单日
  ('00000000-0000-4000-8000-000000000006', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '看牙医', 'once', '{"freq":"once","date":"2026-08-12"}', '2026-08-12', null, null, 8, 0, 1),
  -- T7 每日 + until
  ('00000000-0000-4000-8000-000000000007', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '寒假日记', 'recurring', '{"freq":"daily"}', '2026-01-01', '2026-01-10', null, 3, 0, 1),
  -- T8 每日 + count 5
  ('00000000-0000-4000-8000-000000000008', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '五天挑战', 'recurring', '{"freq":"daily"}', '2026-01-01', null, 5, 3, 0, 1),
  -- T9 每日 + 暂停 01-05 ~ 01-07
  ('00000000-0000-4000-8000-000000000009', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '练琴', 'recurring', '{"freq":"daily"}', '2026-01-01', null, null, 3, 0, 1),
  -- T10 每月 29 号，skip（闰年）
  ('00000000-0000-4000-8000-00000000000a', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '月末复盘', 'recurring',
   '{"freq":"monthly","bymonthday":[29],"month_overflow":"skip"}', '2024-01-01', null, null, 3, 0, 1),
  -- T11 每周一 + count 3
  ('00000000-0000-4000-8000-00000000000b', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '三次周会', 'recurring', '{"freq":"weekly","byweekday":[1]}', '2026-01-01', null, 3, 3, 0, 1),
  -- T12 每月 1 号和 15 号
  ('00000000-0000-4000-8000-00000000000c', '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   '零花钱结算', 'recurring',
   '{"freq":"monthly","bymonthday":[1,15]}', '2026-01-01', null, null, 3, 0, 1);

insert into app.task_pause_periods (task_id, starts_on, ends_on, reason)
values ('00000000-0000-4000-8000-000000000009', '2026-01-05', '2026-01-07', '老师休假');


-- ###########################################################################
-- A. 展开引擎
-- ###########################################################################
do $$
declare n int; d date;
begin
  -- A1 每日：2026 年 1 月 31 天
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000001','2026-01-01','2026-01-31');
  assert n = 31, format('A1 每日1月应 31 天，实际 %s', n);

  -- A2 starts_on 边界：起始日之前不展开
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000001','2025-12-25','2026-01-02');
  assert n = 2, format('A2 应只展开 01-01/01-02 共 2 天，实际 %s', n);

  -- A3 起始日之前完全为空
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000001','2025-01-01','2025-12-31');
  assert n = 0, format('A3 起始日之前应为 0，实际 %s', n);

  -- A4 跨年
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000001','2026-12-30','2027-01-02');
  assert n = 4, format('A4 跨年 4 天，实际 %s', n);

  -- A5 工作日：2026-01 有 22 个工作日（1/1 是周四）
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000002','2026-01-01','2026-01-31');
  assert n = 22, format('A5 工作日应 22 天，实际 %s', n);

  -- A6 工作日不含周六（2026-01-03 是周六）
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000002','2026-01-03','2026-01-03');
  assert n = 0, 'A6 工作日任务不应出现在周六';

  -- A7 工作日含周一（2026-01-05）
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000002','2026-01-05','2026-01-05');
  assert n = 1, 'A7 工作日任务应出现在周一';

  -- A8 周末：2026-01 有 5 个周六 + 4 个周日 = 9
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000003','2026-01-01','2026-01-31');
  assert n = 9, format('A8 周末应 9 天，实际 %s', n);

  -- A9 每月 31 号 skip：2026 全年只有 7 个月有 31 号
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000004','2026-01-01','2026-12-31');
  assert n = 7, format('A9 每月31号(skip) 2026 应 7 次，实际 %s', n);

  -- A10 每月 31 号 skip：2 月一次都不出现
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000004','2026-02-01','2026-02-28');
  assert n = 0, 'A10 每月31号(skip) 不应出现在 2 月';

  -- A11 每月 31 号 last_day：2026-02 落在 02-28（平年）
  select min(e.dt) into d from app.expand_task('00000000-0000-4000-8000-000000000005','2026-02-01','2026-02-28') as e(dt);
  assert d = date '2026-02-28', format('A11 应落在 2026-02-28，实际 %s', d);

  -- A12 每月 31 号 last_day：闰年 2024-02 落在 02-29
  select min(e.dt) into d from app.expand_task('00000000-0000-4000-8000-000000000005','2024-02-01','2024-02-29') as e(dt);
  assert d = date '2024-02-29', format('A12 闰年应落在 2024-02-29，实际 %s', d);

  -- A13 每月 31 号 last_day：4 月（30 天）落在 04-30
  select min(e.dt) into d from app.expand_task('00000000-0000-4000-8000-000000000005','2026-04-01','2026-04-30') as e(dt);
  assert d = date '2026-04-30', format('A13 应落在 2026-04-30，实际 %s', d);

  -- A14 每月 31 号 last_day：1 月直接命中 31 号，且只有一条（不能和月末规则重复计数）
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000005','2026-01-01','2026-01-31');
  assert n = 1, format('A14 1 月应恰好 1 条，实际 %s', n);

  -- A15 每月 31 号 last_day：全年 12 个月每月一次
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000005','2026-01-01','2026-12-31');
  assert n = 12, format('A15 last_day 全年应 12 次，实际 %s', n);

  -- A16 闰年 29 号 skip：2024-02-29 存在
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-00000000000a','2024-02-01','2024-02-29');
  assert n = 1, format('A16 闰年 2/29 应出现，实际 %s', n);

  -- A17 平年 29 号 skip：2026-02 不出现
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-00000000000a','2026-02-01','2026-02-28');
  assert n = 0, 'A17 平年 2 月不应出现 29 号';

  -- A18 单日任务：范围内恰好 1 条且日期正确
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000006','2026-08-01','2026-08-31');
  assert n = 1, format('A18 单日任务应 1 条，实际 %s', n);
  select min(e.dt) into d from app.expand_task('00000000-0000-4000-8000-000000000006','2026-08-01','2026-08-31') as e(dt);
  assert d = date '2026-08-12', format('A18b 日期应为 2026-08-12，实际 %s', d);

  -- A19 单日任务：范围外为空
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000006','2026-09-01','2026-09-30');
  assert n = 0, 'A19 单日任务不应出现在范围外';

  -- A20 until：ends_on 当天要包含在内
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000007','2026-01-01','2026-01-31');
  assert n = 10, format('A20 until 应 10 天，实际 %s', n);
  select max(e.dt) into d from app.expand_task('00000000-0000-4000-8000-000000000007','2026-01-01','2026-01-31') as e(dt);
  assert d = date '2026-01-10', format('A20b until 当天应包含，实际 %s', d);

  -- A21 count 截断：每日 count=5
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000008','2026-01-01','2026-12-31');
  assert n = 5, format('A21 count=5 应 5 天，实际 %s', n);
  select max(e.dt) into d from app.expand_task('00000000-0000-4000-8000-000000000008','2026-01-01','2026-12-31') as e(dt);
  assert d = date '2026-01-05', format('A21b 第 5 次应是 01-05，实际 %s', d);

  -- A22 count 截断在查询窗口之外也生效（只查 3 月，应为 0）
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000008','2026-03-01','2026-03-31');
  assert n = 0, 'A22 count 用完后不应再展开';

  -- A23 count + weekly：每周一 3 次 = 01-05 / 01-12 / 01-19
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-00000000000b','2026-01-01','2026-12-31');
  assert n = 3, format('A23 每周一 count=3 应 3 次，实际 %s', n);
  select max(e.dt) into d from app.expand_task('00000000-0000-4000-8000-00000000000b','2026-01-01','2026-12-31') as e(dt);
  assert d = date '2026-01-19', format('A23b 第 3 个周一应是 01-19，实际 %s', d);

  -- A24 暂停区间：1 月 31 天 - 3 天 = 28
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000009','2026-01-01','2026-01-31');
  assert n = 28, format('A24 暂停 3 天后应 28 天，实际 %s', n);

  -- A25 暂停区间边界：起始当天被排除
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000009','2026-01-05','2026-01-05');
  assert n = 0, 'A25 暂停起始日应被排除';

  -- A26 暂停区间边界：结束当天被排除
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000009','2026-01-07','2026-01-07');
  assert n = 0, 'A26 暂停结束日应被排除';

  -- A27 暂停区间边界：前一天仍在
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000009','2026-01-04','2026-01-04');
  assert n = 1, 'A27 暂停前一天应保留';

  -- A28 暂停区间边界：后一天仍在
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-000000000009','2026-01-08','2026-01-08');
  assert n = 1, 'A28 暂停后一天应保留';

  -- A29 每月 1 号 + 15 号：1 月两条
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-00000000000c','2026-01-01','2026-01-31');
  assert n = 2, format('A29 每月 1/15 号应 2 条，实际 %s', n);

  -- A30 每月 1 号 + 15 号：全年 24 条
  select count(*) into n from app.expand_task('00000000-0000-4000-8000-00000000000c','2026-01-01','2026-12-31');
  assert n = 24, format('A30 全年应 24 条，实际 %s', n);

  -- A31 展开结果必须升序
  assert not exists (
    select 1 from (
      select s.dt, lag(s.dt) over (order by s.rn) as prev
        from (select e.dt, row_number() over () as rn
                from app.expand_task('00000000-0000-4000-8000-000000000001',
                                     '2026-01-01','2026-01-31') as e(dt)) s
    ) t where t.prev is not null and t.dt < t.prev
  ), 'A31 展开结果应升序';

  raise notice '  [A] 展开引擎 31 项 ✓';
end $$;


-- ###########################################################################
-- B. recurrence 形状校验
-- ###########################################################################
do $$
begin
  assert     app.recurrence_is_valid('{"freq":"daily"}'::jsonb),                     'B1';
  assert     app.recurrence_is_valid('{"freq":"once","date":"2026-01-01"}'::jsonb),  'B2';
  assert     app.recurrence_is_valid('{"freq":"weekly","byweekday":[1,7]}'::jsonb),  'B3';
  assert     app.recurrence_is_valid('{"freq":"monthly","bymonthday":[31],"month_overflow":"last_day"}'::jsonb), 'B4';
  assert not app.recurrence_is_valid('{"freq":"yearly"}'::jsonb),                    'B5 未知 freq 应拒绝';
  assert not app.recurrence_is_valid('{"freq":"weekly"}'::jsonb),                    'B6 weekly 缺 byweekday 应拒绝';
  assert not app.recurrence_is_valid('{"freq":"weekly","byweekday":[0]}'::jsonb),    'B7 星期 0 应拒绝（ISO 从 1 开始）';
  assert not app.recurrence_is_valid('{"freq":"weekly","byweekday":[8]}'::jsonb),    'B8 星期 8 应拒绝';
  assert not app.recurrence_is_valid('{"freq":"monthly","bymonthday":[32]}'::jsonb), 'B9 32 号应拒绝';
  assert not app.recurrence_is_valid('{"freq":"monthly","bymonthday":[1],"month_overflow":"wrap"}'::jsonb),
                                                                                     'B10 未知 overflow 应拒绝';
  assert not app.recurrence_is_valid('{"freq":"once"}'::jsonb),                      'B11 once 缺 date 应拒绝';
  assert not app.recurrence_is_valid('{"freq":"once","date":"2026/01/01"}'::jsonb),  'B12 日期格式错应拒绝';
  raise notice '  [B] recurrence 校验 12 项 ✓';
end $$;


-- ###########################################################################
-- C. materialize：防刷分第一道闸
-- ###########################################################################
do $$
declare o app.task_occurrences%rowtype; ok boolean;
begin
  -- C1 合法日期可以落库（2026-01-02 周五）
  o := app.materialize('00000000-0000-4000-8000-000000000002','2026-01-02');
  assert o.id is not null, 'C1 合法日期应能落库';
  assert o.snap_title = '写作业', 'C1b 应快照标题';

  -- C2 幂等：再落一次是同一行
  assert (app.materialize('00000000-0000-4000-8000-000000000002','2026-01-02')).id = o.id,
         'C2 materialize 应幂等';

  -- C3 非法日期（周六）必须被拒
  ok := false;
  begin
    perform app.materialize('00000000-0000-4000-8000-000000000002','2026-01-03');
  exception when others then
    ok := (sqlerrm like 'DATE_NOT_IN_SCHEDULE%');
  end;
  assert ok, 'C3 周六给工作日任务落库必须被拒绝';

  -- C4 起始日之前也要拒
  ok := false;
  begin
    perform app.materialize('00000000-0000-4000-8000-000000000001','2025-06-01');
  exception when others then ok := true; end;
  assert ok, 'C4 起始日之前必须被拒绝';

  -- C5 暂停区间内也要拒
  ok := false;
  begin
    perform app.materialize('00000000-0000-4000-8000-000000000009','2026-01-06');
  exception when others then ok := true; end;
  assert ok, 'C5 暂停区间内必须被拒绝';

  raise notice '  [C] materialize 6 项 ✓';
end $$;


-- ###########################################################################
-- D. 业务动作：完成 / 打卡 / 快照 / 归档
-- ###########################################################################
do $$
declare r jsonb; n int; v_pts int; ok boolean; v_bal int; v_badge int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

  -- D1 完成任务加分。
  -- 013 起：单次完成发「单次分」。T1 是循环任务且开了打卡(2 分) → 发 2，
  -- 不再发整任务的完成分 5（那笔留给「完成全部」作为一次性结清奖励）。
  v_bal := (select points_balance from app.members
             where id = '33333333-3333-3333-3333-333333333333');
  r := app.complete_occurrence('00000000-0000-4000-8000-000000000001','2026-01-02');
  assert (r->>'points_awarded')::int = 2, format('D1 单次完成应加单次分 2，实际 %s', r->>'points_awarded');

  -- 013 起首次拿到勋章还会额外发奖励分，从流水里实读，不写死数值
  -- （有几枚勋章会同时达成取决于跑测试的时间，比如「早起鸟」）
  select coalesce(sum(delta), 0) into v_badge
    from app.point_ledger
   where member_id = '33333333-3333-3333-3333-333333333333'
     and source_type = 'badge' and entry_kind = 'primary';
  assert v_badge > 0, 'D1b 首次完成任务应有勋章奖励分';
  assert (r->>'balance')::int = v_bal + 2 + v_badge,
    format('D1c 余额应为 %s（单次分 2 + 勋章 %s），实际 %s',
           v_bal + 2 + v_badge, v_badge, r->>'balance');

  -- D2 重复点击幂等，不重复加分
  r := app.complete_occurrence('00000000-0000-4000-8000-000000000001','2026-01-02');
  assert (r->>'already')::boolean, 'D2 重复完成应返回 already';
  assert (r->>'balance')::int = v_bal + 2 + v_badge, 'D2b 余额不应变化';
  select count(*) into n from app.point_ledger where source_type='completion';
  assert n = 1, format('D2c 流水应只有 1 条，实际 %s', n);

  -- D3 打卡加分
  r := app.record_checkin('00000000-0000-4000-8000-000000000001','2026-01-03');
  assert (r->>'points_awarded')::int = 2, format('D3 打卡应加 2 分，实际 %s', r->>'points_awarded');
  assert (r->>'seq')::int = 1, 'D3b 首次打卡 seq 应为 1';

  -- D4 打卡次数上限（limit=3）
  perform app.record_checkin('00000000-0000-4000-8000-000000000001','2026-01-03');
  perform app.record_checkin('00000000-0000-4000-8000-000000000001','2026-01-03');
  ok := false;
  begin
    perform app.record_checkin('00000000-0000-4000-8000-000000000001','2026-01-03');
  exception when others then ok := (sqlerrm like 'CHECKIN_LIMIT_REACHED%'); end;
  assert ok, 'D4 超出每日打卡上限必须被拒绝';

  -- D5 撤回完成：分数原路退回，流水追加反向记录而不是删除
  r := app.uncomplete_occurrence('00000000-0000-4000-8000-000000000001','2026-01-02');
  -- 起始 + 单次分 2 + 3 次打卡 2×3 − 撤回的 2 + 勋章奖励
  select coalesce(sum(delta), 0) into v_badge
    from app.point_ledger
   where member_id = '33333333-3333-3333-3333-333333333333'
     and source_type = 'badge' and entry_kind = 'primary';
  assert (r->>'balance')::int = v_bal + 2 + 2*3 - 2 + v_badge,
    format('D5 撤回后余额应为 %s，实际 %s', v_bal + 2 + 2*3 - 2 + v_badge, r->>'balance');
  select count(*) into n from app.point_ledger where entry_kind='reversal';
  assert n = 1, 'D5b 应追加 1 条反向记录';
  select count(*) into n from app.point_ledger where source_type='completion' and entry_kind='primary';
  assert n = 1, 'D5c 原始完成记录必须保留';

  -- D6 快照：改任务积分不影响历史
  perform app.complete_occurrence('00000000-0000-4000-8000-000000000001','2026-01-04');
  update app.tasks set completion_points = 50
   where id = '00000000-0000-4000-8000-000000000001';
  select snap_completion_points into v_pts from app.task_occurrences
   where task_id='00000000-0000-4000-8000-000000000001' and occurrence_date='2026-01-04';
  assert v_pts = 5, format('D6 历史快照应仍为 5，实际 %s', v_pts);

  -- D7 快照：get_calendar 里历史用快照、未来用新值
  select completion_points into v_pts from app.get_calendar('2026-01-04','2026-01-04')
   where task_id='00000000-0000-4000-8000-000000000001';
  assert v_pts = 5, format('D7 日历上历史应显示 5，实际 %s', v_pts);
  select completion_points into v_pts from app.get_calendar('2026-01-20','2026-01-20')
   where task_id='00000000-0000-4000-8000-000000000001';
  assert v_pts = 50, format('D7b 日历上未来应显示 50，实际 %s', v_pts);

  -- D8 改任务定义应自动 bump version
  select version into n from app.tasks where id='00000000-0000-4000-8000-000000000001';
  assert n = 2, format('D8 版本号应自增到 2，实际 %s', n);

  -- D9 归档任务：历史实例仍留在日历上并标记为 archived
  perform app.complete_occurrence('00000000-0000-4000-8000-000000000006','2026-08-12');
  update app.tasks set archived_at = now() where id='00000000-0000-4000-8000-000000000006';
  select count(*) into n from app.get_calendar('2026-08-01','2026-08-31')
   where task_id='00000000-0000-4000-8000-000000000006' and archived;
  assert n = 1, format('D9 归档任务的历史实例应仍可见，实际 %s', n);

  -- D10 归档任务不再产生未来虚拟实例
  select count(*) into n from app.get_calendar('2026-08-13','2026-09-30')
   where task_id='00000000-0000-4000-8000-000000000006';
  assert n = 0, 'D10 归档后不应再有新实例';

  -- D11 get_calendar 虚拟/落库标记正确
  assert (select is_virtual from app.get_calendar('2026-01-20','2026-01-20')
           where task_id='00000000-0000-4000-8000-000000000001'), 'D11 未落库应标记为虚拟';
  assert not (select is_virtual from app.get_calendar('2026-01-04','2026-01-04')
           where task_id='00000000-0000-4000-8000-000000000001'), 'D11b 已落库不应标记为虚拟';

  -- D12 请假：已完成改请假要退分
  perform app.skip_occurrence('00000000-0000-4000-8000-000000000001','2026-01-04');
  select count(*) into n from app.task_occurrences
   where task_id='00000000-0000-4000-8000-000000000001'
     and occurrence_date='2026-01-04' and status='skipped';
  assert n = 1, 'D12a 状态应变为 skipped';
  select count(*) into n from app.point_ledger where entry_kind='reversal';
  assert n = 2, format('D12 改请假应再追加 1 条反向记录，实际共 %s', n);

  raise notice '  [D] 业务动作 20 项 ✓';
end $$;


-- ###########################################################################
-- E. 记账：幂等 / 日上限 / 撤销
-- ###########################################################################
do $$
declare e app.point_ledger%rowtype; e1 app.point_ledger%rowtype; n int; ok boolean;
begin
  -- 换成"小红"，避免和 D 段的余额互相干扰
  -- E1 正常入账
  e1 := app._post_ledger('44444444-4444-4444-4444-444444444444', 150, 'completion',
        '55555555-5555-5555-5555-555555555551', 0, 'test', null, null);
  assert e1.delta = 150, format('E1 应入账 150，实际 %s', e1.delta);

  -- E2 幂等：同一 source 再来一次不重复加分
  e := app._post_ledger('44444444-4444-4444-4444-444444444444', 150, 'completion',
        '55555555-5555-5555-5555-555555555551', 0, 'test', null, null);
  assert e.id = e1.id, 'E2 同一来源应返回原记录';
  select count(*) into n from app.point_ledger
   where member_id='44444444-4444-4444-4444-444444444444' and entry_kind='primary';
  assert n = 1, format('E2b 流水应只有 1 条，实际 %s', n);

  -- E3 日上限：cap=200，已得 150，再来 100 只入 50
  e := app._post_ledger('44444444-4444-4444-4444-444444444444', 100, 'completion',
        '55555555-5555-5555-5555-555555555552', 0, 'test', null, null);
  assert e.delta = 50, format('E3 应被截到 50，实际 %s', e.delta);
  assert e.capped_from = 100, format('E3b capped_from 应为 100，实际 %s', e.capped_from);

  -- E4 上限已满，再来入 0
  e := app._post_ledger('44444444-4444-4444-4444-444444444444', 30, 'completion',
        '55555555-5555-5555-5555-555555555553', 0, 'test', null, null);
  assert e.delta = 0, format('E4 上限已满应入 0，实际 %s', e.delta);

  -- E5 余额正确
  select points_balance into n from app.members where id='44444444-4444-4444-4444-444444444444';
  assert n = 200, format('E5 余额应为 200，实际 %s', n);

  -- E6 家长手动加分不受日上限限制
  e := app._post_ledger('44444444-4444-4444-4444-444444444444', 40, 'manual',
        '55555555-5555-5555-5555-555555555554', 0, '手动奖励', null, null);
  assert e.delta = 40, format('E6 手动加分不应被截，实际 %s', e.delta);

  -- E7 撤销：追加反向记录
  e := app._reverse_ledger(e1.id, '测试撤销', null);
  assert e.delta = -150, format('E7 反向记录应为 -150，实际 %s', e.delta);
  select points_balance into n from app.members where id='44444444-4444-4444-4444-444444444444';
  assert n = 90, format('E7b 撤销后余额应为 90，实际 %s', n);

  -- E8 原记录必须保留
  select count(*) into n from app.point_ledger where id = e1.id;
  assert n = 1, 'E8 原记录不能被删除';

  -- E9 重复撤销必须报错
  ok := false;
  begin
    perform app._reverse_ledger(e1.id, '再撤一次', null);
  exception when others then ok := (sqlerrm like 'ALREADY_REVERSED%'); end;
  assert ok, 'E9 重复撤销必须被拒绝';

  -- E10 反向记录不能再被撤销
  ok := false;
  begin
    perform app._reverse_ledger(e.id, '撤销反向记录', null);
  exception when others then ok := (sqlerrm like 'CANNOT_REVERSE_REVERSAL%'); end;
  assert ok, 'E10 反向记录不应可撤销';

  -- E11 流水账不可 UPDATE
  ok := false;
  begin
    update app.point_ledger set delta = 9999 where id = e1.id;
  exception when others then ok := (sqlerrm like 'POINT_LEDGER_IMMUTABLE%'); end;
  assert ok, 'E11 流水账必须禁止 UPDATE';

  -- E12 流水账不可 DELETE
  ok := false;
  begin
    delete from app.point_ledger where id = e1.id;
  exception when others then ok := (sqlerrm like 'POINT_LEDGER_IMMUTABLE%'); end;
  assert ok, 'E12 流水账必须禁止 DELETE';

  -- E13 对账函数
  update app.members set points_balance = 12345 where id='44444444-4444-4444-4444-444444444444';
  perform app.reconcile_balance('44444444-4444-4444-4444-444444444444');
  select points_balance into n from app.members where id='44444444-4444-4444-4444-444444444444';
  assert n = 90, format('E13 对账后余额应回到 90，实际 %s', n);

  raise notice '  [E] 记账 15 项 ✓';
end $$;


-- ###########################################################################
-- F. 阶段奖励（里程碑）
-- ###########################################################################
do $$
declare n int; v_before int; v_after int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

  insert into app.task_milestones (id, task_id, rule_kind, threshold, points, label)
  values ('66666666-6666-6666-6666-666666666666',
          '00000000-0000-4000-8000-000000000002', 'total_count', 3, 20, '写作业 3 次');

  select points_balance into v_before from app.members where id='33333333-3333-3333-3333-333333333333';

  -- 完成 2 次：还不该发
  perform app.complete_occurrence('00000000-0000-4000-8000-000000000002','2026-01-02');
  perform app.complete_occurrence('00000000-0000-4000-8000-000000000002','2026-01-05');
  select count(*) into n from app.point_ledger where source_type='milestone';
  assert n = 0, format('F1 未达阈值不应发放，实际 %s 条', n);

  -- 第 3 次：达成
  perform app.complete_occurrence('00000000-0000-4000-8000-000000000002','2026-01-06');
  select count(*) into n from app.point_ledger where source_type='milestone';
  assert n = 1, format('F2 达成阈值应发 1 笔，实际 %s 条', n);

  -- 第 4 次：不可重复发（repeatable=false）
  perform app.complete_occurrence('00000000-0000-4000-8000-000000000002','2026-01-07');
  select count(*) into n from app.point_ledger where source_type='milestone';
  assert n = 1, format('F3 不可重复的里程碑只发一次，实际 %s 条', n);

  -- F4 重复跑 evaluate 也不会补发（幂等）
  perform app.evaluate_milestones('00000000-0000-4000-8000-000000000002');
  perform app.evaluate_milestones('00000000-0000-4000-8000-000000000002');
  select count(*) into n from app.point_ledger where source_type='milestone';
  assert n = 1, format('F4 evaluate 必须幂等，实际 %s 条', n);

  select points_balance into v_after from app.members where id='33333333-3333-3333-3333-333333333333';
  assert v_after - v_before = 3*3 + 3 + 20,
         format('F5 余额增量应为 32（4 次完成 x3 分 + 20 分里程碑），实际 %s', v_after - v_before);

  raise notice '  [F] 阶段奖励 5 项 ✓';
end $$;

-- ###########################################################################
-- G. 建任务入口 —— 孩子的积分上限必须在函数里就挡住
-- ###########################################################################
do $$
declare r jsonb; n int; ok boolean; v_tid uuid; v_cap int;
begin
  -- G1 家长建任务：不受积分限制
  perform set_config('request.jwt.claims',
    '{"sub":"2a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  r := app.create_task(
    p_assignee_id => '33333333-3333-3333-3333-333333333333',
    p_title => '练钢琴', p_schedule_kind => 'recurring',
    p_recurrence => '{"freq":"weekly","byweekday":[2,4]}'::jsonb,
    p_starts_on => '2026-03-02', p_completion_points => 500);
  v_tid := (r->>'task_id')::uuid;
  assert v_tid is not null, 'G1 家长建任务应成功';

  select count(*) into n from app.tasks where id = v_tid and completion_points = 500;
  assert n = 1, 'G2 家长可以设高分任务';

  -- G3 展开引擎立刻能算出这个新任务（建完即可见，不用等任何同步）
  select count(*) into n from app.expand_task(v_tid, '2026-03-01', '2026-03-31');
  assert n = 9, format('G3 3 月的周二+周四应有 9 天，实际 %s', n);

  -- G4 created_by 必须是操作人，不能伪造
  select count(*) into n from app.tasks
   where id = v_tid and created_by = '22222222-2222-2222-2222-222222222222';
  assert n = 1, 'G4 created_by 应为当前成员';

  -- ---- 切到孩子 ----
  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  v_cap := app.child_points_cap();

  -- G5 孩子给自己建低分任务：允许
  r := app.create_task(
    p_assignee_id => '33333333-3333-3333-3333-333333333333',
    p_title => '收拾书包', p_completion_points => 1);
  assert (r->>'task_id') is not null, 'G5 孩子可以给自己建任务';

  -- G6 孩子建超上限任务：必须拒绝
  ok := false;
  begin
    perform app.create_task(
      p_assignee_id => '33333333-3333-3333-3333-333333333333',
      p_title => '刷分神器', p_completion_points => v_cap + 1);
  exception when others then
    ok := (sqlerrm like 'CHILD_POINTS_OVER_CAP%');
  end;
  assert ok, 'G6 孩子建超上限任务必须被拒绝';

  -- G7 打卡分+完成分是合计算的，不能拆开绕过
  ok := false;
  begin
    perform app.create_task(
      p_assignee_id => '33333333-3333-3333-3333-333333333333',
      p_title => '拆开绕过', p_checkin_points => v_cap, p_completion_points => v_cap);
  exception when others then
    ok := (sqlerrm like 'CHILD_POINTS_OVER_CAP%');
  end;
  assert ok, 'G7 打卡分与完成分必须合并计入上限';

  -- G8 孩子不能给别人派活
  ok := false;
  begin
    perform app.create_task(
      p_assignee_id => '44444444-4444-4444-4444-444444444444',
      p_title => '替我做', p_completion_points => 1);
  exception when others then
    ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'G8 孩子不能给其他成员建任务';

  -- G9 非法排期挡在入库前
  ok := false;
  begin
    perform app.create_task(
      p_assignee_id => '33333333-3333-3333-3333-333333333333',
      p_title => '坏排期', p_schedule_kind => 'recurring',
      p_recurrence => '{"freq":"weekly"}'::jsonb);
  exception when others then ok := true;
  end;
  assert ok, 'G9 缺 byweekday 的 weekly 必须被拒绝';

  -- G10 派给外人（不存在于本家庭的 member_id）
  ok := false;
  begin
    perform app.create_task(
      p_assignee_id => '99999999-9999-9999-9999-999999999999', p_title => '越界');
  exception when others then
    ok := (sqlerrm like 'ASSIGNEE_NOT_FOUND%');
  end;
  assert ok, 'G10 不能派给家庭外成员';

  -- G11 单日任务不填日期时，自动落在今天，且 recurrence.date 与 starts_on 一致
  r := app.create_task(
    p_assignee_id => '33333333-3333-3333-3333-333333333333', p_title => '今天的临时活');
  v_tid := (r->>'task_id')::uuid;
  select count(*) into n from app.tasks
   where id = v_tid and starts_on = app.today()
     and (recurrence ->> 'date')::date = app.today();
  assert n = 1, 'G11 单日任务应自动落在今天';

  -- G12 只给 recurrence.date 时，starts_on 跟着走（两处不能各说各话）
  r := app.create_task(
    p_assignee_id => '33333333-3333-3333-3333-333333333333', p_title => '下周看牙',
    p_recurrence => '{"freq":"once","date":"2026-09-15"}'::jsonb);
  select count(*) into n from app.tasks
   where id = (r->>'task_id')::uuid and starts_on = '2026-09-15';
  assert n = 1, 'G12 starts_on 应对齐 recurrence.date';

  raise notice '  [G] 建任务 12 项 ✓';
end $$;


-- ###########################################################################
-- H. 商城兑换 —— 扣分必须走流水账，驳回必须退分
-- ###########################################################################
do $$
declare
  r jsonb; n int; ok boolean; v_rid uuid;
  v_bal int; v_bal2 int; v_sum int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"2a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  -- 家长上架：现金（100 分 = 1 元，需审批）+ 冰淇淋（固定 30 分，免审，限量 2）
  insert into app.reward_items (id, family_id, name, emoji, pricing_mode, rate_points,
                                unit_label, min_quantity, step_quantity, requires_approval)
  values ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111',
          '现金', '💰', 'rate', 100, '元', 1, 1, true);
  insert into app.reward_items (id, family_id, name, emoji, pricing_mode, price_points,
                                stock, requires_approval)
  values ('88888888-8888-8888-8888-888888888888', '11111111-1111-1111-1111-111111111111',
          '冰淇淋', '🍦', 'fixed', 30, 2, false);

  -- 给小明先垫点分（manual 来源不受每日上限约束之外的规则影响）
  perform app._post_ledger('33333333-3333-3333-3333-333333333333', 300, 'manual',
    '55555555-5555-5555-5555-555555555555', 99, '测试垫分', null,
    '22222222-2222-2222-2222-222222222222');

  perform set_config('request.jwt.claims',
    '{"sub":"3a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  select points_balance into v_bal from app.members where id='33333333-3333-3333-3333-333333333333';

  -- H1 余额不足直接拒绝（现金 5 元 = 500 分）
  ok := false;
  begin
    perform app.redeem('77777777-7777-7777-7777-777777777777', 5);
  exception when others then ok := (sqlerrm like 'NOT_ENOUGH_POINTS%');
  end;
  assert ok, 'H1 余额不足必须拒绝兑换';

  -- H2 余额没被动过
  select points_balance into v_bal2 from app.members where id='33333333-3333-3333-3333-333333333333';
  assert v_bal2 = v_bal, format('H2 失败的兑换不能扣分，%s -> %s', v_bal, v_bal2);

  -- H3 正常兑换：冰淇淋 1 个 = 30 分
  r := app.redeem('88888888-8888-8888-8888-888888888888', 1);
  v_rid := (r->>'redemption_id')::uuid;
  assert (r->>'points_spent')::int = 30, format('H3 应扣 30 分，实际 %s', r->>'points_spent');

  -- H4 余额确实减了
  select points_balance into v_bal2 from app.members where id='33333333-3333-3333-3333-333333333333';
  assert v_bal2 = v_bal - 30, format('H4 余额应为 %s，实际 %s', v_bal - 30, v_bal2);

  -- H5 扣分必须留下流水（余额只是缓存，流水才是事实）
  select count(*) into n from app.point_ledger
   where source_type = 'redemption' and source_id = v_rid and delta = -30;
  assert n = 1, format('H5 兑换必须写一条 -30 的流水，实际 %s 条', n);

  -- H6 免审商品直接成交
  assert (r->>'pending')::boolean = false, 'H6 免审商品不应进入 pending';

  -- H7 库存扣减
  select stock into n from app.reward_items where id='88888888-8888-8888-8888-888888888888';
  assert n = 1, format('H7 库存应剩 1，实际 %s', n);

  -- H8 再兑 2 个：库存只剩 1，必须拒绝
  ok := false;
  begin
    perform app.redeem('88888888-8888-8888-8888-888888888888', 2);
  exception when others then ok := (sqlerrm like 'OUT_OF_STOCK%');
  end;
  assert ok, 'H8 超库存必须拒绝';

  -- H9 rate 型按倍率算钱：现金 2 元 = 200 分
  r := app.redeem('77777777-7777-7777-7777-777777777777', 2);
  v_rid := (r->>'redemption_id')::uuid;
  assert (r->>'points_spent')::int = 200, format('H9 现金 2 元应扣 200 分，实际 %s', r->>'points_spent');

  -- H10 需审批的进 pending
  assert (r->>'pending')::boolean = true, 'H10 现金需审批，应为 pending';
  select count(*) into n from app.redemptions where id = v_rid and status = 'pending';
  assert n = 1, 'H10b redemptions 状态应为 pending';

  -- H11 pending 期间分先扣（避免同一笔分兑两样东西）
  select points_balance into v_bal2 from app.members where id='33333333-3333-3333-3333-333333333333';
  assert v_bal2 = v_bal - 230, format('H11 余额应为 %s，实际 %s', v_bal - 230, v_bal2);

  -- H12 快照商品名，改名后历史仍可读
  update app.reward_items set name = '零花钱' where id='77777777-7777-7777-7777-777777777777';
  select count(*) into n from app.redemptions where id = v_rid and snap_name = '现金';
  assert n = 1, 'H12 兑换记录必须快照当时的商品名';

  -- ---- 家长驳回 ----
  perform set_config('request.jwt.claims',
    '{"sub":"2a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  perform app.set_pin('4321');
  r := app.verify_parent_pin('4321');
  r := app.decide_redemption(v_rid, 'rejected', r->>'token');

  -- H13 驳回退分
  select points_balance into v_bal2 from app.members where id='33333333-3333-3333-3333-333333333333';
  assert v_bal2 = v_bal - 30, format('H13 驳回后余额应回到 %s，实际 %s', v_bal - 30, v_bal2);

  -- H14 退分是追加反向记账，不是删记录
  select count(*) into n from app.point_ledger
   where source_type = 'redemption' and source_id = v_rid;
  assert n = 1, format('H14 原始扣分记录必须保留，实际 %s 条', n);
  select count(*) into n from app.point_ledger where entry_kind = 'reversal' and delta = 200;
  assert n = 1, format('H14b 应有一条 +200 的反向记账，实际 %s 条', n);

  -- H15 同一笔不能驳回两次
  ok := false;
  begin
    r := app.verify_parent_pin('4321');
    perform app.decide_redemption(v_rid, 'approved', r->>'token');
  exception when others then ok := (sqlerrm like 'ALREADY_DECIDED%');
  end;
  assert ok, 'H15 已处理的兑换不能重复处理';

  -- H16 流水账合计 = 余额缓存（对账，这是全系统的收口检查）
  select coalesce(sum(delta), 0) into v_sum from app.point_ledger
   where member_id = '33333333-3333-3333-3333-333333333333';
  select points_balance into v_bal2 from app.members where id='33333333-3333-3333-3333-333333333333';
  assert v_sum = v_bal2, format('H16 流水合计 %s 应等于余额缓存 %s', v_sum, v_bal2);

  raise notice '  [H] 商城兑换 16 项 ✓';
end $$;

do $$
begin
  raise notice '===========================================';
  raise notice '  全部断言通过（A31+B12+C6+D20+E15+F5+G12+H16 = 117 项）';
  raise notice '===========================================';
end $$;

rollback;
