-- =============================================================================
-- 022：皮肤图拆成「背景图」和「头图横幅」两份
--
-- 起因：头图原来是 1:1 的图配 background-size:cover，而头图容器接近 4:1 的宽条，
-- 结果图片被垂直居中裁切，右下角的角色只剩半个。
--
-- 现在一份皮肤两张图，各司其职：
--   1) 背景图  <key>-bg.webp  （1:1 方形，清淡）
--      → theme.photo，走 body 的一层背景。被 cover 裁切无所谓，越淡越好。
--   2) 头图    <key>.webp     （3:1 宽幅横幅，主体靠右、四周留安全边距）
--      → theme.banner，日历页 / 今天页用 <img> 按原比例整张渲染，
--        不再用 background-size:cover，所以主体完整可见。
--
-- 仍是合并式更新（theme || ...），不覆盖其它主题字段，可重复执行。
-- =============================================================================

with p(key, photo, banner) as (
  values
    ('default',      '/skins/default-bg.webp',      '/skins/default.webp'),
    ('eye_care',     '/skins/eye_care-bg.webp',     '/skins/eye_care.webp'),
    ('pokemon',      '/skins/pokemon-bg.webp',      '/skins/pokemon.webp'),
    ('line_dog',     '/skins/line_dog-bg.webp',     '/skins/line_dog.webp'),
    ('hp_hermione',  '/skins/hp_hermione-bg.webp',  '/skins/hp_hermione.webp')
)
update app.skins s
   set theme = s.theme || jsonb_build_object('photo', p.photo, 'banner', p.banner)
  from p
 where s.key = p.key;
