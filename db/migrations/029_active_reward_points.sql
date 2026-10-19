-- =============================================================================
-- 029_active_reward_points.sql —— 提高「连续活跃」挑战的成功奖励分
-- =============================================================================
-- 用户要求：活跃挑战的成功积分数应在「签到挑战」与「满星挑战」之间。
--   * 签到：signin_21 奖励 33 / signin_45 奖励 100
--   * 满星：fullstar_21 奖励 100 / fullstar_45 奖励 300
--   * 活跃（旧）：active_21 奖励 33 / active_45 奖励 100  ← 与签到同档，偏低
--   * 活跃（新）：active_21 奖励 60 / active_45 奖励 200  ← 落在两者之间
-- 入场费不变（active_21 入场 7 / active_45 入场 10）。
-- 仅重建 _challenge_spec 函数即可，判定 / 状态机 / 补救逻辑全部复用，无需改其他。
-- 已成功发放的旧挑战（33/100）为历史值，不影响；新开挑战按新值发奖。
-- =============================================================================


-- ###########################################################################
-- 重建 _challenge_spec（仅 active_21 / active_45 的 reward_points 上调）
-- ###########################################################################
create or replace function app._challenge_spec(p_kind text)
returns jsonb
language plpgsql immutable security definer set search_path = app, public as $$
begin
  if p_kind = 'fullstar_21' then
    return jsonb_build_object(
      'kind', 'fullstar_21', 'title', '21天满星挑战',
      'window_days', 21, 'required_fullstar', 20, 'allowed_miss', 1,
      'entry_fee', 20, 'reward_points', 100,
      'reward_card', 'retro_signin', 'reward_card_label', '补签卡');
  elsif p_kind = 'fullstar_45' then
    return jsonb_build_object(
      'kind', 'fullstar_45', 'title', '45天满星挑战',
      'window_days', 45, 'required_fullstar', 42, 'allowed_miss', 3,
      'entry_fee', 30, 'reward_points', 300,
      'reward_card', 'retro_fullstar', 'reward_card_label', '补满星卡');
  elsif p_kind = 'signin_21' then
    return jsonb_build_object(
      'kind', 'signin_21', 'title', '21天签到挑战',
      'window_days', 21, 'required_fullstar', 20, 'allowed_miss', 1,
      'entry_fee', 7, 'reward_points', 33,
      'reward_card', 'retro_signin', 'reward_card_label', '补签卡');
  elsif p_kind = 'signin_45' then
    return jsonb_build_object(
      'kind', 'signin_45', 'title', '45天签到挑战',
      'window_days', 45, 'required_fullstar', 42, 'allowed_miss', 3,
      'entry_fee', 10, 'reward_points', 100,
      'reward_card', 'retro_fullstar', 'reward_card_label', '补满星卡');
  elsif p_kind = 'active_21' then
    return jsonb_build_object(
      'kind', 'active_21', 'title', '21天活跃挑战',
      'window_days', 21, 'required_fullstar', 20, 'allowed_miss', 1,
      'entry_fee', 7, 'reward_points', 60,
      'reward_card', 'retro_active', 'reward_card_label', '补活跃卡');
  elsif p_kind = 'active_45' then
    return jsonb_build_object(
      'kind', 'active_45', 'title', '45天活跃挑战',
      'window_days', 45, 'required_fullstar', 42, 'allowed_miss', 3,
      'entry_fee', 10, 'reward_points', 200,
      'reward_card', 'retro_active', 'reward_card_label', '补活跃卡');
  end if;
  raise exception 'BAD_CHALLENGE_KIND: % 不是有效的挑战类型', p_kind;
end $$;


grant execute on all functions in schema app to authenticated;
grant execute on all functions in schema app to service_role;
