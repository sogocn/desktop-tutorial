-- =============================================================================
-- 021：给预置皮肤配上专属背景图
--
-- 图片文件放在 public/skins/<key>.webp（Vite 会原样拷进 dist，Nginx 直接静态托管）。
-- 这里只做一件事：把 photo 路径写进每个皮肤的 theme jsonb。
-- 前端约定：
--   - applyTheme() 会把 photo 渲染成 --skin-photo，作为 body 的一大层背景
--   - 日历页把同一张图当头图（useCurrentSkin() → theme.photo）
--   - 文件缺失也没关系：那一层会被浏览器忽略，自动退化成原来的 pattern
--
-- 用 theme || jsonb_build_object(...) 而不是整体替换，
-- 免得把各家已存在的 northern-其他字段覆盖掉；且可重复执行。
-- =============================================================================

with p(key, photo) as (
  values
    ('default',      '/skins/default.webp'),
    ('eye_care',     '/skins/eye_care.webp'),
    ('pokemon',      '/skins/pokemon.webp'),
    ('line_dog',     '/skins/line_dog.webp'),
    ('hp_hermione',  '/skins/hp_hermione.webp')
)
update app.skins s
   set theme = s.theme || jsonb_build_object('photo', p.photo)
  from p
 where s.key = p.key;
