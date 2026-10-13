-- =============================================================================
-- 026_no_redemption_approval.sql —— 取消积分兑换的家长审批，兑换即时生效
-- =============================================================================
-- 用户诉求：孩子用积分兑换时不要再卡在「等家长确认」，点一下就直接生效。
--
-- 根因：013 的 app.redeem() 插入 redemptions 时**永远**写 status='pending'，
-- requires_approval 只影响返回给前端的提示文案。也就是说不管商品配不配审批，
-- 都得家长去审批中心点一次「同意」才算数。
--
-- 改法（保留能力、只改默认）：
--   1. reward_items.requires_approval 默认 true → false，存量一并刷成 false。
--      线上所有商品随即变成免审批；将来若想对大额兑换单独开审批，把这列设回 true
--      即可，app.redeem 的分支还在（前端没有入口去改它，属保留能力不是死开关）。
--   2. app.redeem()：免审批时直接落 status='approved' 并写 decided_at，
--      不再进待批队列。扣分 / 扣库存 / 发补卡的原有行为一律不动。
--   3. app.decide_redemption() 新增「事后撤销」：家长可对已生效（approved/delivered）
--      的兑换执行 'cancelled'，退分 + 收回补卡。
--      ⚠️ 这不是加功能，是补本次改动引入的回归：审批取消后家长失去了事前驳回的时机，
--      孩子误兑 / 多兑（尤其是补签卡这类立刻进库存的东西）再也没有回头路。
--      decide_redemption 里的退分退卡逻辑本来就是为 rejected 写的，'cancelled'
--      走的是同一条路径，天然一致。
--   4. app.seed_reward_items() 现金那条显式写的 true 改成 false，
--      否则新建家庭的现金又回到需要审批。
-- =============================================================================

-- ---- 一、默认免审批（存量一起刷，否则老家庭的现金还是 pending） ---------------
alter table app.reward_items alter column requires_approval set default false;

update app.reward_items set requires_approval = false where requires_approval;


-- ---- 二、兑换：免审批即生效 --------------------------------------------------
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
  v_qty  int;
  -- 026：免审批的商品直接落 approved，不再进待批队列
  v_status text;
begin
  me := app.require_member();
  if p_quantity is null or p_quantity <= 0 then raise exception 'BAD_QTY'; end if;

  select * into item from app.reward_items where id = p_item_id;
  if not found or item.family_id <> me.family_id then raise exception 'ITEM_NOT_FOUND'; end if;
  if not item.active then raise exception 'ITEM_INACTIVE: 这个商品已下架'; end if;

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

  select points_balance into v_bal from app.members where id = me.id for update;
  if v_bal < v_cost then
    raise exception 'NOT_ENOUGH_POINTS: 积分不够，还差 %', v_cost - v_bal;
  end if;

  v_status := case when item.requires_approval then 'pending' else 'approved' end;

  insert into app.redemptions (family_id, member_id, item_id, quantity, points_cost,
                               snap_name, snap_emoji, note, status, decided_at)
  values (me.family_id, me.id, item.id, p_quantity, v_cost,
          item.name, item.emoji, nullif(btrim(coalesce(p_note, '')), ''),
          v_status, case when v_status = 'pending' then null else now() end)
  returning id into v_id;

  perform app._post_ledger(me.id, -v_cost, 'redemption', v_id, 0,
                           '兑换 ' || item.name, null, me.id);

  if item.stock is not null then
    update app.reward_items set stock = stock - p_quantity where id = item.id;
  end if;

  -- 补卡：直接进库存。分数已经扣了，卡先给；家长撤销时 decide_redemption 再收回。
  if item.item_kind = 'card' and item.card_kind is not null then
    v_qty := ceil(p_quantity)::int;
    insert into app.member_cards (member_id, kind, qty)
    values (me.id, item.card_kind, v_qty)
    on conflict (member_id, kind) do update
       set qty = member_cards.qty + excluded.qty, updated_at = now();
  end if;

  return jsonb_build_object(
    'redemption_id', v_id,
    'points_spent', v_cost,
    'balance', (select points_balance from app.members where id = me.id),
    'pending', item.requires_approval,
    'granted_card', item.card_kind,
    'granted_qty', case when item.item_kind = 'card' then ceil(p_quantity)::int else 0 end,
    'message', case when item.requires_approval then '已提交，等家长确认' else '兑换成功' end);
end $$;


-- ---- 三、审批 / 撤销：已生效的兑换也能作废 ------------------------------------
-- 允许的状态迁移：
--   pending   → approved / rejected / delivered / cancelled   （原样）
--   approved  → delivered / cancelled                        （026 新增）
--   delivered → cancelled                                    （026 新增）
--   rejected / cancelled 为终态，再动一律 ALREADY_DECIDED。
create or replace function app.decide_redemption(
  p_redemption_id uuid, p_decision text, p_parent_token text default null
)
returns jsonb
language plpgsql security definer set search_path = app, public as $$
declare
  parent app.members%rowtype;
  r      app.redemptions%rowtype;
  item   app.reward_items%rowtype;
  src    app.point_ledger%rowtype;
begin
  parent := app.require_parent(p_parent_token);
  if p_decision not in ('approved', 'rejected', 'delivered', 'cancelled') then
    raise exception 'BAD_DECISION';
  end if;

  select * into r from app.redemptions where id = p_redemption_id;
  if not found or r.family_id <> parent.family_id then raise exception 'REDEMPTION_NOT_FOUND'; end if;

  -- 终态不许再动；已生效的（approved/delivered）不能再走"同意/驳回"，只能交付或撤销
  if r.status in ('rejected', 'cancelled') then
    raise exception 'ALREADY_DECIDED: 这笔已经处理过了';
  end if;
  if r.status <> 'pending' and p_decision in ('approved', 'rejected') then
    raise exception 'ALREADY_DECIDED: 这笔已经生效了，只能撤销';
  end if;

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

    -- 补卡跟着退：分都退回去了，卡不能留在手里
    select * into item from app.reward_items where id = r.item_id;
    if item.item_kind = 'card' and item.card_kind is not null then
      update app.member_cards
         set qty = greatest(0, qty - ceil(r.quantity)::int), updated_at = now()
       where member_id = r.member_id and kind = item.card_kind;
    end if;
  end if;

  return jsonb_build_object(
    'redemption_id', r.id, 'status', p_decision,
    'balance', (select points_balance from app.members where id = r.member_id));
end $$;


-- ---- 四、播种：现金也免审批 ---------------------------------------------------
create or replace function app.seed_reward_items(p_family_id uuid)
returns void
language plpgsql security definer set search_path = app, public as $$
begin
  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and item_kind = 'cash') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  rate_points, unit_label, min_quantity, step_quantity,
                                  requires_approval, item_kind, sort_order)
    values (p_family_id, '现金', '💰', '攒够了换零花钱', 'rate', 10, '元', 1, 1,
            false, 'cash', 0);
  end if;

  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and card_kind = 'retro_signin') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  price_points, min_quantity, step_quantity,
                                  requires_approval, item_kind, card_kind, sort_order)
    values (p_family_id, '补签卡', '🎫', '补一天忘记签到的日子', 'fixed', 30, 1, 1,
            false, 'card', 'retro_signin', 1);
  end if;

  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and card_kind = 'retro_active') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  price_points, min_quantity, step_quantity,
                                  requires_approval, item_kind, card_kind, sort_order)
    values (p_family_id, '补活跃卡', '⚡', '补一天没完成任务的日子', 'fixed', 60, 1, 1,
            false, 'card', 'retro_active', 2);
  end if;

  if not exists (select 1 from app.reward_items
                  where family_id = p_family_id and card_kind = 'retro_fullstar') then
    insert into app.reward_items (family_id, name, emoji, description, pricing_mode,
                                  price_points, min_quantity, step_quantity,
                                  requires_approval, item_kind, card_kind, sort_order)
    values (p_family_id, '补满星卡', '🌟', '补一天没全部完成的日子', 'fixed', 120, 1, 1,
            false, 'card', 'retro_fullstar', 3);
  end if;
end $$;
