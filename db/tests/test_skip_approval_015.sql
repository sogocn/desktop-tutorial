-- =============================================================================
-- test_skip_approval_015.sql —— 015 孩子请假需家长审批
-- =============================================================================
-- 覆盖：
--   S1 孩子提交请假 → 写 pending 行，task_occurrences 不动
--   S2 孩子重复提交 → 「已在审核中」，不新增行
--   S7 家长 list_skip_requests 只看到 pending（S2 后应是 1 条）
--   S3 家长同意 → 复用 skip_occurrence：occurrence 置 skipped，request 标记 approved
--   S4 孩子再提一条 → 家长驳回 → 标记 rejected，occurrence 不动
--   S5 家长同意时复用 skip_occurrence 的退分逻辑（先完成再请假，余额回到完成前）
--   S8 孩子不能自己审批 → decide_skip 抛 FORBIDDEN（角色闸门）
--
-- 跑法：npm run db:test。整脚本包在事务里，最后 ROLLBACK，不留数据。
-- =============================================================================

begin;

-- 固定数据：一家 + 爸 + 娃
insert into app.families (id, name, timezone, day_cutoff_hour, child_daily_points_cap) values
  ('f0150000-0000-4000-8000-000000000001', '请假之家', 'Asia/Shanghai', 0, 0);

insert into app.members (id, family_id, user_id, nickname, role) values
  ('f0150000-0000-4000-8000-00000000000a', 'f0150000-0000-4000-8000-000000000001',
   'f0150000-0000-4000-8000-00000000000b', '爸', 'parent'),
  ('f0150000-0000-4000-8000-00000000000c', 'f0150000-0000-4000-8000-000000000001',
   'f0150000-0000-4000-8000-00000000000d', '娃', 'child');

-- 家长建三条任务给娃（once，分别落在不同日期，积分只给完成分避免打卡干扰）
do $$
declare
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  v_t1 := (app.create_task(
             array['f0150000-0000-4000-8000-00000000000c'::uuid],
             '数学作业', '📘', 'sky', 'once', null,
             '2026-10-01'::date, null, null, null, null, null, false, 0, 1, 10) -> 'task_ids' ->> 0)::uuid;
  v_t2 := (app.create_task(
             array['f0150000-0000-4000-8000-00000000000c'::uuid],
             '英语阅读', '📗', 'sky', 'once', null,
             '2026-10-02'::date) -> 'task_ids' ->> 0)::uuid;
  v_t3 := (app.create_task(
             array['f0150000-0000-4000-8000-00000000000c'::uuid],
             '书法练习', '🖌️', 'sky', 'once', null,
             '2026-10-03'::date, null, null, null, null, null, false, 0, 1, 10) -> 'task_ids' ->> 0)::uuid;
  v_t4 := (app.create_task(
             array['f0150000-0000-4000-8000-00000000000c'::uuid],
             '体育锻炼', '🏃', 'sky', 'once', null,
             '2026-10-04'::date) -> 'task_ids' ->> 0)::uuid;

  -- 透传给后续 do 块用（临时表不需要，直接写 app 之外的全局变量不可行，故重查）
  perform set_config('test.t1', v_t1::text, true);
  perform set_config('test.t2', v_t2::text, true);
  perform set_config('test.t3', v_t3::text, true);
  perform set_config('test.t4', v_t4::text, true);
end $$;

do $$
declare
  v_t1 uuid := (current_setting('test.t1'))::uuid;
  v_t2 uuid := (current_setting('test.t2'))::uuid;
  v_t3 uuid := (current_setting('test.t3'))::uuid;
  v_t4 uuid := (current_setting('test.t4'))::uuid;
  v_req uuid; v_rid uuid; v_pre int; v_done int; v_after int; v_oc text; v_n int; v_list jsonb; ok boolean;
begin
  -- S1 孩子提交请假（2026-10-01）→ pending，occurrence 不动
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  v_req := (app.request_skip(v_t1, '2026-10-01'::date, '感冒了') ->> 'request_id')::uuid;
  assert v_req is not null, 'S1 应返回 request_id';
  select count(*)::int into v_n from app.skip_requests where status = 'pending';
  assert v_n = 1, format('S1 应有 1 条 pending，实际 %s', v_n);
  select count(*)::int into v_n from app.task_occurrences
    where task_id = v_t1 and occurrence_date = '2026-10-01'::date;
  assert v_n = 0, format('S1 不应改动 occurrence，实际 %s 行', v_n);
  raise notice '✓ S1 孩子提交请假 → pending，occurrence 未动';

  -- S2 孩子重复提交 → 「已在审核中」，不新增行
  perform app.request_skip(v_t1, '2026-10-01'::date, '又想请');
  select count(*)::int into v_n from app.skip_requests where status = 'pending';
  assert v_n = 1, format('S2 重复提交不应新增 pending，实际 %s', v_n);
  raise notice '✓ S2 孩子重复提交被拦（仍在审核中）';

  -- S7 家长拉待批列表 → 只有 1 条 pending
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  v_list := app.list_skip_requests(null);
  assert jsonb_array_length(v_list) = 1,
     format('S7 家长应看到 1 条待批请假，实际 %s', v_list);
  raise notice '✓ S7 家长 list_skip_requests 仅含 1 条 pending';

  -- S3 家长同意 → 复用 skip_occurrence，occurrence 置 skipped
  perform app.decide_skip(v_req, 'approved', null);
  select status into v_oc from app.skip_requests where id = v_req;
  assert v_oc = 'approved', format('S3 request 应 approved，实际 %s', v_oc);
  select status into v_oc from app.task_occurrences
    where task_id = v_t1 and occurrence_date = '2026-10-01'::date;
  assert v_oc = 'skipped', format('S3 occurrence 应 skipped，实际 %s', v_oc);
  raise notice '✓ S3 家长同意 → occurrence 置 skipped（复用 skip_occurrence）';

  -- S4 孩子再提一条（2026-10-02）→ 家长驳回 → rejected，occurrence 不动
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  v_rid := (app.request_skip(v_t2, '2026-10-02'::date, '想去玩') ->> 'request_id')::uuid;
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  perform app.decide_skip(v_rid, 'rejected', null);
  select status into v_oc from app.skip_requests where id = v_rid;
  assert v_oc = 'rejected', format('S4 request 应 rejected，实际 %s', v_oc);
  select count(*)::int into v_n from app.task_occurrences
    where task_id = v_t2 and occurrence_date = '2026-10-02'::date;
  assert v_n = 0, format('S4 驳回不应产生 occurrence，实际 %s 行', v_n);
  raise notice '✓ S4 家长驳回 → rejected，occurrence 不动';

  -- S5 退分逻辑：先完成 2026-10-03（+10），再请假，家长同意后余额回到完成前
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  v_pre := (select points_balance from app.members
             where id = 'f0150000-0000-4000-8000-00000000000c');
  perform app.complete_occurrence(v_t3, '2026-10-03'::date);
  v_done := (select points_balance from app.members
              where id = 'f0150000-0000-4000-8000-00000000000c');
  assert v_done > v_pre, format('S5 完成应加分，%s → %s', v_pre, v_done);
  -- 注：完成可能触发一次性勋章奖励（013 的 first_step），skip 只退「完成分」，
  --     不退勋章奖励；故断言「同意后余额 = 完成前 - 完成分」而非回到 0。
  v_req := (app.request_skip(v_t3, '2026-10-03'::date, '累了') ->> 'request_id')::uuid;
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
  perform app.decide_skip(v_req, 'approved', null);
  v_after := (select points_balance from app.members
               where id = 'f0150000-0000-4000-8000-00000000000c');
  assert v_after = v_done - 10, format('S5 同意后应退回完成分(10)，余额 %s → %s', v_done, v_after);
  select status into v_oc from app.task_occurrences
    where task_id = v_t3 and occurrence_date = '2026-10-03'::date;
  assert v_oc = 'skipped', format('S5 occurrence 应 skipped，实际 %s', v_oc);
  raise notice '✓ S5 同意后复用 skip_occurrence 退完成分，occurrence 置 skipped';

  -- S8 孩子不能自己审批 → decide_skip 抛 FORBIDDEN
  perform set_config('request.jwt.claims',
    '{"sub":"f0150000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
  v_req := (app.request_skip(v_t4, '2026-10-04'::date, '想逃') ->> 'request_id')::uuid;
  ok := false;
  begin
    perform app.decide_skip(v_req, 'approved', null);
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'S8 孩子不能自己审批，必须 FORBIDDEN';
  raise notice '✓ S8 孩子自行审批被拒（角色闸门）';
end $$;


rollback;
