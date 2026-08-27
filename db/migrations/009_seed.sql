-- =============================================================================
-- 009_seed.sql —— 系统内置勋章（family_id is null，所有家庭共享）
-- =============================================================================
insert into app.badges (family_id, code, name, description, emoji, tier, rule, sort_order) values
  (null, 'first_step',    '第一步',     '完成第一个任务',            '👟', 'bronze',
     '{"kind":"total_completions","threshold":1}',    10),
  (null, 'streak_3',      '三日连击',   '连续 3 天完成任务',          '🔥', 'bronze',
     '{"kind":"streak_days","threshold":3}',          20),
  (null, 'streak_7',      '一周不断',   '连续 7 天完成任务',          '🔥', 'silver',
     '{"kind":"streak_days","threshold":7}',          30),
  (null, 'streak_30',     '满月坚持',   '连续 30 天完成任务',         '🏔️', 'gold',
     '{"kind":"streak_days","threshold":30}',         40),
  (null, 'complete_10',   '小有成就',   '累计完成 10 个任务',         '🌱', 'bronze',
     '{"kind":"total_completions","threshold":10}',   50),
  (null, 'complete_50',   '熟能生巧',   '累计完成 50 个任务',         '🌳', 'silver',
     '{"kind":"total_completions","threshold":50}',   60),
  (null, 'complete_200',  '百炼成钢',   '累计完成 200 个任务',        '⛰️', 'gold',
     '{"kind":"total_completions","threshold":200}',  70),
  (null, 'points_500',    '小金库',     '累计获得 500 积分',          '💎', 'silver',
     '{"kind":"total_points","threshold":500}',       80),
  (null, 'points_2000',   '大富翁',     '累计获得 2000 积分',         '👑', 'gold',
     '{"kind":"total_points","threshold":2000}',      90),
  (null, 'early_bird',    '早起鸟',     '在早上 8 点前完成一个任务',   '🌅', 'special',
     '{"kind":"first_task","threshold":1}',          100)
on conflict do nothing;
