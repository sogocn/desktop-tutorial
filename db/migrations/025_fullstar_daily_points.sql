-- =============================================================================
-- 025：每天完成满星奖励 30 积分
--
-- 规则：
--   1) 某成员某天的任务全部达标（member_day.fullstar = true）→ 当天发一笔满星奖励
--   2) 金额取 app.families.fullstar_points，默认 30；家长可以按家庭改
--   3) 一天只发一次：同一天反复触发重算不会重复发
--   4) 满星没了（家长撤回完成 / 改成请假）→ 追加 reversal 把这笔收回去。
--      流水账不可变，收回只能反向记账；之后再满星会新起一个 seq 重新发
--   5) 未来的日子不发：提前完成明天的任务，不该今天就领明天的奖励
--
-- 挂点为什么选 refresh_day_status()：
--   所有会让"当天状态"变化的动作（打卡 / 完成 / 撤销完成 / 请假 / 补卡）最后都会调它，
--   一处改动全覆盖，不需要任何定时任务。
--
-- 防重为什么用"当前有没有未撤销的满星流水"而不是"有没有发过"：
--   只用 uq_ledger_source 防重的话，撤销后重新满星会因为 source_seq=0 已占用
--   而被 _post_ledger 的 on conflict 静默吞掉 —— 于是"撤回后再做完"永远拿不到分。
--   这与 complete_occurrence 里 source_seq 递增是同一个坑。
-- =============================================================================

-- ###########################################################################
-- 一、流水账来源枚举扩容（存量库补约束）
-- ###########################################################################
-- 沿用 010 / 016 的 drop/add 写法。这里只是放宽（多一个取值），已存在的行不可能违反，
-- 对新库是等价替换，可重复执行。
--
-- ⚠️ 列表必须带上 016 加的 'challenge'：这个约束是"整表替换"不是"增量追加"，
--    漏一个就会把已有来源全部拒掉，而且报错发生在写流水时，离这里很远，很难查。
--    以后再加来源，务必先把当前全量抄过来。
alter table app.point_ledger drop constraint if exists point_ledger_source_type_check;
alter table app.point_ledger add constraint point_ledger_source_type_check
  check (source_type in ('checkin', 'completion', 'milestone', 'manual', 'redemption',
                         'badge', 'reversal', 'signin', 'streak', 'challenge', 'fullstar'));

-- ###########################################################################
-- 二、家庭可配置的满星奖励分值
-- ###########################################################################
alter table app.families add column if not exists fullstar_points int
  not null default 30 check (fullstar_points >= 0);

/** 满星奖励分值。家庭没配（或查不到）时退回 30，保证函数永远有值可用。 */
create or replace function app.fullstar_points(p_family_id uuid)
returns int
language sql stable security definer set search_path = app, public as $$
  select coalesce((select f.fullstar_points from app.families f where f.id = p_family_id), 30)
$$;

grant execute on function app.fullstar_points(uuid) to authenticated, service_role;

-- ###########################################################################
-- 三、refresh_day_status 接上满星奖励
-- ###########################################################################
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
  v_fid       uuid;
  v_today     date;
  v_points    int;
  v_seq       int;
  v_live      app.point_ledger%rowtype;
begin
  if p_member_id is null or p_date is null then return md; end if;

  select family_id into v_fid from app.members where id = p_member_id;
  if v_fid is null then return md; end if;
  v_today := app.family_today(v_fid);

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

  -- ---- 满星奖励 ------------------------------------------------------------
  -- 未来的日子不算：提前完成明天的任务不该今天就领明天的奖励。
  if p_date <= v_today then
    -- 这天"还活着"的满星奖励（没有 reversal 抵消掉的那一笔）
    select l.* into v_live
      from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'fullstar' and l.source_id = md.id
       and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
     order by l.source_seq desc
     limit 1;

    if md.fullstar then
      if v_live.id is null then
        -- seq 递增：撤回后再满星要能重新发，不能撞死在 uq_ledger_source 上
        select coalesce(max(l.source_seq), -1) + 1 into v_seq
          from app.point_ledger l
         where l.entry_kind = 'primary' and l.source_type = 'fullstar' and l.source_id = md.id;

        v_points := app.fullstar_points(v_fid);
        if v_points > 0 then
          perform app._post_ledger(p_member_id, v_points, 'fullstar', md.id, v_seq,
                                   '当日满星', p_date, null);
        end if;
      end if;
    elsif v_live.id is not null then
      -- 满星被撤掉了（家长撤回完成 / 改成请假）→ 反向记账收回，原记录原样保留
      perform app._reverse_ledger(v_live.id, '不再满星 · 收回当日满星奖励', null);
    end if;
  end if;

  return md;
end $$;
