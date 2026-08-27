-- =============================================================================
-- 007_functions.sql —— 展开引擎 / 记账核心 / 业务入口
-- =============================================================================
-- 约定：所有会写数据的函数一律 SECURITY DEFINER。
-- 原因见 008_rls.sql —— 前端对 point_ledger / checkins / task_occurrences
-- 这些表只有 SELECT 权限，写入的唯一通道就是这里的函数。
-- =============================================================================


-- ###########################################################################
-- 一、身份
-- ###########################################################################

-- 这三个会被 RLS 策略调用。必须是 SECURITY DEFINER：
-- 否则策略里查 members 又会触发 members 的策略，无限递归。
create or replace function app.current_member_id()
returns uuid language sql stable security definer set search_path = app, public as $$
  select m.id from app.members m
   where m.user_id = auth.uid() and m.archived_at is null
   limit 1
$$;

create or replace function app.current_family_id()
returns uuid language sql stable security definer set search_path = app, public as $$
  select m.family_id from app.members m
   where m.user_id = auth.uid() and m.archived_at is null
   limit 1
$$;

create or replace function app.is_parent()
returns boolean language sql stable security definer set search_path = app, public as $$
  select coalesce((select m.role = 'parent' from app.members m
                    where m.user_id = auth.uid() and m.archived_at is null limit 1), false)
$$;

-- 孩子自建任务的单项积分上限（RLS 的 WITH CHECK 用）
create or replace function app.child_points_cap()
returns int language sql stable security definer set search_path = app, public as $$
  select case f.child_task_points_policy
           when 'free'   then 1000000
           when 'zero'   then 0
           else f.child_task_points_cap
         end
    from app.families f
   where f.id = app.current_family_id()
$$;

create or replace function app.require_member()
returns app.members language plpgsql stable security definer set search_path = app, public as $$
declare m app.members%rowtype;
begin
  select * into m from app.members
   where user_id = auth.uid() and archived_at is null;
  if not found then
    raise exception 'NOT_A_MEMBER: 当前身份不属于任何家庭';
  end if;
  return m;
end $$;

-- 家长专属操作的守卫。PIN 验证通过后拿到的 token 在这里兑现。
create or replace function app.require_parent(p_token text)
returns app.members language plpgsql stable security definer set search_path = app, public as $$
declare m app.members%rowtype; s app.parent_sessions%rowtype;
begin
  select * into s from app.parent_sessions where token = p_token;
  if not found then raise exception 'PARENT_TOKEN_INVALID: 需要家长验证'; end if;
  if s.expires_at < now() then raise exception 'PARENT_TOKEN_EXPIRED: 家长验证已过期，请重新输入 PIN'; end if;

  select * into m from app.members where id = s.member_id and archived_at is null;
  if not found or m.role <> 'parent' then raise exception 'PARENT_TOKEN_INVALID'; end if;
  return m;
end $$;


-- ###########################################################################
-- 二、时间：全系统"今天"只有这一个来源
-- ###########################################################################
-- 前端禁止裸 new Date() 算业务日期。孩子把设备时间改到明天来刷分，
-- 是一定会发生的事。
create or replace function app.family_today(p_family_id uuid)
returns date language sql stable security definer set search_path = app, public as $$
  select ((now() at time zone f.timezone) - make_interval(hours => f.day_cutoff_hour))::date
    from app.families f where f.id = p_family_id
$$;

create or replace function app.today()
returns date language sql stable security definer set search_path = app, public as $$
  select app.family_today(app.current_family_id())
$$;


-- ###########################################################################
-- 三、展开引擎
-- ###########################################################################

-- 只做"频率匹配"，不管有效期 / 暂停 / count。
-- 抽出来是为了让 expand_task 里算 count 截断点时能复用同一套匹配逻辑，
-- 而不是把规则写两遍——写两遍必然会漂。
create or replace function app._match_dates(r jsonb, p_from date, p_to date)
returns setof date language sql immutable as $$
  -- 用整数偏移生成日期，不经过 timestamp —— 少一层时区转换就少一类"差一天"的 bug
  select x.d
    from generate_series(0, p_to - p_from) as g(i)
   cross join lateral (select (p_from + g.i)::date) as x(d)
   where case r ->> 'freq'
     when 'once'  then d = (r ->> 'date')::date
     when 'daily' then true
     when 'weekly' then (r -> 'byweekday') @> to_jsonb(extract(isodow from d)::int)
     when 'monthly' then (
       (r -> 'bymonthday') @> to_jsonb(extract(day from d)::int)
       -- month_overflow = last_day：31 号在 2 月不存在时顺延到月末
       or (
         coalesce(r ->> 'month_overflow', 'skip') = 'last_day'
         and d = (date_trunc('month', d) + interval '1 month' - interval '1 day')::date
         and exists (
           select 1 from jsonb_array_elements(r -> 'bymonthday') e
            where (e #>> '{}')::int
                  > extract(day from (date_trunc('month', d) + interval '1 month' - interval '1 day'))::int
         )
       )
     )
     else false
   end
$$;

-- 有效期裁剪 → 频率匹配 → 排除暂停区间 → 应用 until / count
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
  -- 探测上界按频率给一个必然够用的富余量，避免无界扫描。
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
     order by m.d;
end $$;


-- 前端画日历只调这一个函数。
-- 虚拟展开 + 已落库实例合并（落库的用快照字段覆盖）+ 孤儿实例补入。
-- "孤儿实例" = 已落库但当前规则算不出来的日子，比如任务归档了、
-- 或者家长把"每周一三五"改成了"每周二四"。它们必须继续显示，否则
-- 孩子会发现自己前天挣的分对应的任务凭空消失了。
create or replace function app.get_calendar(
  p_from date, p_to date, p_member_id uuid default null
)
returns table (
  task_id            uuid,
  occurrence_id      uuid,
  occurrence_date    date,
  assignee_id        uuid,
  title              text,
  icon_emoji         text,
  color              text,
  status             text,
  checkin_points     int,
  completion_points  int,
  checkin_count      int,
  checkin_daily_limit int,
  window_start_time  time,
  window_end_time    time,
  due_time           time,
  is_deadline_style  boolean,
  archived           boolean,
  is_virtual         boolean,
  schedule_kind      text
)
language plpgsql stable security definer set search_path = app, public as $$
declare v_family uuid;
begin
  v_family := app.current_family_id();
  if v_family is null then return; end if;

  return query
  with ft as (
    select t.* from app.tasks t
     where t.family_id = v_family
       and (p_member_id is null or t.assignee_id = p_member_id)
  ),
  virt as (
    select t.id as tid, e.d as odate
      from ft t
      cross join lateral app.expand_task(t.id, p_from, p_to) as e(d)
     where t.archived_at is null
  ),
  occ as (
    select o.* from app.task_occurrences o
     where o.task_id in (select id from ft)
       and o.occurrence_date between p_from and p_to
  ),
  keys as (
    select tid, odate from virt
    union
    select o.task_id, o.occurrence_date from occ o
  )
  select
    k.tid,
    o.id,
    k.odate,
    t.assignee_id,
    coalesce(o.snap_title, t.title),
    coalesce(o.snap_icon_emoji, t.icon_emoji),
    coalesce(o.snap_color, t.color),
    coalesce(o.status, 'pending'),
    coalesce(o.snap_checkin_points, t.checkin_points),
    coalesce(o.snap_completion_points, t.completion_points),
    coalesce((select count(*)::int from app.checkins c where c.occurrence_id = o.id), 0),
    t.checkin_daily_limit,
    coalesce(o.snap_window_start_time, t.window_start_time),
    coalesce(o.snap_window_end_time, t.window_end_time),
    coalesce(o.snap_due_time, t.due_time),
    t.is_deadline_style,
    (t.archived_at is not null),
    (o.id is null),
    t.schedule_kind
  from keys k
  join ft t on t.id = k.tid
  left join occ o on o.task_id = k.tid and o.occurrence_date = k.odate
  order by k.odate,
           coalesce(o.snap_window_start_time, t.window_start_time) nulls last,
           t.created_at;
end $$;


-- 兑换商城商品。扣分同样走流水账，不直接改余额 ——
-- 余额只是缓存，流水账才是事实来源。
-- redemptions 对 authenticated 只读，前端拼不出 INSERT，必须经这里。
create or replace function app.redeem(
  p_item_id  uuid,
  p_quantity numeric default 1,
  p_note     text   default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me     app.members%rowtype;
  item   app.reward_items%rowtype;
  v_cost int;
  v_id   uuid;
  v_bal  int;
begin
  me := app.require_member();
  if p_quantity is null or p_quantity <= 0 then raise exception 'BAD_QTY'; end if;

  select * into item from app.reward_items where id = p_item_id;
  if not found or item.family_id <> me.family_id then raise exception 'ITEM_NOT_FOUND'; end if;
  if not item.active then raise exception 'ITEM_INACTIVE: 这个商品已下架'; end if;

  -- 阶梯量校验：min/step 是家长设的规则，绕过它就等于绕过定价
  if p_quantity < item.min_quantity then
    raise exception 'BELOW_MIN_QTY: 至少要兑 % %', item.min_quantity, coalesce(item.unit_label, '个');
  end if;
  if mod((p_quantity - item.min_quantity)::numeric, item.step_quantity) <> 0 then
    raise exception 'BAD_STEP_QTY: 数量必须按 % 递增', item.step_quantity;
  end if;

  if item.stock is not null and item.stock < p_quantity then
    raise exception 'OUT_OF_STOCK: 库存不足';
  end if;

  v_cost := ceil(
    case when item.pricing_mode = 'fixed' then item.price_points * p_quantity
         else item.rate_points * p_quantity end
  )::int;

  -- 锁住成员行再读余额，防止连点两次各扣一半
  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < v_cost then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', v_cost - v_bal;
  end if;

  insert into app.redemptions (family_id, member_id, item_id, quantity, points_cost,
                               snap_name, snap_emoji, note)
  values (me.family_id, me.id, item.id, p_quantity, v_cost,
          item.name, item.emoji, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  -- 分先扣掉。家长驳回时走 revoke_ledger_entry 退回。
  perform app._post_ledger(me.id, -v_cost, 'redemption', v_id, 0,
                           '兑换 ' || item.name, null, me.id);

  if item.stock is not null then
    update app.reward_items set stock = stock - p_quantity where id = item.id;
  end if;

  return jsonb_build_object(
    'redemption_id', v_id,
    'points_spent', v_cost,
    'balance', (select points_balance from app.members where id = me.id),
    'pending', item.requires_approval,
    'message', case when item.requires_approval then '已提交，等家长确认' else '兑换成功' end);
end $$;


-- 家长处理兑换申请。驳回 = 退分（追加反向记账），不是删记录。
create or replace function app.decide_redemption(
  p_redemption_id uuid, p_decision text, p_parent_token text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; r app.redemptions%rowtype; src app.point_ledger%rowtype;
begin
  parent := app.require_parent(p_parent_token);
  if p_decision not in ('approved', 'rejected', 'delivered', 'cancelled') then
    raise exception 'BAD_DECISION';
  end if;

  select * into r from app.redemptions where id = p_redemption_id;
  if not found or r.family_id <> parent.family_id then raise exception 'REDEMPTION_NOT_FOUND'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED: 这笔已经处理过了'; end if;

  update app.redemptions
     set status = p_decision, decided_at = now(), decided_by = parent.id
   where id = r.id;

  if p_decision in ('rejected', 'cancelled') then
    select * into src from app.point_ledger
     where entry_kind = 'primary' and source_type = 'redemption'
       and source_id = r.id and source_seq = 0;
    if found then
      perform app._reverse_ledger(src.id, '兑换未通过，积分退回', parent.id);
    end if;
  end if;

  return jsonb_build_object(
    'redemption_id', r.id, 'status', p_decision,
    'balance', (select points_balance from app.members where id = r.member_id));
end $$;


-- 所有写操作的前置步骤。
-- 内含日期合法性断言 —— 这是防刷分的第一道闸：
-- 没有它，孩子可以给"每周一"的任务在周日打卡，或者给去年的任务补卡。
create or replace function app.materialize(p_task_id uuid, p_date date)
returns app.task_occurrences
language plpgsql security definer set search_path = app, public as $$
declare
  t app.tasks%rowtype;
  o app.task_occurrences%rowtype;
  v_ok boolean;
begin
  select * into t from app.tasks where id = p_task_id;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;

  select exists(select 1 from app.expand_task(p_task_id, p_date, p_date)) into v_ok;
  if not v_ok then
    -- 已经落过库的（家长强制加的实例、规则改动前的历史）允许继续操作
    if not exists (select 1 from app.task_occurrences
                    where task_id = p_task_id and occurrence_date = p_date) then
      raise exception 'DATE_NOT_IN_SCHEDULE: % 不在该任务的排期内', p_date;
    end if;
  end if;

  insert into app.task_occurrences (
    task_id, family_id, assignee_id, occurrence_date,
    snap_title, snap_icon_emoji, snap_color,
    snap_checkin_points, snap_completion_points,
    snap_window_start_time, snap_window_end_time, snap_due_time,
    task_version
  ) values (
    t.id, t.family_id, t.assignee_id, p_date,
    t.title, t.icon_emoji, t.color,
    t.checkin_points, t.completion_points,
    t.window_start_time, t.window_end_time, t.due_time,
    t.version
  )
  -- 冲突时只碰 updated_at，绝不覆盖快照字段
  on conflict (task_id, occurrence_date) do update set updated_at = now()
  returning * into o;

  return o;
end $$;


-- ###########################################################################
-- 四、记账
-- ###########################################################################

-- 唯一允许写 point_ledger 的地方。
-- 幂等 + 日上限 + 余额缓存行锁，三件事都在这里做完。
create or replace function app._post_ledger(
  p_member_id      uuid,
  p_delta          int,
  p_source_type    text,
  p_source_id      uuid,
  p_source_seq     int,
  p_reason         text,
  p_occurrence_date date,
  p_created_by     uuid
)
returns app.point_ledger
language plpgsql security definer set search_path = app, public as $$
declare
  m   app.members%rowtype;
  f   app.families%rowtype;
  e   app.point_ledger%rowtype;
  v_today date;
  v_earned_today int;
  v_delta int;
  v_capped_from int;
begin
  -- 行锁：并发打卡时余额缓存不会互相覆盖
  select * into m from app.members where id = p_member_id for update;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  select * into f from app.families where id = m.family_id;

  v_today := app.family_today(m.family_id);
  v_delta := p_delta;

  -- 每日上限：宽松档下最有效的一道闸。只管孩子、只管挣分的来源。
  if v_delta > 0
     and m.role = 'child'
     and f.child_daily_points_cap > 0
     and p_source_type in ('checkin', 'completion', 'milestone', 'badge')
  then
    select coalesce(sum(delta), 0) into v_earned_today
      from app.point_ledger
     where member_id = p_member_id and award_date = v_today and delta > 0;

    if v_earned_today + v_delta > f.child_daily_points_cap then
      v_capped_from := v_delta;
      v_delta := greatest(f.child_daily_points_cap - v_earned_today, 0);
    end if;
  end if;

  insert into app.point_ledger (
    family_id, member_id, delta, balance_after, entry_kind,
    source_type, source_id, source_seq, reason, capped_from,
    occurrence_date, award_date, created_by
  ) values (
    m.family_id, p_member_id, v_delta, m.points_balance + v_delta, 'primary',
    p_source_type, p_source_id, p_source_seq, p_reason, v_capped_from,
    p_occurrence_date, v_today, p_created_by
  )
  on conflict do nothing
  returning * into e;

  -- 撞上唯一约束 = 这笔已经发过了，直接返回原记录，不重复加分
  if e.id is null then
    select * into e from app.point_ledger
     where entry_kind = 'primary' and source_type = p_source_type
       and source_id = p_source_id and source_seq = p_source_seq;
    return e;
  end if;

  update app.members set points_balance = points_balance + v_delta where id = p_member_id;
  return e;
end $$;


-- 撤销 = 追加一条反向记账。原记录永远保留。
create or replace function app._reverse_ledger(
  p_entry_id uuid, p_reason text, p_by uuid
)
returns app.point_ledger
language plpgsql security definer set search_path = app, public as $$
declare src app.point_ledger%rowtype; e app.point_ledger%rowtype; m app.members%rowtype;
begin
  select * into src from app.point_ledger where id = p_entry_id;
  if not found then raise exception 'LEDGER_ENTRY_NOT_FOUND'; end if;
  if src.entry_kind <> 'primary' then
    raise exception 'CANNOT_REVERSE_REVERSAL: 反向记录不能再撤销';
  end if;
  if exists (select 1 from app.point_ledger where reverses_id = p_entry_id) then
    raise exception 'ALREADY_REVERSED: 这笔积分已经撤销过了';
  end if;

  select * into m from app.members where id = src.member_id for update;

  insert into app.point_ledger (
    family_id, member_id, delta, balance_after, entry_kind,
    source_type, source_id, source_seq, reverses_id, reason,
    occurrence_date, award_date, created_by
  ) values (
    src.family_id, src.member_id, -src.delta, m.points_balance - src.delta, 'reversal',
    'reversal', src.id, 0, src.id,
    coalesce(p_reason, '撤销：' || coalesce(src.reason, src.source_type)),
    src.occurrence_date, app.family_today(src.family_id), p_by
  )
  returning * into e;

  update app.members set points_balance = points_balance - src.delta where id = src.member_id;
  return e;
end $$;


create or replace function app.revoke_ledger_entry(
  p_entry_id uuid, p_parent_token text, p_reason text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; src app.point_ledger%rowtype; e app.point_ledger%rowtype;
begin
  parent := app.require_parent(p_parent_token);
  select * into src from app.point_ledger where id = p_entry_id;
  if not found or src.family_id <> parent.family_id then
    raise exception 'LEDGER_ENTRY_NOT_FOUND';
  end if;

  e := app._reverse_ledger(p_entry_id, p_reason, parent.id);
  return jsonb_build_object(
    'reversal_id', e.id,
    'delta', e.delta,
    'balance', (select points_balance from app.members where id = src.member_id)
  );
end $$;


-- 余额对账：缓存 vs 流水真值。UI 上给家长一个"重算"按钮。
create or replace function app.reconcile_balance(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare v_true int; v_cache int;
begin
  select coalesce(sum(delta), 0) into v_true from app.point_ledger where member_id = p_member_id;
  select points_balance into v_cache from app.members where id = p_member_id;
  update app.members set points_balance = v_true where id = p_member_id;
  return jsonb_build_object('before', v_cache, 'after', v_true, 'drift', v_true - v_cache);
end $$;


-- ###########################################################################
-- 五、阶段奖励（事件驱动，无定时任务）
-- ###########################################################################
-- 幂等靠"应发总数 n_should − 已发数 n_done = 补发数"。
-- 重试跑两遍，第二遍差值为 0，天然安全。
create or replace function app.evaluate_milestones(p_task_id uuid)
returns int
language plpgsql security definer set search_path = app, public as $$
declare
  t        app.tasks%rowtype;
  ms       app.task_milestones%rowtype;
  rec      record;
  v_today  date;
  v_progress numeric;
  v_should int;
  v_done   int;
  v_total  int := 0;
  v_streak int;
  v_expanded int;
  v_completed int;
  i int;
begin
  select * into t from app.tasks where id = p_task_id;
  if not found then return 0; end if;
  v_today := app.family_today(t.family_id);

  for ms in select * from app.task_milestones where task_id = p_task_id loop
    v_progress := 0;

    if ms.rule_kind = 'total_count' then
      select count(*) into v_progress from app.task_occurrences
       where task_id = p_task_id and status = 'completed';

    elsif ms.rule_kind = 'checkin_total' then
      select count(*) into v_progress
        from app.checkins c
        join app.task_occurrences o on o.id = c.occurrence_id
       where o.task_id = p_task_id;

    elsif ms.rule_kind = 'streak_days' then
      -- 从今天往回走：completed 计数，skipped 跳过但不断连，
      -- 今天还没做（pending）不算断连，其余一律断。
      v_streak := 0;
      for rec in
        select e.d,
               coalesce(o.status, 'pending') as st
          from app.expand_task(p_task_id, greatest(t.starts_on, v_today - 400), v_today) as e(d)
          left join app.task_occurrences o
                 on o.task_id = p_task_id and o.occurrence_date = e.d
         order by e.d desc
      loop
        if rec.st = 'completed' then
          v_streak := v_streak + 1;
        elsif rec.st = 'skipped' then
          continue;
        elsif rec.d = v_today then
          continue;
        else
          exit;
        end if;
      end loop;
      v_progress := v_streak;

    elsif ms.rule_kind = 'completion_rate' then
      select count(*) into v_expanded
        from app.expand_task(p_task_id,
               case when ms.window_kind = 'month' then date_trunc('month', v_today)::date
                    else t.starts_on end,
               v_today) as e(d);
      select count(*) into v_completed
        from app.task_occurrences
       where task_id = p_task_id and status = 'completed'
         and occurrence_date >= case when ms.window_kind = 'month'
                                     then date_trunc('month', v_today)::date
                                     else t.starts_on end
         and occurrence_date <= v_today;
      -- 请假的日子从分母里扣掉
      select v_expanded - count(*) into v_expanded
        from app.task_occurrences
       where task_id = p_task_id and status = 'skipped'
         and occurrence_date between
             (case when ms.window_kind = 'month' then date_trunc('month', v_today)::date
                   else t.starts_on end) and v_today;
      if v_expanded <= 0 then continue; end if;
      v_progress := v_completed::numeric / v_expanded;
    end if;

    if ms.repeatable and ms.rule_kind <> 'completion_rate' then
      v_should := floor(v_progress / ms.threshold)::int;
    else
      v_should := case when v_progress >= ms.threshold then 1 else 0 end;
    end if;

    select count(*)::int into v_done from app.point_ledger
     where entry_kind = 'primary' and source_type = 'milestone' and source_id = ms.id;

    i := v_done + 1;
    while i <= v_should loop
      perform app._post_ledger(
        t.assignee_id, ms.points, 'milestone', ms.id, i,
        coalesce(ms.label, '阶段奖励：' || t.title), v_today, null);
      v_total := v_total + 1;
      i := i + 1;
    end loop;

    if v_should > 0 and ms.badge_id is not null then
      insert into app.member_badges (member_id, badge_id, source_type, source_id)
      values (t.assignee_id, ms.badge_id, 'milestone', ms.id)
      on conflict (member_id, badge_id) do nothing;
    end if;
  end loop;

  return v_total;
end $$;


-- ###########################################################################
-- 六、业务入口：打卡 / 完成 / 请假 / 撤销完成
-- ###########################################################################

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

  return jsonb_build_object(
    'occurrence_id', o.id,
    'checkin_id', ck.id,
    'seq', v_seq,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- ⚠ 本函数在 010_signin.sql 里被再次 create or replace（追加了签到/活跃/满星的
-- 联动调用），最终生效的是那一版。这里保留同样的 source_seq 修复，
-- 好让新建的库从第一天起就是对的、也让读代码的人不会以为这里还是坏的。
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

  -- source_seq 不能写死 0：撤销完成只追加 reversal（铁律 5），旧的 primary 还在，
  -- 再次完成时 seq=0 会撞 uq_ledger_source 被 on conflict 静默吞掉 → 分不再加。
  -- 每次真发分都取下一个序号，撤销后重做就是一条新的 primary。
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

  perform app.evaluate_milestones(p_task_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'already', false,
    'points_awarded', v_awarded,
    'capped_from', v_capped,
    'balance', (select points_balance from app.members where id = t.assignee_id)
  );
end $$;


-- 点错了撤回。分数一起退回去（追加反向记账，不删原始记录）。
create or replace function app.uncomplete_occurrence(p_task_id uuid, p_date date)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  src app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then raise exception 'FORBIDDEN'; end if;

  select * into o from app.task_occurrences
   where task_id = p_task_id and occurrence_date = p_date;
  if not found or o.status <> 'completed' then
    raise exception 'NOT_COMPLETED: 这条本来就不是已完成状态';
  end if;

  update app.task_occurrences
     set status = 'pending', completed_at = null, completed_by = null, updated_at = now()
   where id = o.id;

  -- 取"最后一条还没被撤销的完成记账"。完成→撤销→再完成会产生 seq 0/1/2…，
  -- 写死 seq=0 会去撤一条早就撤过的记录，等于撤不掉。
  select l.* into src from app.point_ledger l
   where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
     and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
   order by l.source_seq desc
   limit 1;
  if src.id is not null then
    perform app._reverse_ledger(src.id, '撤回完成 · ' || o.snap_title, me.id);
  end if;

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


create or replace function app.skip_occurrence(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
  t  app.tasks%rowtype;
  o  app.task_occurrences%rowtype;
  src app.point_ledger%rowtype;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  if t.assignee_id <> me.id and me.role <> 'parent' then raise exception 'FORBIDDEN'; end if;

  o := app.materialize(p_task_id, p_date);

  -- 已完成的改成请假，要把完成分退回去（同样取最后一条未撤销的）
  if o.status = 'completed' then
    select l.* into src from app.point_ledger l
     where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
       and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
     order by l.source_seq desc
     limit 1;
    if src.id is not null then
      perform app._reverse_ledger(src.id, '改为请假 · ' || o.snap_title, me.id);
    end if;
  end if;

  update app.task_occurrences
     set status = 'skipped', completed_at = null, completed_by = null,
         note = coalesce(p_note, note), updated_at = now()
   where id = o.id;

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


-- ###########################################################################
-- 七、家庭 / 成员 / PIN
-- ###########################################################################

create or replace function app._new_invite_code()
returns text language plpgsql volatile set search_path = app, public as $$
declare v_code text;
begin
  loop
    v_code := app.gen_code(6);
    exit when not exists (select 1 from app.invites where code = v_code);
  end loop;
  return v_code;
end $$;


create or replace function app.create_family(
  p_family_name text,
  p_nickname    text,
  p_avatar      text default '🙂',
  p_pin         text default null,
  p_timezone    text default 'Asia/Shanghai'
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_uid uuid;
  f app.families%rowtype;
  m app.members%rowtype;
  v_child_code text;
  v_parent_code text;
  v_salt text;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'NO_AUTH: 缺少身份'; end if;
  if exists (select 1 from app.members where user_id = v_uid) then
    raise exception 'ALREADY_IN_FAMILY: 这个身份已经属于某个家庭了';
  end if;
  if p_pin is not null and p_pin !~ '^\d{4}$' then
    raise exception 'BAD_PIN: PIN 必须是 4 位数字';
  end if;

  insert into app.families (name, timezone) values (btrim(p_family_name), p_timezone)
  returning * into f;

  v_salt := app.gen_salt_text();
  insert into app.members (family_id, user_id, nickname, role, avatar_emoji, pin_hash, pin_salt)
  values (f.id, v_uid, btrim(p_nickname), 'parent', coalesce(p_avatar, '🙂'),
          case when p_pin is null then null else app.hash_pin(p_pin, v_salt) end,
          case when p_pin is null then null else v_salt end)
  returning * into m;

  v_child_code  := app._new_invite_code();
  v_parent_code := app._new_invite_code();
  insert into app.invites (family_id, code, role, created_by) values
    (f.id, v_child_code,  'child',  m.id),
    (f.id, v_parent_code, 'parent', m.id);

  -- 商城默认只播这一条。它是一条普通记录，不是特例。
  insert into app.reward_items (family_id, name, emoji, pricing_mode, rate_points, unit_label,
                                min_quantity, step_quantity, requires_approval, sort_order)
  values (f.id, '现金', '💰', 'rate', 100, '元', 1, 1, true, 0);

  return jsonb_build_object(
    'family_id', f.id, 'member_id', m.id, 'user_id', v_uid,
    'child_invite_code', v_child_code, 'parent_invite_code', v_parent_code);
end $$;


-- 建任务。家长不受积分限制，孩子建的打卡分+完成分合计不能超家庭上限
-- （而且孩子只能 UPDATE 自己建的，所以"先建 5 分过审再改成 100 分"走不通）。
create or replace function app.create_task(
  p_assignee_id     uuid,
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
  v_ass  app.members%rowtype;
  v_task app.tasks%rowtype;
  v_start date;
  v_rec  jsonb;
  v_total int := coalesce(p_checkin_points, 0) + coalesce(p_completion_points, 0);
begin
  me := app.require_member();
  v_fid := me.family_id;
  v_start := coalesce(p_starts_on, app.family_today(v_fid));

  select * into v_ass from app.members where id = p_assignee_id and family_id = v_fid;
  if not found then raise exception 'ASSIGNEE_NOT_FOUND'; end if;

  -- 单日任务的"那一天"就是 starts_on，前端没必要两处都填。
  -- 反过来，如果调用方只给了 recurrence.date，starts_on 跟着它走。
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

  if not app.is_parent() then
    if v_ass.id <> me.id then raise exception 'FORBIDDEN: 孩子只能给自己建任务'; end if;
    if v_total > app.child_points_cap() then
      raise exception 'CHILD_POINTS_OVER_CAP: 孩子建的任务积分不能超过 %', app.child_points_cap();
    end if;
  end if;

  -- 每日上限不在这里管：任务可以设 50 分，但一天挣满上限后
  -- _post_ledger 会自动截断。两处都判反而会出现"建得出来却发不了分"的错觉。

  insert into app.tasks (
    family_id, assignee_id, created_by, title, icon_emoji, color,
    schedule_kind, recurrence, starts_on, ends_on, max_occurrences,
    window_start_time, window_end_time, due_time, is_deadline_style,
    checkin_points, checkin_daily_limit, completion_points
  ) values (
    v_fid, p_assignee_id, me.id, btrim(p_title), coalesce(p_icon_emoji, '⭐'),
    coalesce(p_color, 'sky'), coalesce(p_schedule_kind, 'once'),
    v_rec, v_start, p_ends_on, p_max_occurrences,
    p_window_start, p_window_end, p_due_time, coalesce(p_is_deadline, false),
    coalesce(p_checkin_points, 0), coalesce(p_checkin_limit, 1), coalesce(p_completion_points, 0)
  ) returning * into v_task;

  return jsonb_build_object(
    'task_id', v_task.id, 'version', v_task.version,
    'starts_on', v_task.starts_on, 'created_by', v_task.created_by);
end $$;

-- 家长在自己设备上直接建孩子成员（不用孩子当场在场）。
-- 同时签发一个认领码，孩子将来在自己设备上输入即可接管这个成员。
create or replace function app.add_member(
  p_nickname text, p_avatar text, p_role text, p_parent_token text
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare parent app.members%rowtype; m app.members%rowtype; v_code text;
begin
  parent := app.require_parent(p_parent_token);
  if p_role not in ('parent', 'child') then raise exception 'BAD_ROLE'; end if;

  insert into app.members (family_id, user_id, nickname, role, avatar_emoji)
  values (parent.family_id, gen_random_uuid(), btrim(p_nickname), p_role, coalesce(p_avatar, '🙂'))
  returning * into m;

  v_code := app._new_invite_code();
  insert into app.invites (family_id, code, role, member_id, created_by, max_uses)
  values (parent.family_id, v_code, p_role, m.id, parent.id, 1);

  return jsonb_build_object('member_id', m.id, 'user_id', m.user_id, 'claim_code', v_code);
end $$;


create or replace function app.join_family(
  p_code text, p_nickname text default null, p_avatar text default '🙂'
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_uid uuid; inv app.invites%rowtype; m app.members%rowtype;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'NO_AUTH'; end if;
  if exists (select 1 from app.members where user_id = v_uid) then
    raise exception 'ALREADY_IN_FAMILY';
  end if;

  select * into inv from app.invites where code = upper(btrim(p_code));
  if not found then raise exception 'INVITE_NOT_FOUND: 邀请码不存在'; end if;
  if inv.revoked_at is not null then raise exception 'INVITE_REVOKED: 邀请码已作废'; end if;
  if inv.expires_at is not null and inv.expires_at < now() then
    raise exception 'INVITE_EXPIRED: 邀请码已过期'; end if;
  if inv.max_uses > 0 and inv.used_count >= inv.max_uses then
    raise exception 'INVITE_USED_UP: 邀请码已用完'; end if;

  if inv.member_id is not null then
    -- 认领一个家长代建的成员
    update app.members
       set user_id = v_uid,
           nickname = coalesce(nullif(btrim(p_nickname), ''), nickname)
     where id = inv.member_id
     returning * into m;
  else
    if nullif(btrim(coalesce(p_nickname, '')), '') is null then
      raise exception 'NICKNAME_REQUIRED: 请填写昵称';
    end if;
    insert into app.members (family_id, user_id, nickname, role, avatar_emoji)
    values (inv.family_id, v_uid, btrim(p_nickname), inv.role, coalesce(p_avatar, '🙂'))
    returning * into m;
  end if;

  update app.invites set used_count = used_count + 1 where id = inv.id;

  return jsonb_build_object('family_id', m.family_id, 'member_id', m.id, 'role', m.role);
end $$;


create or replace function app.set_pin(p_pin text, p_old_pin text default null)
returns boolean
language plpgsql security definer set search_path = app, public as $$
declare me app.members%rowtype; v_salt text;
begin
  me := app.require_member();
  if me.role <> 'parent' then raise exception 'FORBIDDEN: 只有家长能设置 PIN'; end if;
  if p_pin !~ '^\d{4}$' then raise exception 'BAD_PIN: PIN 必须是 4 位数字'; end if;

  if me.pin_hash is not null then
    if p_old_pin is null or app.hash_pin(p_old_pin, me.pin_salt) <> me.pin_hash then
      raise exception 'WRONG_PIN: 原 PIN 不正确';
    end if;
  end if;

  v_salt := app.gen_salt_text();
  update app.members set pin_hash = app.hash_pin(p_pin, v_salt), pin_salt = v_salt
   where id = me.id;
  return true;
end $$;


-- 连续 5 次失败锁 15 分钟。PIN 只有 4 位，真正的防线是这个计数器。
create or replace function app.verify_parent_pin(p_pin text, p_member_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype; target app.members%rowtype;
  v_fails int; v_token text;
begin
  me := app.require_member();
  if p_member_id is null then
    target := me;
  else
    select * into target from app.members where id = p_member_id and family_id = me.family_id;
    if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  end if;

  if target.role <> 'parent' then raise exception 'NOT_A_PARENT'; end if;
  if target.pin_hash is null then raise exception 'PIN_NOT_SET: 还没有设置家长 PIN'; end if;

  select count(*) into v_fails from app.pin_attempts
   where member_id = target.id and not success and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then
    raise exception 'PIN_LOCKED: 尝试次数过多，请 15 分钟后再试';
  end if;

  if app.hash_pin(p_pin, target.pin_salt) <> target.pin_hash then
    insert into app.pin_attempts (member_id, success) values (target.id, false);
    raise exception 'WRONG_PIN: PIN 不正确';
  end if;

  insert into app.pin_attempts (member_id, success) values (target.id, true);
  delete from app.parent_sessions where expires_at < now();

  v_token := encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex');
  insert into app.parent_sessions (token, member_id, expires_at)
  values (v_token, target.id, now() + interval '30 minutes');

  return jsonb_build_object('token', v_token, 'member_id', target.id,
                            'expires_at', now() + interval '30 minutes');
end $$;


-- 一次拿全启动所需数据，省掉三个来回
-- ⚠ 在 010_signin.sql 里被再次 create or replace（members 每个元素追加
-- signed_today / active_today / fullstar_today），最终生效的是那一版。
create or replace function app.bootstrap_state()
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare v_fid uuid; v_mid uuid;
begin
  v_fid := app.current_family_id();
  if v_fid is null then return jsonb_build_object('in_family', false); end if;
  v_mid := app.current_member_id();

  return jsonb_build_object(
    'in_family', true,
    'today', app.family_today(v_fid),
    'me_id', v_mid,
    'family', (select to_jsonb(f) from app.families f where f.id = v_fid),
    'members', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.role, x.created_at)
        from (select id, family_id, user_id, nickname, role, avatar_emoji, points_balance,
                     (pin_hash is not null) as has_pin, created_at
                from app.members where family_id = v_fid and archived_at is null) x
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from app.invites i where i.family_id = v_fid and i.revoked_at is null
    ), '[]'::jsonb)
  );
end $$;
