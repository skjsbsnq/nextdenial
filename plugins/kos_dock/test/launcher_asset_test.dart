// TASK-04：启动器 asset 的「查询键」测试（评审阻塞 1 的回归防线）。
//
// Denial 宿主把 kos_dock 当 path 包依赖，Flutter 给依赖包 asset 注册的
// bundle 键是 `packages/kos_dock/assets/applauncher.svg`。`Image.asset` 不传
// `package:` 时查询的是未加前缀的 `assets/applauncher.svg`，在宿主里永远
// 解析失败 → 稳定落入 `errorBuilder`，NextKde logo 实际没交付。
//
// 本文件断言 widget 交给 `AssetImage` 的键，而不是「有没有渲染出 Image」：
// flutter_tester 自己的 asset bundle 键（本包是 root package）与宿主打包键
// 不同，所以「fallback 是否出现」在单测里不可判；只有 keyName 能证明宿主
// 会查到正确资源。
//
// 去掉 `package: 'kos_dock'` 后 `asset.package`/`asset.keyName` 断言必然失败
// （见 `_wrap` 用例与下面的对照组）。

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/launcher_icon.dart';

/// 只覆盖 [LauncherIcon] 真正触达的成员（`linkCursor`、`toggleLauncher`）；
/// 其余 `ShellServices` 成员由 `noSuchMethod` 兜底（本用例不会走到）。
class _StubShellServices implements ShellServices {
  int launcherToggles = 0;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  void toggleLauncher() => launcherToggles++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('未使用的 ShellServices 成员：${invocation.memberName}');
}

Widget _wrap(_StubShellServices services) => MaterialApp(
  home: ShellTheme(
    data: const ShellThemeData(),
    child: SizedBox(
      // 独立宿主 → DockMetricsScope.fallback 基准槽宽（方案 C）。
      width: DockMetricsScope.fallback.iconSlotSize,
      height: DockMetricsScope.fallback.iconSlotSize,
      child: LauncherIcon(services: services),
    ),
  ),
);

/// 启动器图标内的 `Image`（`errorBuilder` 的 `Icon` 不是 `Image`）。
Image _launcherImage(WidgetTester tester) => tester.widget<Image>(
  find.descendant(of: find.byType(LauncherIcon), matching: find.byType(Image)),
);

void main() {
  group('LauncherIcon asset', () {
    testWidgets('Image 查询包内 asset 键 packages/kos_dock/assets/applauncher.svg', (
      tester,
    ) async {
      final services = _StubShellServices();
      await tester.pumpWidget(_wrap(services));
      await tester.pump();

      final image = _launcherImage(tester);
      final provider = image.image;
      expect(provider, isA<AssetImage>());
      final asset = provider as AssetImage;
      expect(asset.assetName, 'assets/applauncher.svg');
      // 阻塞 1 的核心断言：包作用域。缺 `package:` 时 package == null。
      expect(asset.package, 'kos_dock');
      expect(asset.keyName, 'packages/kos_dock/assets/applauncher.svg');
      // `Icons.apps` 只作为安全回退保留，而非主路径。
      expect(image.errorBuilder, isNotNull);
    });

    testWidgets('tap 仍然 → services.toggleLauncher()', (tester) async {
      final services = _StubShellServices();
      await tester.pumpWidget(_wrap(services));
      await tester.pump();

      await tester.tap(find.byType(LauncherIcon));
      expect(services.launcherToggles, 1);
    });
  });

  group('AssetImage 键对照（说明 package 缺失为何会被 fallback 吞掉）', () {
    test('无 package 的键 ≠ 包内键', () {
      const unprefixed = AssetImage('assets/applauncher.svg');
      const packaged = AssetImage(
        'assets/applauncher.svg',
        package: 'kos_dock',
      );
      expect(unprefixed.keyName, 'assets/applauncher.svg');
      expect(packaged.keyName, 'packages/kos_dock/assets/applauncher.svg');
      expect(unprefixed.keyName, isNot(packaged.keyName));
    });
  });
}
