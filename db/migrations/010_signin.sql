-- =============================================================================
-- 010_signin.sql —— 签到 / 活跃 / 满星 / 连续奖励 / 补签卡 / 家长手动调分
-- =============================================================================
-- 为什么新开一个文件而不是直接改 007：
--   适配器按文件名记录已应用的迁移（public.__migrations），已经建过库的设备
--   永远不会重跑 007。所以凡是"存量库也必须拿到"的函数改动，都要落在一个
--   全新的迁移文件里。007 里同名函数保留了同样的修复，新库两遍结果一致。
--
-- 三个维度，全部**按孩子个人**统计（每个 member 只看自己名下的任务）：
--   signed   主动签到（每天 +2 分）
--   active   当天名下至少完成 1 个任务
--   fullstar 当天名下所有任务都已完成或请假（没有任务的日子不算满星）
--
-- 连续天数奖励（同一档只发一次，member_streak_awards 防重）：
--   signin    3→+10   7→+30   30→+100
--   active    3→+15   7→+40   30→+150
--   fullstar  3→+20   7→+60   30→+200
-- 每满 7 天（7/14/21…）额外发一张对应的补签卡，member_card_grants 防重。
-- =============================================================================


-- ###########################################################################
-- 一、流水账来源枚举扩容
-- ###########################################################################
-- 004 里已经写成新枚举了（新库直接就是对的），这里为存量库补一遍。
-- 同名 drop/add 对新库是等价替换，重复执行无副作用。
alter table app.point_ledger drop constraint if exists point_ledger_source_type_check;
alter table app.point_ledger add constraint point_ledger_source_type_check
  check (source_type in ('checkin', 'completion', 'milestone', 'manual', 'redemption',
                         'badge', 'reversal', 'signin', 'streak'));


-- ###########################################################################
-- 二、表
-- ###########################################################################

-- 一个成员的一天。三个布尔就是三条连续链的原始事实。
-- retro_active / retro_fullstar 是"补卡盖过来的"标记：refresh_day_status 会
-- 按当天任务实况重算 active/fullstar，没有这两个粘性标记，补的活跃会被立刻刷掉。
create table if not exists app.member_day (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references app.members(id) on delete cascade,
  day           date not null,
  signed        boolean not null default false,
  active        boolean not null default false,
  fullstar      boolean not null default false,
  retro_active   boolean not null default false,
  retro_fullstar boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_member_day unique (member_id, day)
);
create index if not exists member_day_member_idx on app.member_day (member_id, day desc);

-- 补签卡库存
create table if not exists app.member_cards (
  member_id  uuid not null references app.members(id) on delete cascade,
  kind       text not null check (kind in ('retro_signin', 'retro_active', 'retro_fullstar')),
  qty        int not null default 0 check (qty >= 0),
  updated_at timestamptz not null default now(),
  constraint pk_member_cards primary key (member_id, kind)
);

-- 发卡日志。streak_at = 触发时的连续天数（7 / 14 / 21 …），防止同一档反复发卡。
create table if not exists app.member_card_grants (
  member_id  uuid not null references app.members(id) on delete cascade,
  kind       text not null,
  streak_at  int  not null,
  granted_at timestamptz not null default now(),
  constraint uq_card_grant unique (member_id, kind, streak_at)
);

-- 连续档位积分奖励的发放日志。tier ∈ (3, 7, 30)。
-- 用它防重而不是拿"当前 streak 值"防重：streak 每天都在变，档位不变。
create table if not exists app.member_streak_awards (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references app.members(id) on delete cascade,
  kind       text not null check (kind in ('signin', 'active', 'fullstar')),
  tier       int  not null check (tier in (3, 7, 30)),
  points     int  not null default 0,
  awarded_at timestamptz not null default now(),
  constraint uq_streak_award unique (member_id, kind, tier)
);


-- ###########################################################################
-- 三、权限（008 已经跑过，新表得自己把 grant / RLS 补上）
-- ###########################################################################
grant select on app.member_day, app.member_cards,
                app.member_card_grants, app.member_streak_awards to authenticated;
grant all on app.member_day, app.member_cards,
             app.member_card_grants, app.member_streak_awards to service_role;

alter table app.member_day           enable row level security;
alter table app.member_cards         enable row level security;
alter table app.member_card_grants   enable row level security;
alter table app.member_streak_awards enable row level security;

drop policy if exists member_day_select on app.member_day;
create policy member_day_select on app.member_day for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

drop policy if exists member_cards_select on app.member_cards;
create policy member_cards_select on app.member_cards for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

drop policy if exists card_grants_select on app.member_card_grants;
create policy card_grants_select on app.member_card_grants for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));

drop policy if exists streak_awards_select on app.member_streak_awards;
create policy streak_awards_select on app.member_streak_awards for select to authenticated
  using (exists (select 1 from app.members m
                  where m.id = member_id and m.family_id = app.current_family_id()));


-- ###########################################################################
-- 四、家长守卫（PIN 是可选的家长锁）
-- ###########################################################################
-- require_parent 硬要 token，可是 PIN 本来就是可选的：没设 PIN 的家庭
-- 一个 token 都拿不到，家长就永远调不了分。这里把两种情况都收进来：
--   * 给了 token   → 按 require_parent 严格校验
--   * 没给 token   → 必须是家长身份；而且**一旦设过 PIN 就必须验**
--     （不然"家长解锁后把手机递给孩子"这条路又通了）
-- 防线的层次没变：孩子无论如何都过不了这道门。
create or replace function app._parent_guard(p_token text)
returns app.members
language plpgsql stable security definer set search_path = app, public as $$
declare me app.members%rowtype;
begin
  if p_token is not null then
    return app.require_parent(p_token);
  end if;

  me := app.require_member();
  if me.role <> 'parent' then
    raise exception 'FORBIDDEN: 只有家长能做这件事';
  end if;
  if me.pin_hash is not null then
    raise exception 'PARENT_TOKEN_INVALID: 需要家长验证，请先输入 PIN';
  end if;
  return me;
end $$;


-- ###########################################################################
-- 五、家长手动调分
-- ###########################################################################
-- 打赏和扣除都走这里，一样只追加流水（铁律 5）。
-- 家长只能调孩子：调自己等于自己给自己发钱，规则会立刻失去意义。
create or replace function app.adjust_member_points(
  p_parent_token text,
  p_member_id    uuid,
  p_delta        int,
  p_reason       text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  target app.members%rowtype;
  e      app.point_ledger%rowtype;
  v_bal  int;
begin
  parent := app._parent_guard(p_parent_token);

  if p_delta is null or p_delta = 0 then
    raise exception 'BAD_DELTA: 调整分值不能为 0';
  end if;
  if abs(p_delta) > 100000 then
    raise exception 'BAD_DELTA: 单次调整不能超过 100000 分';
  end if;

  select * into target from app.members
   where id = p_member_id and family_id = parent.family_id and archived_at is null;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  if target.id = parent.id then
    raise exception 'FORBIDDEN: 家长不能给自己调分';
  end if;

  select points_balance into v_bal from app.members where id = target.id for update;
  if v_bal + p_delta < 0 then
    raise exception 'NOT_ENOUGH_POINTS: 余额只有 %，最多扣 %', v_bal, v_bal;
  end if;

  e := app._post_ledger(target.id, p_delta, 'manual', null, 0,
                        coalesce(nullif(btrim(p_reason), ''),
                                 case when p_delta > 0 then '家长打赏' else '家长扣分' end),
                        null, parent.id);

  return jsonb_build_object(
    'member_id', target.id,
    'delta', coalesce(e.delta, 0),
    'entry_id', e.id,
    'balance', (select points_balance from app.members where id = target.id));
end $$;


-- ###########################################################################
-- 六、当天状态：活跃 / 满星
-- ###########################################################################
-- "当天有哪些任务"= 规则虚拟展开 ∪ 已落库实例（归档任务和改过规则的历史也要算）。
-- 只看 task_occurrences 会把"3 个任务只落库 1 个"误判成满星。
create or replace function app.refresh_day_status(p_member_id uuid, p_date date)
returns app.member_day
language plpgsql security definer set search_path = app, public as $$
declare
  md       app.member_day%rowtype;
  v_total  int := 0;
  v_done   int := 0;
  v_closed int := 0;
  v_active boolean;
  v_full   boolean;
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
    select coalesce(o.status, 'pending') as status
      from sched s
      left join app.task_occurrences o
             on o.task_id = s.task_id and o.occurrence_date = p_date
  )
  select count(*)::int,
         count(*) filter (where status = 'completed')::int,
         count(*) filter (where status in ('completed', 'skipped'))::int
    into v_total, v_done, v_closed
    from st;

  v_active := v_done > 0;
  -- 没有任务的日子不算满星，否则"什么都不安排"就成了最优策略
  v_full := v_total > 0 and v_closed = v_total;

  insert into app.member_day (member_id, day, active, fullstar)
  values (p_member_id, p_date, v_active, v_full)
  on conflict (member_id, day) do update
     set active   = excluded.active   or member_day.retro_active,
         fullstar = excluded.fullstar or member_day.retro_fullstar,
         updated_at = now()
  returning * into md;

  return md;
end $$;


-- ###########################################################################
-- 七、连续天数
-- ###########################################################################
-- 从"今天"往回逐日看。今天还没达成不算断连（一天还没过完），
-- 昨天及更早只要有一天没达成就断。最多回看 400 天。
create or replace function app.member_streak(p_member_id uuid, p_kind text)
returns int
language plpgsql stable security definer set search_path = app, public as $$
declare
  v_fid   uuid;
  v_today date;
  d       date;
  v_hit   boolean;
  n       int := 0;
begin
  if p_kind not in ('signin', 'active', 'fullstar') then
    raise exception 'BAD_STREAK_KIND: % 不是有效维度', p_kind;
  end if;

  select family_id into v_fid from app.members where id = p_member_id;
  if v_fid is null then return 0; end if;

  v_today := app.family_today(v_fid);
  d := v_today;

  loop
    select coalesce((
      select case p_kind
               when 'signin'   then md.signed
               when 'active'   then md.active
               else                 md.fullstar
             end
        from app.member_day md
       where md.member_id = p_member_id and md.day = d), false)
      into v_hit;

    if v_hit then
      n := n + 1;
    elsif d = v_today then
      null;  -- 今天还有机会，不算断
    else
      exit;
    end if;

    d := d - 1;
    exit when d < v_today - 400;
  end loop;

  return n;
end $$;


-- 连续奖励结算。幂等：档位积分靠 member_streak_awards，补签卡靠 member_card_grants。
create or replace function app.evaluate_streaks(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  v_fid     uuid;
  v_today   date;
  v_kind    text;
  v_streak  int;
  v_tier    int;
  v_points  int;
  v_card    text;
  v_award   app.member_streak_awards%rowtype;
  v_granted text;
  v_paid    int := 0;
  v_cards   int := 0;
  v_out     jsonb := '{}'::jsonb;
begin
  select family_id into v_fid from app.members where id = p_member_id;
  if v_fid is null then return jsonb_build_object('member_id', p_member_id, 'skipped', true); end if;
  v_today := app.family_today(v_fid);

  foreach v_kind in array array['signin', 'active', 'fullstar'] loop
    v_streak := app.member_streak(p_member_id, v_kind);
    v_out := v_out || jsonb_build_object(v_kind, v_streak);

    -- ---- 档位积分 --------------------------------------------------------
    foreach v_tier in array array[3, 7, 30] loop
      if v_streak < v_tier then continue; end if;

      v_points := case v_kind
        when 'signin'   then case v_tier when 3 then 10 when 7 then 30 else 100 end
        when 'active'   then case v_tier when 3 then 15 when 7 then 40 else 150 end
        else                 case v_tier when 3 then 20 when 7 then 60 else 200 end
      end;

      -- 手动清空：on conflict do nothing 撞上约束时不会返回行，
      -- 别让上一轮循环留下的值被当成"这次发了"
      v_award := null;
      insert into app.member_streak_awards (member_id, kind, tier, points)
      values (p_member_id, v_kind, v_tier, v_points)
      on conflict (member_id, kind, tier) do nothing
      returning * into v_award;

      if v_award.id is not null then
        perform app._post_ledger(
          p_member_id, v_points, 'streak', v_award.id, 0,
          format('连续%s天%s', v_tier,
                 case v_kind when 'signin' then '签到'
                             when 'active' then '完成任务'
                             else '满星' end),
          v_today, p_member_id);
        v_paid := v_paid + v_points;
      end if;
    end loop;

    -- ---- 每满 7 天发一张补签卡 -------------------------------------------
    if v_streak >= 7 and v_streak % 7 = 0 then
      v_card := case v_kind
        when 'signin' then 'retro_signin'
        when 'active' then 'retro_active'
        else               'retro_fullstar'
      end;

      v_granted := null;
      insert into app.member_card_grants (member_id, kind, streak_at)
      values (p_member_id, v_card, v_streak)
      on conflict (member_id, kind, streak_at) do nothing
      returning kind into v_granted;

      if v_granted is not null then
        insert into app.member_cards (member_id, kind, qty)
        values (p_member_id, v_card, 1)
        on conflict (member_id, kind) do update
           set qty = member_cards.qty + 1, updated_at = now();
        v_cards := v_cards + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'member_id', p_member_id,
    'streak', v_out,
    'points_awarded', v_paid,
    'cards_granted', v_cards);
end $$;


-- ###########################################################################
-- 八、签到
-- ###########################################################################
-- 只能签"今天"。补过去的日子必须消耗补签卡，否则连续奖励一文不值。
create or replace function app.do_signin(p_date date default null)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  md      app.member_day%rowtype;
  e       app.point_ledger%rowtype;
  v_today date;
  v_date  date;
  v_award int := 0;
begin
  me := app.require_member();
  v_today := app.family_today(me.family_id);
  v_date := coalesce(p_date, v_today);

  if v_date <> v_today then
    raise exception 'BAD_SIGNIN_DATE: 只能签今天（%），补以前的日子请用补签卡', v_today;
  end if;

  select * into md from app.member_day where member_id = me.id and day = v_date;
  if md.id is not null and md.signed then
    return jsonb_build_object(
      'signed', true, 'already', true, 'points_awarded', 0,
      'balance', (select points_balance from app.members where id = me.id),
      'summary', app.get_signin_summary(me.id));
  end if;

  insert into app.member_day (member_id, day, signed)
  values (me.id, v_date, true)
  on conflict (member_id, day) do update
     set signed = true, updated_at = now()
  returning * into md;

  -- source_id 用 member_day 行的 id：一个成员一天只有一行，天然幂等
  e := app._post_ledger(me.id, 2, 'signin', md.id, 0, '每日签到', v_date, me.id);
  v_award := coalesce(e.delta, 0);

  perform app.refresh_day_status(me.id, v_date);
  perform app.evaluate_streaks(me.id);
  perform app.evaluate_badges(me.id);

  return jsonb_build_object(
    'signed', true, 'already', false, 'points_awarded', v_award,
    'balance', (select points_balance from app.members where id = me.id),
    'summary', app.get_signin_summary(me.id));
end $$;


-- 补签 / 补活跃 / 补满星。消耗一张卡，把那天的对应维度点亮。
create or replace function app.use_retro_card(
  p_kind      text,
  p_date      date,
  p_member_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  target  app.members%rowtype;
  md      app.member_day%rowtype;
  v_today date;
  v_qty   int;
  v_done  boolean;
begin
  me := app.require_member();

  if p_kind not in ('retro_signin', 'retro_active', 'retro_fullstar') then
    raise exception 'BAD_CARD_KIND: % 不是有效的补签卡', p_kind;
  end if;

  if p_member_id is null or p_member_id = me.id then
    target := me;
  else
    select * into target from app.members
     where id = p_member_id and family_id = me.family_id and archived_at is null;
    if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
    if me.role <> 'parent' then raise exception 'FORBIDDEN: 只能用自己的补签卡'; end if;
  end if;

  v_today := app.family_today(target.family_id);
  if p_date is null or p_date > v_today then
    raise exception 'BAD_DATE: 不能补未来的日子';
  end if;
  if p_date < v_today - 30 then
    raise exception 'RETRO_TOO_OLD: 只能补最近 30 天内的日子';
  end if;

  select * into md from app.member_day where member_id = target.id and day = p_date;
  v_done := case p_kind
    when 'retro_signin'   then coalesce(md.signed, false)
    when 'retro_active'   then coalesce(md.active, false)
    else                       coalesce(md.fullstar, false)
  end;
  if v_done then
    raise exception 'ALREADY_MARKED: % 这天已经达成，不用补', p_date;
  end if;

  select qty into v_qty from app.member_cards
   where member_id = target.id and kind = p_kind for update;
  if v_qty is null or v_qty <= 0 then
    raise exception 'NO_RETRO_CARD: 没有可用的%',
      case p_kind when 'retro_signin' then '补签卡'
                  when 'retro_active' then '补活跃卡'
                  else '补满星卡' end;
  end if;

  update app.member_cards set qty = qty - 1, updated_at = now()
   where member_id = target.id and kind = p_kind;

  insert into app.member_day (member_id, day, signed, active, fullstar,
                              retro_active, retro_fullstar)
  values (target.id, p_date,
          p_kind = 'retro_signin',
          p_kind = 'retro_active',
          p_kind = 'retro_fullstar',
          p_kind = 'retro_active',
          p_kind = 'retro_fullstar')
  on conflict (member_id, day) do update
     set signed         = member_day.signed         or (p_kind = 'retro_signin'),
         active         = member_day.active         or (p_kind = 'retro_active'),
         fullstar       = member_day.fullstar       or (p_kind = 'retro_fullstar'),
         retro_active   = member_day.retro_active   or (p_kind = 'retro_active'),
         retro_fullstar = member_day.retro_fullstar or (p_kind = 'retro_fullstar'),
         updated_at     = now()
  returning * into md;

  perform app.refresh_day_status(target.id, p_date);
  perform app.evaluate_streaks(target.id);
  perform app.evaluate_badges(target.id);

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind,
    'date', p_date,
    'remaining', (select qty from app.member_cards
                   where member_id = target.id and kind = p_kind),
    'balance', (select points_balance from app.members where id = target.id),
    'summary', app.get_signin_summary(target.id));
end $$;


-- 前端签到卡一次拿全：今天三个维度 + 三条连续链 + 补签卡库存 + 已发档位
create or replace function app.get_signin_summary(p_member_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare
  me      app.members%rowtype;
  target  app.members%rowtype;
  md      app.member_day%rowtype;
  v_today date;
begin
  me := app.require_member();

  if p_member_id is null or p_member_id = me.id then
    target := me;
  else
    select * into target from app.members
     where id = p_member_id and family_id = me.family_id;
    if not found then raise exception 'FORBIDDEN: 只能看本家庭成员'; end if;
  end if;

  v_today := app.family_today(target.family_id);
  select * into md from app.member_day where member_id = target.id and day = v_today;

  return jsonb_build_object(
    'member_id', target.id,
    'today', v_today,
    'signed_today',   coalesce(md.signed, false),
    'active_today',   coalesce(md.active, false),
    'fullstar_today', coalesce(md.fullstar, false),
    'streak', jsonb_build_object(
      'signin',   app.member_streak(target.id, 'signin'),
      'active',   app.member_streak(target.id, 'active'),
      'fullstar', app.member_streak(target.id, 'fullstar')),
    'totals', jsonb_build_object(
      'signin',   (select count(*)::int from app.member_day d
                    where d.member_id = target.id and d.signed),
      'active',   (select count(*)::int from app.member_day d
                    where d.member_id = target.id and d.active),
      'fullstar', (select count(*)::int from app.member_day d
                    where d.member_id = target.id and d.fullstar)),
    'retro_cards', jsonb_build_object(
      'retro_signin',   coalesce((select qty from app.member_cards
                                   where member_id = target.id and kind = 'retro_signin'), 0),
      'retro_active',   coalesce((select qty from app.member_cards
                                   where member_id = target.id and kind = 'retro_active'), 0),
      'retro_fullstar', coalesce((select qty from app.member_cards
                                   where member_id = target.id and kind = 'retro_fullstar'), 0)),
    'awarded_tiers', coalesce((
      select jsonb_agg(jsonb_build_object('kind', a.kind, 'tier', a.tier, 'points', a.points)
                       order by a.kind, a.tier)
        from app.member_streak_awards a where a.member_id = target.id), '[]'::jsonb));
end $$;


-- ###########################################################################
-- 九、业务动作接上签到系统
-- ###########################################################################
-- 这三个函数 007 里已经有一版；这里是最终版：在原有逻辑之后追加
-- refresh_day_status + evaluate_streaks + evaluate_badges，让"完成任务"
-- 自动驱动活跃 / 满星 / 连续奖励 / 勋章，全程没有定时任务。

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

  -- source_seq 取下一个序号，而不是写死 0。
  -- 撤销完成只追加 reversal（铁律 5），旧的 primary 还在表里；写死 0 会撞
  -- uq_ledger_source，被 _post_ledger 的 on conflict 静默吞掉 —— 于是
  -- "撤销后再点完成"永远不加分。这就是那个积分 bug 的根。
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

  -- 撤最后一条还没被撤销的完成记账（完成→撤销→再完成会有 seq 0/1/2…）
  select l.* into src from app.point_ledger l
   where l.entry_kind = 'primary' and l.source_type = 'completion' and l.source_id = o.id
     and not exists (select 1 from app.point_ledger r where r.reverses_id = l.id)
   order by l.source_seq desc
   limit 1;
  if src.id is not null then
    perform app._reverse_ledger(src.id, '撤回完成 · ' || o.snap_title, me.id);
  end if;

  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);

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

  -- 已完成的改成请假，要把完成分退回去（取最后一条未撤销的）
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

  perform app.refresh_day_status(t.assignee_id, p_date);
  perform app.evaluate_streaks(t.assignee_id);

  return jsonb_build_object(
    'occurrence_id', o.id,
    'balance', (select points_balance from app.members where id = t.assignee_id));
end $$;


-- ###########################################################################
-- 十、bootstrap 带上今天的签到状态
-- ###########################################################################
-- streak / 补签卡不塞进来：那是签到卡自己的事，走 get_signin_summary 按需拉，
-- 免得每次启动都算三条连续链。
create or replace function app.bootstrap_state()
returns jsonb
language plpgsql stable security definer set search_path = app, public as $$
declare v_fid uuid; v_mid uuid; v_today date;
begin
  v_fid := app.current_family_id();
  if v_fid is null then return jsonb_build_object('in_family', false); end if;
  v_mid := app.current_member_id();
  v_today := app.family_today(v_fid);

  return jsonb_build_object(
    'in_family', true,
    'today', v_today,
    'me_id', v_mid,
    'family', (select to_jsonb(f) from app.families f where f.id = v_fid),
    'members', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.role, x.created_at)
        from (select m.id, m.family_id, m.user_id, m.nickname, m.role, m.avatar_emoji,
                     m.points_balance, (m.pin_hash is not null) as has_pin, m.created_at,
                     coalesce(md.signed, false)   as signed_today,
                     coalesce(md.active, false)   as active_today,
                     coalesce(md.fullstar, false) as fullstar_today
                from app.members m
                left join app.member_day md
                       on md.member_id = m.id and md.day = v_today
               where m.family_id = v_fid and m.archived_at is null) x
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from app.invites i where i.family_id = v_fid and i.revoked_at is null
    ), '[]'::jsonb)
  );
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
