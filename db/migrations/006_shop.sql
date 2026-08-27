-- =============================================================================
-- 006_shop.sql —— 兑换商城
-- =============================================================================
-- 两种定价模式共存一张表：
--   fixed —— 固定商品，price_points 分换 1 件（"看一集动画 = 30 分"）
--   rate  —— 按量兑换，rate_points 分换 1 个 unit_label（"100 分 = 1 元"）
--
-- "默认只有现金"是通过建家庭时播种一条普通记录实现的，
-- 代码里没有任何 kind === 'cash' 的特判。第一个品类就走通用模型，
-- 可扩展性才是真的；给通用模型开后门只会在加第二个品类时还债。
-- =============================================================================

create table app.reward_items (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app.families(id) on delete cascade,
  name         text not null check (length(btrim(name)) between 1 and 40),
  emoji        text not null default '🎁',
  description  text,

  pricing_mode text not null check (pricing_mode in ('fixed', 'rate')),
  price_points int  check (price_points is null or price_points > 0),
  rate_points  int  check (rate_points is null or rate_points > 0),
  unit_label   text,
  min_quantity numeric not null default 1 check (min_quantity > 0),
  step_quantity numeric not null default 1 check (step_quantity > 0),

  stock        int,                       -- null = 不限量
  requires_approval boolean not null default true,
  active       boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),

  constraint pricing_shape check (
    (pricing_mode = 'fixed' and price_points is not null)
    or (pricing_mode = 'rate' and rate_points is not null and unit_label is not null)
  )
);
create index reward_items_family_idx on app.reward_items (family_id) where active;

create table app.redemptions (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app.families(id) on delete cascade,
  member_id    uuid not null references app.members(id) on delete cascade,
  item_id      uuid not null references app.reward_items(id),
  quantity     numeric not null default 1 check (quantity > 0),
  points_cost  int not null check (points_cost >= 0),
  -- 快照商品名，商品改名/下架后历史记录仍可读
  snap_name    text not null,
  snap_emoji   text not null,
  status       text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected', 'delivered', 'cancelled')),
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   uuid references app.members(id),
  note         text
);
create index redemptions_member_idx on app.redemptions (member_id, requested_at desc);
create index redemptions_family_pending_idx on app.redemptions (family_id) where status = 'pending';
