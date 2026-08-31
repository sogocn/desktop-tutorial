-- =============================================================================
-- test_parent_multiusers.sql —— 需求1/2/3 的 DB 层回归
-- -----------------------------------------------------------------------------
-- 覆盖三项新能力的数据流（均在内存 PGlite 上跑，begin/rollback 互不污染）：
--   需求2：家长一次性派给多个孩子 → 每个孩子一份独立副本(group_id 关联)
--   需求2：家长编辑某一份 → 整组副本同步
--   需求1：家长删除"全部" → 整组软删(archived_at)
--   需求1：家长删除循环任务"某一次" → 写入 task_exclusions，该日不再展开
--   需求3：单次/到期任务"完成" → 同时自动记一次打卡(completion+checkin 都发分)
--   需求3：循环任务"完成" → 不自动打卡(打卡是独立每日动作)
--   需求1：孩子不能改/删别人的任务(FORBIDDEN)
--
-- 身份固件（family '61111111-1111-1111-1111-111111111111'）：
--   爸爸(parent) user='6a222222-...' member='62222222-...'
--   小明(child)  user='6a333333-...' member='63333333-...'
--   小红(child)  user='6a444444-...' member='64444444-...'
-- 身份切换：perform set_config('request.jwt.claims',
--   '{"sub":"<user_id>","role":"authenticated"}', true);
-- =============================================================================

begin;

-- ###########################################################################
-- SETUP：家庭 / 家长 / 两个孩子
-- ###########################################################################
do $$
begin
  insert into app.families (id, name, timezone, day_cutoff_hour)
  values ('61111111-1111-1111-1111-111111111111', '多选之家', 'Asia/Shanghai', 0);

  insert into app.members (id, family_id, user_id, nickname, role) values
    ('62222222-2222-2222-2222-222222222222', '61111111-1111-1111-1111-111111111111',
     '6a222222-2222-2222-2222-222222222222', '爸爸', 'parent'),
    ('63333333-3333-3333-3333-333333333333', '61111111-1111-1111-1111-111111111111',
     '6a333333-3333-3333-3333-333333333333', '小明', 'child'),
    ('64444444-4444-4444-4444-444444444444', '61111111-1111-1111-1111-111111111111',
     '6a444444-4444-4444-4444-444444444444', '小红', 'child');

  raise notice '✓ SETUP 多选之家 + 爸爸/小明/小红';
end $$;


-- ###########################################################################
-- 需求2：家长一次派给两个孩子 → 两份独立副本 + 同一 group_id
-- ###########################################################################
do $$
declare
  r jsonb; n int; v_gid uuid;
begin
  -- 爸爸身份
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  r := app.create_task(
    p_assignee_ids      => array[
      '63333333-3333-3333-3333-333333333333'::uuid,
      '64444444-4444-4444-4444-444444444444'::uuid],
    p_title             => '周末大扫除',
    p_schedule_kind     => 'once',
    p_recurrence        => '{"freq":"once","date":"2026-09-01"}'::jsonb,
    p_completion_points => 10,
    p_checkin_points    => 2,
    p_checkin_limit     => 1);

  assert (r->>'group_id') is not null, 'R2-0 应返回 group_id';
  v_gid := (r->>'group_id')::uuid;
  assert jsonb_array_length(r->'task_ids') = 2,
         format('R2-1 应建 2 份副本，实际 %s', jsonb_array_length(r->'task_ids'));

  select count(*) into n from app.tasks
   where group_id = v_gid and archived_at is null;
  assert n = 2, format('R2-2 同 group 应 2 份未归档副本，实际 %s', n);

  select count(distinct assignee_id) into n from app.tasks
   where group_id = v_gid;
  assert n = 2, format('R2-3 两份副本应分给两个不同孩子，实际 %s 个指派人', n);

  raise notice '✓ 需求2 多选指派人 → 两份独立副本(group_id=%s)', v_gid;
end $$;


-- ###########################################################################
-- 需求2：家长编辑某一份 → 整组副本同步(标题)
-- ###########################################################################
do $$
declare
  v_gid uuid; v_tid uuid; n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  select group_id into v_gid from app.tasks
   where title = '周末大扫除' and archived_at is null limit 1;
  select id into v_tid from app.tasks
   where group_id = v_gid and assignee_id = '63333333-3333-3333-3333-333333333333';

  perform app.update_task(p_task_id => v_tid, p_title => '周末大扫除(改)');

  -- 另一份(小红)也应同步改标题
  select count(*) into n from app.tasks
   where group_id = v_gid and title = '周末大扫除(改)';
  assert n = 2, format('R2-4 整组应同步为 2 份改后标题，实际 %s', n);

  raise notice '✓ 需求2 编辑一份 → 整组副本同步';
end $$;


-- ###########################################################################
-- 需求1：家长删除"全部" → 整组软删
-- ###########################################################################
do $$
declare
  v_gid uuid; v_tid uuid; n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  select group_id into v_gid from app.tasks
   where title = '周末大扫除(改)' and archived_at is null limit 1;
  select id into v_tid from app.tasks where group_id = v_gid limit 1;

  perform app.delete_task(p_task_id => v_tid, p_scope => 'all');

  select count(*) into n from app.tasks
   where group_id = v_gid and archived_at is null;
  assert n = 0, format('R1-1 整组应全部归档，未归档数应为 0，实际 %s', n);

  raise notice '✓ 需求1 删除全部 → 整组软删';
end $$;


-- ###########################################################################
-- 需求1：家长删除循环任务"某一次" → task_exclusions + 该日不再展开
-- ###########################################################################
do $$
declare
  v_tid uuid; n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  -- 给小红派一个每日任务
  perform app.create_task(
    p_assignee_ids      => array['64444444-4444-4444-4444-444444444444'::uuid],
    p_title             => '每日练琴',
    p_schedule_kind     => 'recurring',
    p_recurrence        => '{"freq":"daily"}'::jsonb,
    p_starts_on         => '2026-09-01',
    p_completion_points => 3,
    p_checkin_points    => 1,
    p_checkin_limit     => 1);

  select id into v_tid from app.tasks
   where title = '每日练琴' and assignee_id = '64444444-4444-4444-4444-444444444444';

  -- 删除 2026-09-05 这一次
  perform app.delete_task(p_task_id => v_tid, p_scope => 'once', p_date => '2026-09-05');

  select count(*) into n from app.task_exclusions
   where task_id = v_tid and occurrence_date = '2026-09-05';
  assert n = 1, format('R1-2 应写入 1 条 exclusion，实际 %s', n);

  -- 切到小红，看日历：09-05 不应出现，前后日期应出现
  perform set_config('request.jwt.claims',
    '{"sub":"6a444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  select count(*) into n from app.get_calendar('2026-09-01','2026-09-10') where task_id = v_tid;
  assert n = 9, format('R1-3 9/1-9/10 应展开 9 天(去掉 9/5)，实际 %s', n);

  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  perform app.delete_task(p_task_id => v_tid, p_scope => 'all');

  raise notice '✓ 需求1 删除某一次 → exclusion 生效(9/5 不再展开)';
end $$;


-- ###########################################################################
-- 需求3：单次任务"完成" → 同时自动打卡(completion + checkin 都发分)
-- ###########################################################################
do $$
declare
  v_tid uuid; r jsonb; n int; v_bal int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  perform app.create_task(
    p_assignee_ids      => array['63333333-3333-3333-3333-333333333333'::uuid],
    p_title             => '看牙医(单次)',
    p_schedule_kind     => 'once',
    p_recurrence        => '{"freq":"once","date":"2026-09-10"}'::jsonb,
    p_completion_points => 5,
    p_checkin_points    => 3,
    p_checkin_limit     => 1);

  select id into v_tid from app.tasks
   where title = '看牙医(单次)' and assignee_id = '63333333-3333-3333-3333-333333333333';

  -- 小明完成
  perform set_config('request.jwt.claims',
    '{"sub":"6a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  r := app.complete_occurrence(v_tid, '2026-09-10');

  -- 完成即打卡：状态应为 completed
  select count(*) into n from app.task_occurrences
   where task_id = v_tid and occurrence_date = '2026-09-10' and status = 'completed';
  assert n = 1, format('R3-1 单次完成应 1 条 completed，实际 %s', n);

  -- 自动打卡：checkins 应有 1 条
  select count(*) into n from app.checkins c
   join app.task_occurrences o on o.id = c.occurrence_id
   where o.task_id = v_tid and o.occurrence_date = '2026-09-10';
  assert n = 1, format('R3-2 完成应自动补 1 条打卡，实际 %s', n);

  -- 积分：completion 5 + checkin 3 = 8
  select points_balance into v_bal
    from app.members where id = '63333333-3333-3333-3333-333333333333';
  assert v_bal = 8, format('R3-3 余额应为 8(5+3)，实际 %s', v_bal);

  raise notice '✓ 需求3 单次完成即打卡(余额=%s)', v_bal;
end $$;


-- ###########################################################################
-- 需求3：循环任务"完成" → 不自动打卡
-- ###########################################################################
do $$
declare
  v_tid uuid; r jsonb; n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

  perform app.create_task(
    p_assignee_ids      => array['63333333-3333-3333-3333-333333333333'::uuid],
    p_title             => '每日阅读(循环)',
    p_schedule_kind     => 'recurring',
    p_recurrence        => '{"freq":"daily"}'::jsonb,
    p_starts_on         => '2026-09-01',
    p_completion_points => 5,
    p_checkin_points    => 2,
    p_checkin_limit     => 3);

  select id into v_tid from app.tasks
   where title = '每日阅读(循环)' and assignee_id = '63333333-3333-3333-3333-333333333333';

  perform set_config('request.jwt.claims',
    '{"sub":"6a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  r := app.complete_occurrence(v_tid, '2026-09-12');

  -- 完成状态有了
  select count(*) into n from app.task_occurrences
   where task_id = v_tid and occurrence_date = '2026-09-12' and status = 'completed';
  assert n = 1, format('R3-4 循环完成应 1 条 completed，实际 %s', n);

  -- 但不应自动打卡
  select count(*) into n from app.checkins c
   join app.task_occurrences o on o.id = c.occurrence_id
   where o.task_id = v_tid and o.occurrence_date = '2026-09-12';
  assert n = 0, format('R3-5 循环完成不应自动打卡，实际 %s 条', n);

  raise notice '✓ 需求3 循环完成不自动打卡';
end $$;


-- ###########################################################################
-- 需求1：权限 —— 孩子不能改/删别人的任务
-- ###########################################################################
do $$
declare
  v_tid uuid; ok boolean;
begin
  -- 爸爸给小红派一个任务
  perform set_config('request.jwt.claims',
    '{"sub":"6a222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  perform app.create_task(
    p_assignee_ids      => array['64444444-4444-4444-4444-444444444444'::uuid],
    p_title             => '小红专属',
    p_schedule_kind     => 'once',
    p_recurrence        => '{"freq":"once","date":"2026-09-20"}'::jsonb,
    p_completion_points => 5);
  select id into v_tid from app.tasks
   where title = '小红专属' and assignee_id = '64444444-4444-4444-4444-444444444444';

  -- 小明(非家长、非创建者)试图删除小红的任务 → FORBIDDEN
  perform set_config('request.jwt.claims',
    '{"sub":"6a333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  ok := false;
  begin
    perform app.delete_task(p_task_id => v_tid, p_scope => 'all');
  exception when others then ok := (sqlerrm like 'FORBIDDEN%');
  end;
  assert ok, 'R1-4 孩子不能删除别人的任务';

  raise notice '✓ 需求1 权限：孩子不能删别人的任务';
end $$;


do $$
begin
  raise notice '===========================================';
  raise notice '  需求1/2/3 DB 层回归全部断言通过';
  raise notice '===========================================';
end $$;

rollback;
