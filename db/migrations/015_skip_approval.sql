-- =============================================================================
-- 015_skip_approval.sql —— 孩子请假需家长审批
-- =============================================================================
-- 现状：app.skip_occurrence 立即生效（孩子自己就能把某天置为 skipped）。
-- 新需求：孩子发起的请假必须家长同意后才生效。
--
-- 确认的方案（三分支，用户全选推荐）：
--   1) 仅孩子发起需审批；家长（当前前端无「请假」入口）直接走 skip_occurrence 即时生效。
--   2) 审批合并进现有「兑换审批」中心（ApprovalsSheet 复用）。
--   3) 日历暂不额外渲染标记，仅在任务详情页提示「请假申请审核中」。
--
-- 关键设计：
--   * skip_requests 待批表（pending/approved/rejected）。
--   * request_skip：孩子提交只写 pending 行，不动 task_occurrences。
--   * decide_skip：家长走 _parent_guard 免 PIN；同意时【复用现有 skip_occurrence】
--     （退完成分 / 置 skipped / 刷新满星连续一条龙），零重复逻辑；
--     驳回则标记 rejected 保持原状。
-- =============================================================================

create table app.skip_requests (
  id              uuid primary key default gen_random_uuid(),
  family_id       uuid not null references app.families(id) on delete cascade,
  task_id         uuid not null references app.tasks(id) on delete cascade,
  assignee_id     uuid not null references app.members(id) on delete cascade,
  occurrence_date date not null,
  requester_id    uuid not null references app.members(id) on delete cascade,
  note            text check (note is null or length(note) <= 300),
  status          text not null default 'pending'
                    check (status in ('pending', 'approved', 'rejected')),
  decided_at      timestamptz,
  decided_by      uuid references app.members(id),
  created_at      timestamptz not null default now()

  -- 同一天同一孩子不能重复提交待批（驳回后可再提）。
  -- 表级 UNIQUE 约束不支持 WHERE 谓词，故用【部分唯一索引】单独建：
  -- 仅约束 status='pending' 的行，驳回后的历史行不影响再次提交。
);
create unique index skip_req_pending_uq
  on app.skip_requests (task_id, occurrence_date, assignee_id)
  where status = 'pending';
create index skip_req_family_idx on app.skip_requests (family_id, created_at desc);
create index skip_req_pending_idx on app.skip_requests (family_id) where status = 'pending';


-- -----------------------------------------------------------------------------
-- 孩子提交请假申请：只写 pending 行，绝不改动 occurrence
-- -----------------------------------------------------------------------------
create or replace function app.request_skip(
  p_task_id uuid, p_date date, p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me  app.members%rowtype;
  t   app.tasks%rowtype;
  o   app.task_occurrences%rowtype;
  rid uuid;
begin
  me := app.require_member();
  select * into t from app.tasks where id = p_task_id;
  if not found or t.family_id <> me.family_id then raise exception 'TASK_NOT_FOUND'; end if;
  -- 只给【自己】名下的任务请假；家长直接走 skip_occurrence，不进这条流程
  if t.assignee_id <> me.id then
    raise exception 'FORBIDDEN: 只能给自己的任务请假';
  end if;

  -- 已经置为 skipped，没必要再走审批
  select * into o from app.task_occurrences
   where task_id = p_task_id and occurrence_date = p_date;
  if found and o.status = 'skipped' then
    return jsonb_build_object('occurrence_id', o.id, 'already', 'skipped');
  end if;

  -- 已有待批，避免重复提交
  if exists (
    select 1 from app.skip_requests
     where task_id = p_task_id and occurrence_date = p_date
       and assignee_id = me.id and status = 'pending'
  ) then
    return jsonb_build_object('status', 'pending', 'message', '请假申请已在审核中');
  end if;

  insert into app.skip_requests (family_id, task_id, assignee_id, occurrence_date, requester_id, note)
  values (t.family_id, p_task_id, me.id, p_date, me.id, p_note)
  returning id into rid;

  return jsonb_build_object(
    'request_id', rid,
    'status', 'pending',
    'message', '已提交请假申请，等家长同意');
end $$;


-- -----------------------------------------------------------------------------
-- 家长审批：免 PIN（角色闸门）；同意时复用 skip_occurrence
-- -----------------------------------------------------------------------------
create or replace function app.decide_skip(
  p_req_id uuid, p_decision text, p_parent_token text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  req    app.skip_requests%rowtype;
begin
  parent := app._parent_guard(p_parent_token);
  if p_decision not in ('approved', 'rejected') then
    raise exception 'BAD_DECISION';
  end if;

  select * into req from app.skip_requests where id = p_req_id;
  if not found or req.family_id <> parent.family_id then
    raise exception 'SKIP_REQUEST_NOT_FOUND';
  end if;
  if req.status <> 'pending' then
    raise exception 'ALREADY_DECIDED: 这条请假已经处理过了';
  end if;

  update app.skip_requests
     set status = p_decision, decided_at = now(), decided_by = parent.id
   where id = req.id;

  if p_decision = 'approved' then
    -- 复用现有 skip_occurrence：退完成分 / 置 skipped / 刷新满星连续
    -- 当前会话是家长，skip_occurrence 的家长分支放行，余额结算到被请假的孩子
    perform app.skip_occurrence(req.task_id, req.occurrence_date, req.note);
  end if;

  return jsonb_build_object(
    'request_id', req.id, 'status', p_decision,
    'balance', (select points_balance from app.members where id = req.assignee_id));
end $$;


-- -----------------------------------------------------------------------------
-- 家长拉取待批请假（并入现有审批中心）
-- -----------------------------------------------------------------------------
create or replace function app.list_skip_requests(p_parent_token text default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me app.members%rowtype;
begin
  me := app._parent_guard(p_parent_token);
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.requested_at desc)
    from (
      select sr.id,
             sr.task_id,
             sr.assignee_id,
             sr.occurrence_date,
             sr.note,
             sr.status,
             sr.created_at as requested_at,
             m.nickname as assignee_name,
             t.title     as task_title,
             t.icon_emoji as task_emoji
        from app.skip_requests sr
        join app.members m on m.id = sr.assignee_id
        join app.tasks   t on t.id = sr.task_id
       where sr.family_id = me.family_id
         and sr.status = 'pending'
    ) x
  ), '[]'::jsonb);
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
