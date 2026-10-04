// KosDockPlugin 契约测试（TASK-00 骨架）。
//
// 覆盖：
// - id / layer 契约；
// - place()：每输出非 null（不做 isMainOutput 门控）、bounds 贴底边、
//   厚度 = dockHeight + edgeMargin + workspaceMargin、不占桌面；
// - 锁屏/壁纸选择器 → visible:false；fullscreen/overview 不隐藏；
// - tokens 常量断言（kDockIconSize 等）；
// - fade == ShellSurfaceFade.custom（插件自管 opacity，SDK 不叠整体淡出）。

import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/kos_dock.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';

const Rect _outputRect = Rect.fromLTWH(0, 0, 1920, 1080);

/// 构造 `ShellSurfaceEnvironment`（只覆盖本用例关心的字段）。
ShellSurfaceEnvironment _env({
  bool isMainOutput = true,
  bool locked = false,
  bool wallpaperSelectorVisible = false,
  bool fullscreen = false,
  bool overview = false,
  Rect logicalRect = _outputRect,
}) => ShellSurfaceEnvironment(
  output: DisplayOutput(
    monitorId: 0,
    name: 'test-output',
    logicalRect: logicalRect,
    pixelSize: logicalRect.size,
    scale: 1,
    refreshRate: 60,
  ),
  workArea: logicalRect,
  isMainOutput: isMainOutput,
  workspaceId: 1,
  fullscreen: fullscreen,
  overview: overview,
  desktopVisible: true,
  wallpaperSelectorVisible: wallpaperSelectorVisible,
  locked: locked,
  settings: const ShellSettings(),
  defaultOutputSelected: true,
);

void main() {
  group('KosDockPlugin', () {
    test('id 与 layer 契约', () {
      const surface = KosDockPlugin();
      expect(surface.id, 'kos_dock.dock');
      expect(surface.layer, ShellSurfaceLayer.aboveWindows);
    });

    test('place：每输出非 null（主/非主输出都落 dock）', () {
      const surface = KosDockPlugin();
      expect(surface.place(_env()), isNotNull);
      expect(surface.place(_env(isMainOutput: false)), isNotNull);
    });

    test('place：bounds 贴输出底边，厚度 = dock + 2×浮空边距', () {
      const surface = KosDockPlugin();
      // 60 + max(4,round(60*0.12))×2 = 60 + 7 + 7 = 74。
      const expectedThickness = 74.0;
      expect(KosDockPlugin.thickness, expectedThickness);
      final placement = surface.place(_env())!;
      expect(
        placement.bounds,
        Rect.fromLTWH(0, 1080 - expectedThickness, 1920, expectedThickness),
      );
      expect(placement.bounds.bottom, _outputRect.bottom);
      expect(placement.occupiesDesktop, isFalse);
    });

    test('place：非零原点输出同样贴其底边', () {
      const surface = KosDockPlugin();
      const rect = Rect.fromLTWH(1920, 0, 2560, 1440);
      final placement = surface.place(_env(logicalRect: rect))!;
      expect(placement.bounds.left, rect.left);
      expect(placement.bounds.bottom, rect.bottom);
      expect(placement.bounds.height, KosDockPlugin.thickness);
    });

    test('place：锁屏 / 壁纸选择器 → visible:false', () {
      const surface = KosDockPlugin();
      expect(surface.place(_env(locked: true))!.visible, isFalse);
      expect(
        surface.place(_env(wallpaperSelectorVisible: true))!.visible,
        isFalse,
      );
    });

    test('place：fullscreen / overview 不隐藏', () {
      const surface = KosDockPlugin();
      expect(surface.place(_env(fullscreen: true))!.visible, isTrue);
      expect(surface.place(_env(overview: true))!.visible, isTrue);
    });

    test('place：fade == custom（opacity 由插件喂 ShellBackdropBlur）', () {
      const surface = KosDockPlugin();
      expect(surface.place(_env())!.fade, ShellSurfaceFade.custom);
    });
  });

  group('dock_tokens', () {
    test('kDockIconSize = 60/(1+2*0.20) ≈ 42.857', () {
      expect(kDockIconSize, closeTo(42.857, 0.001));
    });
    test('pill 半径 = height×0.50', () {
      expect(kDockBaseHeight * kDockPillRadiusRatio, 30);
    });
  });
}
