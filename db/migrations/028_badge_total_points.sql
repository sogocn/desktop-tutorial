-- =============================================================================
-- 028_badge_total_points.sql —— 修复「累计获得积分」类勋章（大富翁/小金库）的计算口径
-- =============================================================================
-- 问题：011 起 evaluate_badges 的 total_points 分支用 m.points_balance（当前余额）
--      算进度。导致孩子一旦把积分花掉/兑换，余额低于阈值就"掉勋章"，与勋章文案
--      "累计获得 N 积分"的语义相悖（文案一直是对的，实现错了）。
-- 修正：total_points 改为「所有正向流水（流入）之和」，即累计获取的积分数，
--      不随消费/兑换/家长扣减而减少；撤销（reversal，负流水）不计入正向和，
--      天然等于"历史累计入账"，符合"累计获取"语义。
-- 数据纠正：迁移时对所有未归档成员重跑 evaluate_badges，补发此前因花掉积分而
--      漏发的 total_points 类勋章（如大富翁/小金库）。幂等（member_badges 唯一
--      约束兜底），已获得的不会重复发、也不会多扣积分；不存在"误发需撤回"的情况
--      （旧口径下能拿到勋章的人必然累计>=阈值，新口径下依然成立）。
-- 注意：本函数与 013 的版本完全一致，仅 total_points 分支一行不同，务必保留
--      013 的"首次获得发奖励分"逻辑，否则会回归勋章奖励分。
-- =============================================================================


-- ###########################################################################
-- 重建 evaluate_badges（仅 total_points 分支改为累计获取）
-- ###########################################################################
create or replace function app.evaluate_badges(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  m         app.members%rowtype;
  b         app.badges%rowtype;
  v_kind    text;
  v_dim     text;
  v_thr     int;
  v_prog    int;
  v_earned  boolean;
  v_at      timestamptz;
  v_mb_id   uuid;
  v_bonus   int;
  v_out     jsonb := '[]'::jsonb;
begin
  select * into m from app.members where id = p_member_id;
  if not found then return v_out; end if;

  for b in
    select * from app.badges
     where family_id = m.family_id or family_id is null
     order by (family_id is null), sort_order, name
  loop
    if not app.badge_rule_is_valid(b.rule) then continue; end if;

    v_kind := b.rule ->> 'kind';
    v_thr  := (b.rule ->> 'threshold')::int;
    v_prog := 0;
    v_dim  := null;
    v_mb_id := null;

    if v_kind = 'total_completions' then
      select count(*)::int into v_prog from app.task_occurrences o
       where o.assignee_id = m.id and o.status = 'completed';

    elsif v_kind = 'first_task' then
      -- 早起鸟：按家庭时区算，早上 8 点前完成的任务
      select count(*)::int into v_prog
        from app.task_occurrences o
        join app.families f on f.id = o.family_id
       where o.assignee_id = m.id and o.status = 'completed'
         and o.completed_at is not null
         and extract(hour from (o.completed_at at time zone f.timezone)) < 8;

    elsif v_kind = 'total_checkins' then
      select count(*)::int into v_prog from app.checkins c where c.member_id = m.id;

    elsif v_kind = 'total_points' then
      -- 累计获取的积分数 = 所有正向流水（流入）之和，不随消费/兑换而减少。
      -- 旧口径用 points_balance（当前余额），导致花掉积分就掉勋章，已修正。
      select coalesce(sum(delta), 0)::int into v_prog
        from app.point_ledger where member_id = m.id and delta > 0;

    elsif v_kind = 'total_signin' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.signed;

    elsif v_kind = 'total_active' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.active;

    elsif v_kind = 'total_fullstar' then
      select count(*)::int into v_prog from app.member_day d
       where d.member_id = m.id and d.fullstar;

    elsif v_kind = 'streak_days' then
      v_dim := coalesce(b.rule ->> 'dimension', 'active');
      v_prog := app.member_streak(m.id, v_dim);
    end if;

    v_earned := v_prog >= v_thr;

    if v_earned then
      -- returning id + on conflict do nothing：重复评估时拿不到行 → v_mb_id 为空。
      -- 奖励分因此天然只发一次，不用额外维护发放日志。
      insert into app.member_badges (member_id, badge_id, source_type, source_id)
      values (m.id, b.id, 'rule', b.id)
      on conflict (member_id, badge_id) do nothing
      returning id into v_mb_id;

      if v_mb_id is not null then
        v_bonus := app.badge_points_bonus(m.family_id, b.id);
        if v_bonus > 0 then
          perform app._post_ledger(m.id, v_bonus, 'badge', v_mb_id, 0,
                                   '勋章 · ' || b.name, null, m.id);
        end if;
      end if;
    end if;

    select mb.awarded_at into v_at from app.member_badges mb
     where mb.member_id = m.id and mb.badge_id = b.id;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id',          b.id,
      'badge_id',    b.id,
      'code',        b.code,
      'name',        b.name,
      'emoji',       b.emoji,
      'tier',        b.tier,
      'description', b.description,
      'rule',        b.rule,
      'kind',        v_kind,
      'dimension',   v_dim,
      'progress',    least(v_prog, v_thr),
      'raw_progress', v_prog,
      'threshold',   v_thr,
      'earned',      (v_at is not null),
      'earned_at',   v_at,
      'is_system',   (b.family_id is null),
      'points_bonus', app.badge_points_bonus(m.family_id, b.id)));
  end loop;

  return v_out;
end $$;


-- ###########################################################################
-- 数据纠正：对所有未归档成员重跑评估，补发历史漏发的 total_points 类勋章
-- ###########################################################################
do $$
declare r record;
begin
  for r in
    select id from app.members where archived_at is null
  loop
    perform app.evaluate_badges(r.id);
  end loop;
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
