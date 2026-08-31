-- =============================================================================
-- 011_parent_edit_multiusers.sql
-- 需求1：家长可修改 / 删除孩子的日程；删除时可选择"仅这一次"或"全部"。
-- 需求2：创建任务可选多个指派人（为每个孩子各建一份独立副本，group_id 关联）。
-- 需求3：单次 / 到期任务"完成"即同时"打卡"（complete_occurrence 内自动补一次打卡）。
-- 全部为增量变更：新列 / 新表 / 新函数；已建库经 migrate.ts 仅跑一次。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) 任务分组：多选指派人时为每个孩子建一份副本，用 group_id 串起来
-- ---------------------------------------------------------------------------
alter table app.tasks add column if not exists group_id uuid;
create index if not exists tasks_group_idx on app.tasks (group_id);

-- ---------------------------------------------------------------------------
-- 2) 单次排除：家长"删除某一次"循环任务时，把这一天从日历展开里拿掉
-- ---------------------------------------------------------------------------
create table if not exists app.task_exclusions (
  task_id          uuid not null references app.tasks(id) on delete cascade,
  occurrence_date  date not null,
  created_by       uuid references app.members(id),
  created_at       timestamptz not null default now(),
  primary key (task_id, occurrence_date)
);
create index if not exists excl_task_idx on app.task_exclusions (task_id);

-- ---------------------------------------------------------------------------
-- 3) expand_task：展开时跳过已被排除的日期（与暂停区间同处理）
-- ---------------------------------------------------------------------------
create or replace function app.expand_task(p_task_id uuid, p_from date, p_to date)
returns setof date language plpgsql stable security definer set search_path = app, public as $$
declare
  t      app.tasks%rowtype;
  v_from date;
  v_to   date;
  v_probe date;
  v_cut  date;
begin
  select * into t from app.tasks where id = p_task_id;
  if not found then return; end if;

  -- 跨家庭窥探防护（测试脚本以 superuser 直连、auth.uid() 为空时放行）
  if auth.uid() is not null and t.family_id <> app.current_family_id() then
    return;
  end if;

  v_from := greatest(p_from, t.starts_on);
  v_to   := p_to;
  if t.ends_on is not null then v_to := least(v_to, t.ends_on); end if;
  if v_from > v_to then return; end if;

  -- COUNT 截断：先算出"第 N 次落在哪天"，再把上界收到那天。
  if t.max_occurrences is not null then
    v_probe := case t.recurrence ->> 'freq'
      when 'once'    then t.starts_on
      when 'daily'   then t.starts_on + (t.max_occurrences + 1)
      when 'weekly'  then t.starts_on + ((t.max_occurrences + 1) * 7)
      when 'monthly' then (t.starts_on + make_interval(months => t.max_occurrences + 2))::date
      else t.starts_on
    end;
    if t.ends_on is not null then v_probe := least(v_probe, t.ends_on); end if;

    select max(s.d) into v_cut from (
      select m.d from app._match_dates(t.recurrence, t.starts_on, v_probe) as m(d)
       where not exists (
         select 1 from app.task_pause_periods p
          where p.task_id = t.id and m.d between p.starts_on and p.ends_on)
         and not exists (
         select 1 from app.task_exclusions x
          where x.task_id = t.id and x.occurrence_date = m.d)
       order by m.d
       limit t.max_occurrences
    ) s;

    if v_cut is null then return; end if;
    v_to := least(v_to, v_cut);
    if v_from > v_to then return; end if;
  end if;

  return query
    select m.d
      from app._match_dates(t.recurrence, v_from, v_to) as m(d)
     where not exists (
       select 1 from app.task_pause_periods p
        where p.task_id = t.id and m.d between p.starts_on and p.ends_on)
       and not exists (
       select 1 from app.task_exclusions x
        where x.task_id = t.id and x.occurrence_date = m.d)
     order by m.d;
end $$;

-- ---------------------------------------------------------------------------
-- 4) create_task：改收 p_assignee_ids uuid[]，为每个孩子各建一份副本
--    （原单指派人签名先 drop，再建新签名，避免重载歧义）
-- ---------------------------------------------------------------------------
drop function if exists app.create_task(
  uuid, text, text, text, text, jsonb, date, date, int, time, time, time, boolean, int, int);

create or replace function app.create_task(
  p_assignee_ids     uuid[],
  p_title           text,
  p_icon_emoji      text   default '⭐',
  p_color           text   default 'sky',
  p_schedule_kind   text   default 'once',
  p_recurrence      jsonb  default '{"freq":"once"}'::jsonb,
  p_starts_on       date   default null,
  p_ends_on         date   default null,
  p_max_occurrences int    default null,
  p_window_start    time   default null,
  p_window_end      time   default null,
  p_due_time        time   default null,
  p_is_deadline     boolean default false,
  p_checkin_points  int    default 0,
  p_checkin_limit   int    default 1,
  p_completion_points int  default 0
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me     app.members%rowtype;
  v_fid  uuid;
  v_gid  uuid := gen_random_uuid();
  v_a    uuid;
  v_ass  app.members%rowtype;
  v_task app.tasks%rowtype;
  v_start date;
  v_rec  jsonb;
  v_total int := coalesce(p_checkin_points, 0) + coalesce(p_completion_points, 0);
  v_ids  uuid[] := '{}';
begin
  me := app.require_member();
  v_fid := me.family_id;
  v_start := coalesce(p_starts_on, app.family_today(v_fid));

  if coalesce(array_length(p_assignee_ids, 1), 0) = 0 then
    raise exception 'NO_ASSIGNEE: 至少要选一个孩子';
  end if;

  -- 单日任务的"那一天"就是 starts_on；若只给了 recurrence.date，starts_on 跟着走
  v_rec := coalesce(p_recurrence, '{"freq":"once"}'::jsonb);
  if v_rec ->> 'freq' = 'once' then
    if v_rec ? 'date' then
      v_start := (v_rec ->> 'date')::date;
    else
      v_rec := v_rec || jsonb_build_object('date', v_start::text);
    end if;
  end if;

  if not app.recurrence_is_valid(v_rec) then
    raise exception 'BAD_RECURRENCE: 排期设置不合法';
  end if;

  foreach v_a in array p_assignee_ids loop
    select * into v_ass from app.members where id = v_a and family_id = v_fid;
    if not found then raise exception 'ASSIGNEE_NOT_FOUND'; end if;

    if not app.is_parent() then
      if v_ass.id <> me.id then raise exception 'FORBIDDEN: 孩子只能给自己建任务'; end if;
      if v_total > app.child_points_cap() then
        raise exception 'CHILD_POINTS_OVER_CAP: 孩子建的任务积分不能超过 %', app.child_points_cap();
      end if;
    end if;

    insert into app.tasks (
      family_id, assignee_id, created_by, group_id, title, icon_emoji, color,
      schedule_kind, recurrence, starts_on, ends_on, max_occurrences,
      window_start_time, window_end_time, due_time, is_deadline_style,
      checkin_points, checkin_daily_limit, completion_points
    ) values (
      v_fid, v_a, me.id, v_gid, btrim(p_title), coalesce(p_icon_emoji, '⭐'),
      coalesce(p_color, 'sky'), coalesce(p_schedule_kind, 'once'),
      v_rec, v_start, p_ends_on, p_max_occurrences,
      p_window_start, p_window_end, p_due_time, coalesce(p_is_deadline, false),
      coalesce(p_checkin_points, 0), coalesce(p_checkin_limit, 1), coalesce(p_completion_points, 0)
    ) returning * into v_task;

    v_ids := array_append(v_ids, v_task.id);
  end loop;

  return jsonb_build_object(
    'task_ids', to_jsonb(v_ids), 'group_id', v_gid,
    'starts_on', v_start, 'created_by', me.id);
end $$;

-- ---------------------------------------------------------------------------
-- 5) update_task：编辑整条任务定义；若属某 group，同步整组副本
-- ---------------------------------------------------------------------------
create or replace function app.update_task(
  p_task_id uuid,
  p_title text default null,
  p_icon_emoji text default null,
  p_color text default null,
  p_schedule_kind text default null,
  p_recurrence jsonb default null,
  p_starts_on date default null,
  p_ends_on date default null,
  p_window_start time default null,
  p_window_end time default null,
  p_due_time time default null,
  p_is_deadline boolean default null,
  p_checkin_points int default null,
  p_checkin_limit int default null,
  p_completion_points int default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  v_rec jsonb;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if not app.is_parent() and me.id <> t.created_by then
    raise exception 'FORBIDDEN: 只能改自己建的任务';
  end if;

  if p_recurrence is not null then
    v_rec := p_recurrence;
    if v_rec ->> 'freq' = 'once' then
      if not (v_rec ? 'date') then
        v_rec := v_rec || jsonb_build_object('date', coalesce(p_starts_on, t.starts_on)::text);
      end if;
    end if;
    if not app.recurrence_is_valid(v_rec) then raise exception 'BAD_RECURRENCE'; end if;
  end if;

  update app.tasks set
    title            = coalesce(btrim(p_title), title),
    icon_emoji       = coalesce(p_icon_emoji, icon_emoji),
    color            = coalesce(p_color, color),
    schedule_kind    = coalesce(p_schedule_kind, schedule_kind),
    recurrence       = coalesce(v_rec, recurrence),
    starts_on        = coalesce(p_starts_on, starts_on),
    ends_on          = coalesce(p_ends_on, ends_on),
    window_start_time = coalesce(p_window_start, window_start_time),
    window_end_time   = coalesce(p_window_end, window_end_time),
    due_time         = coalesce(p_due_time, due_time),
    is_deadline_style = coalesce(p_is_deadline, is_deadline_style),
    checkin_points    = coalesce(p_checkin_points, checkin_points),
    checkin_daily_limit = coalesce(p_checkin_limit, checkin_daily_limit),
    completion_points = coalesce(p_completion_points, completion_points)
  where id = p_task_id;

  -- 同步整组副本，保证多选指派人时各孩子看到的任务一致
  if t.group_id is not null then
    update app.tasks set
      title            = coalesce(btrim(p_title), title),
      icon_emoji       = coalesce(p_icon_emoji, icon_emoji),
      color            = coalesce(p_color, color),
      schedule_kind    = coalesce(p_schedule_kind, schedule_kind),
      recurrence       = coalesce(v_rec, recurrence),
      starts_on        = coalesce(p_starts_on, starts_on),
      ends_on          = coalesce(p_ends_on, ends_on),
      window_start_time = coalesce(p_window_start, window_start_time),
      window_end_time   = coalesce(p_window_end, window_end_time),
      due_time         = coalesce(p_due_time, due_time),
      is_deadline_style = coalesce(p_is_deadline, is_deadline_style),
      checkin_points    = coalesce(p_checkin_points, checkin_points),
      checkin_daily_limit = coalesce(p_checkin_limit, checkin_daily_limit),
      completion_points = coalesce(p_completion_points, completion_points)
    where group_id = t.group_id;
  end if;

  return jsonb_build_object('task_id', p_task_id, 'updated', true);
end $$;

-- ---------------------------------------------------------------------------
-- 6) delete_task：scope='once' 删除某一次（排除该日期 + 删已落库实例）；
--    scope='all' 软删整条（含同 group 副本）。历史实例保留为灰色。
--    已完成的实例不允许直接删（避免静默吞掉已挣的分），需先撤销。
-- ---------------------------------------------------------------------------
create or replace function app.delete_task(
  p_task_id uuid,
  p_scope   text default 'all',   -- 'once' | 'all'
  p_date    date default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  v_oids uuid[];
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if not app.is_parent() and me.id <> t.created_by then
    raise exception 'FORBIDDEN: 只能删除自己建的任务';
  end if;

  if p_scope = 'once' then
    -- 单次 / 到期任务只有一次，删"本次"等价于删整条
    if t.schedule_kind <> 'recurring' then
      p_scope := 'all';
    else
      if p_date is null then raise exception 'NEED_DATE: 删除某一次必须指定日期'; end if;

      select array_agg(o.id) into v_oids
        from app.task_occurrences o
       where o.task_id = t.id and o.occurrence_date = p_date;

      if v_oids is not null then
        if exists (
          select 1 from app.task_occurrences o
           where o.task_id = t.id and o.occurrence_date = p_date and o.status = 'completed'
        ) then
          raise exception 'OCCURRENCE_COMPLETED: 这一天已经完成了，请先撤销再删除';
        end if;
        -- checkins 随 task_occurrences 级联删除
        delete from app.task_occurrences where id = any(v_oids);
      end if;

      insert into app.task_exclusions (task_id, occurrence_date, created_by)
      values (t.id, p_date, me.id)
      on conflict (task_id, occurrence_date) do nothing;

      return jsonb_build_object('task_id', p_task_id, 'scope', 'once', 'date', p_date);
    end if;
  end if;

  -- scope = 'all'（或单次任务被归并到此处）
  if t.group_id is not null then
    update app.tasks set archived_at = now() where group_id = t.group_id;
  else
    update app.tasks set archived_at = now() where id = t.id;
  end if;
  return jsonb_build_object('task_id', p_task_id, 'scope', 'all', 'group_id', t.group_id);
end $$;

-- ---------------------------------------------------------------------------
-- 7) complete_occurrence：需求3 —— 单次 / 到期任务完成时，同时记一次打卡
--    （完成与打卡一起发分）。循环任务不自动打卡（打卡是独立每日动作）。
-- ---------------------------------------------------------------------------
create or replace function app.complete_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  e  app.point_ledger%rowtype;
  v_awarded int := 0;
  v_capped int;
  v_seq int;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只能完成自己的任务';
  end if;

  o := app.materialize(p_task_id, p_date);

  if o.status = 'completed' then
    -- 幂等：重复点击不重复发分
    return jsonb_build_object(
      'occurrence_id', o.id, 'already', true, 'points_awarded', 0,
      'balance', (select points_balance from app.members where id = t.assignee_id));
  end if;

  update app.task_occurrences
     set status = 'completed', completed_at = now(), completed_by = me.id,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id
   returning * into o;

  if o.snap_completion_points > 0 and not t.requires_approval then
    select coalesce(max(l.source_seq), -1) + 1 into v_seq
      from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id;

    e := app._post_ledger(t.assignee_id, o.snap_completion_points, 'completion', o.id, v_seq,
                          '完成 · ' || o.snap_title, p_date, me.id);
    v_awarded := coalesce(e.delta, 0);
    v_capped := e.capped_from;
  elsif o.snap_completion_points > 0 then
    insert into app.pending_awards (family_id, member_id, source_type, source_id, points, reason)
    values (t.family_id, t.assignee_id, 'completion', o.id, o.snap_completion_points,
            '完成 · ' || o.snap_title)
    on conflict (source_type, source_id, source_seq) do nothing;
  end if;

  -- 需求3：单次 / 到期任务，完成即同时打卡（避免重复打卡：当天已有打卡则跳过）
  if (t.schedule_kind = 'once' or t.is_deadline_style)
     and o.snap_checkin_points > 0 and t.checkin_auto_approve
     and not exists (select 1 from app.checkins c where c.occurrence_id = o.id) then
    perform app.record_checkin(p_task_id, p_date);
  end if;

  perform app.evaluate_milestones(p_task_id);
  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);
  perform app.evaluate_badges(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'already', false,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;
