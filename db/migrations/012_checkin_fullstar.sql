-- ###########################################################################
-- 012 增量：打卡 / 完成 逻辑梳理（对应产品反馈）
--   1) record_checkin：打卡后也要刷新当天状态 / 连续 / 勋章，
--      否则"满星"永远不把打卡算进去。
--   2) refresh_day_status：让"当日打卡达标"也算该任务当日达标，
--      从而计入「满星 / 活跃」。打卡次数按 checkins 实时统计（与 get_calendar 一致，
--      不依赖 task_occurrences.checkin_count 这个不会自增的冗余列）。
--   3) complete_all_occurrences：重复 / 期限任务「完成全部」——
--      把今天及之后的所有 occurrence 批量置完成，完成分只发一次（按任务计，幂等）。
-- 三个函数都用 create or replace 覆盖既有定义，不破坏其它调用方。
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- 1) 打卡后刷新当天状态（原 007 的 record_checkin 漏了这步）
-- ---------------------------------------------------------------------------
create or replace function app.record_checkin(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  ck app.checkins%rowtype;
  e  app.point_ledger%rowtype;
  v_seq int;
  v_awarded int := 0;
  v_capped int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能给自己的任务打卡';
  end if;

  o := app.materialize(p_task_id, p_date);

  select coalesce(max(seq), 0) + 1 into v_seq from app.checkins where occurrence_id = o.id;
  if v_seq > t.checkin_daily_limit then
    raise exception 'CHECKIN_LIMIT_REACHED: 今天这个任务最多打卡 % 次', t.checkin_daily_limit;
  end if;

  insert into app.checkins (occurrence_id, member_id, seq, points_awarded, note)
  values (o.id, t.assignee_id, v_seq, 0, p_note)
  returning * into ck;

  if o.snap_checkin_points > 0 and t.checkin_auto_approve then
    e := app._post_ledger(t.assignee_id, o.snap_checkin_points, 'checkin', ck.id, 0,
                          '打卡 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
    update app.checkins set points_awarded = v_awarded where id = ck.id;
  end if;

  perform app.evaluate_milestones(p_task_id);

  -- 012：打卡也要刷新当天状态 / 连续 / 勋章，否则"满星"不计打卡
  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'checkin_id', ck.id,
    'seq', v_seq,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- ---------------------------------------------------------------------------
-- 2) 重算某成员某天的 active / fullstar
--    达标(satisfied) = 该任务当天 occurrence 已 completed/skipped
--                      OR 该任务带打卡且当日打卡次数已达标(>=checkin_daily_limit)
--    active  = 当天有任意一次完成 或 任意一次打卡
--    fullstar= 当天有任务 且 全部任务都 satisfied
-- ---------------------------------------------------------------------------
create or replace function app.refresh_day_status(p_member_id uuid, p_date date)
returns app.member_day
language plpgsql security definer set search_path = app, public as $$
declare
  md          app.member_day%rowtype;
  v_total     int := 0;
  v_done      int := 0;
  v_satisfied int := 0;
  v_checkedin int := 0;
  v_active    boolean;
  v_full      boolean;
begin
  if p_member_id is null or p_date is null then return md; end if;

  with sched as (
    select t.id as task_id
      from app.tasks t
     where t.assignee_id = p_member_id
       and t.archived_at is null
       and exists (select 1 from app.expand_task(t.id, p_date, p_date))
    union
    select o.task_id
      from app.task_occurrences o
     where o.assignee_id = p_member_id and o.occurrence_date = p_date
  ),
  st as (
    select coalesce(o.status, 'pending') as status,
           -- 打卡次数实时统计（与 get_calendar 一致），不依赖冗余的存储列
           coalesce((select count(*)::int from app.checkins c where c.occurrence_id = o.id), 0) as ck_count,
           coalesce(t.checkin_daily_limit, 0) as ck_limit
      from sched s
      left join app.task_occurrences o on o.task_id = s.task_id and o.occurrence_date = p_date
      left join app.tasks t          on t.id = s.task_id
  )
  select count(*)::int,
         count(*) filter (where status = 'completed')::int,
         count(*) filter (where status in ('completed', 'skipped')
                          or (ck_limit > 0 and ck_count >= ck_limit))::int,
         count(*) filter (where ck_count > 0)::int
    into v_total, v_done, v_satisfied, v_checkedin
    from st;

  v_active := v_done > 0 or v_checkedin > 0;
  -- 没有任务的日子不算满星，否则"什么都不安排"就成了最优策略
  v_full := v_total > 0 and v_satisfied = v_total;

  insert into app.member_day (member_id, day, active, fullstar)
  values (p_member_id, p_date, v_active, v_full)
  on conflict (member_id, day) do update
     set active   = excluded.active   or member_day.retro_active,
         fullstar = excluded.fullstar or member_day.retro_fullstar,
         updated_at = now()
  returning * into md;

  return md;
end $$;


-- ---------------------------------------------------------------------------
-- 3) 完成全部：重复 / 期限任务批量完成
--    p_upto_date 省略 = ends_on（没有 ends_on 则只完成今天）
--    今天及之后（≤ p_upto_date / ends_on，最多往前看 730 天）的每次 occurrence：
--      - 已完成的跳过（不重复置完成、不重复发分）
--      - 未完成的：置 completed；once/到期任务同时补一次打卡（沿用 complete_occurrence 语义）
--      - 里程碑结算一次
--    完成分只发一次（按任务计，source_id=p_task_id，幂等）
-- ---------------------------------------------------------------------------
create or replace function app.complete_all_occurrences(
  p_task_id   uuid,
  p_upto_date date default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  t       app.tasks%rowtype;
  v_today date;
  v_upto  date;
  v_occ   date;
  v_count int := 0;
  v_awarded int := 0;
  v_capped  int;
  v_seq   int;
  e       app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能完成自己的任务';
  end if;

  v_today := app.family_today(t.family_id);
  -- 默认到 ends_on；上限 730 天，避免无 ends_on 的循环任务被展开到天荒地老
  v_upto := least(
    coalesce(p_upto_date, coalesce(t.ends_on, v_today)),
    v_today + 730
  );

  for v_occ in
    select x.d from app.expand_task(p_task_id, v_today, v_upto) as x(d)
     where x.d >= v_today
     order by x.d
  loop
    -- 已经完成的这一天跳过，避免重复置完成 / 重复发分
    if exists (
      select 1 from app.task_occurrences o
       where o.task_id = p_task_id and o.occurrence_date = v_occ and o.status = 'completed'
    ) then
      continue;
    end if;

    perform app.materialize(p_task_id, v_occ);
    update app.task_occurrences
       set status = 'completed', completed_at = now(), completed_by = me.id, updated_at = now()
     where task_id = p_task_id and occurrence_date = v_occ;
    v_count := v_count + 1;

    -- once / 到期：完成同时补一次打卡（完成+打卡一起发分）
    if (t.schedule_kind = 'once' or t.is_deadline_style)
       and t.checkin_points > 0 and t.checkin_auto_approve
       and not exists (
         select 1 from app.checkins c
         join app.task_occurrences o on o.id = c.occurrence_id
        where o.task_id = p_task_id and o.occurrence_date = v_occ)
    then
      perform app.record_checkin(p_task_id, v_occ);
    end if;
  end loop;

  -- 里程碑只结算一次（按任务，非逐次）
  if v_count > 0 then
    perform app.evaluate_milestones(p_task_id);
  end if;

  -- 完成分只发一次（按任务计，幂等）
  if v_count > 0 and t.completion_points > 0 then
    if not t.requires_approval then
      select coalesce(max(l.source_seq), -1) + 1 into v_seq
        from app.point_ledger l
       where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = p_task_id;

      e := app._post_ledger(t.assignee_id, t.completion_points, 'completion', p_task_id, v_seq,
                            '完成全部 · ' || t.title, v_today, me.id);
      v_awarded := coalesce(e.delta, 0);
      v_capped := e.capped_from;
    else
      insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
      values (t.family_id, t.assignee_id, 'completion', p_task_id, t.completion_points,
              '完成全部 · ' || t.title)
      on conflict (source_type, source_id, source_seq) do nothing;
    end if;
  end if;

  perform app.refresh_day_status(t.assignee_id, v_today);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'task_id', p_task_id,
    'completed_occurrences', v_count,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;
