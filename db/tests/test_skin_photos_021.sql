-- =============================================================================
-- test_skin_photos_021.sql —— 皮肤图配置（021 背景图 + 022 头图横幅）
-- 跑法：npm run db:test（已在 scripts/run-sql-tests.mjs 的 suites 里挂上本文件）
--
-- 022 之后一份皮肤有两张图：
--   theme.photo  = <key>-bg.webp  1:1 方形背景图（body 的一层，被裁切无所谓）
--   theme.banner = <key>.webp     3:1 宽幅头图（<img> 整张渲染，主体不能被裁）
-- =============================================================================

begin;

do $$
declare
  v_keys text[] := array['default', 'eye_care', 'pokemon', 'line_dog', 'hp_hermione'];
  k      text;
  ph     text;
  bn     text;
  v_n    int;
begin
  perform app.seed_skins();

  foreach k in array v_keys loop
    select theme ->> 'photo' into ph from app.skins where key = k;

    -- P1 每个预置皮肤都要有背景图路径
    assert ph is not null, 'P1 ' || k || ' 缺少 theme.photo';

    -- P2 背景图必须是 <key>-bg.webp（022 起头图另立 banner）
    assert ph = '/skins/' || k || '-bg.webp',
      format('P2 %s 的背景图路径不对：%s', k, ph);

    -- P3 头图横幅必须有，且指向 <key>.webp
    select theme ->> 'banner' into bn from app.skins where key = k;
    assert bn = '/skins/' || k || '.webp',
      format('P3 %s 的头图路径不对：%s', k, bn);
  end loop;

  raise notice '✓ P1/P2/P3 五张皮肤的背景图与头图路径均符合约定';

  -- P4 两次合并式更新都不能把别的主题字段弄丢
  select count(*) into v_n
    from app.skins
   where key = any(v_keys)
     and theme ->> 'bg' is not null
     and theme ->> 'primary' is not null
     and theme ? 'pattern';
  assert v_n = 5, 'P4 原有配色字段应保持完整，实际完整的有 ' || v_n || ' 个';
  raise notice '✓ P4 合并式更新未覆盖原有配色/图案字段';
end $$;

rollback;
