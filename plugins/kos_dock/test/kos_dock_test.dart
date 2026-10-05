// KosDockPlugin 契约测试（TASK-00 骨架）。
//
// 覆盖：
// - id / layer 契约；
// - place()：每输出非 null（不做 isMainOutput 门控）、bounds 贴底边、
//   厚度 = dockHeight + edgeMargin + workspaceMargin、不占桌面；
// - 锁屏/壁纸选择器 → visible:false；全屏隐藏（compositor 层级语义），
//   除 overview 打开或 desktopVisible；
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
  bool desktopVisible = true,
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
  desktopVisible: desktopVisible,
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
      // 方案 C：厚度由 DockMetrics 反解，不再是常量。1920 宽基准配置下
      // iconSize=floor(60/1.4)=42 → dockHeight=round(42*1.4)=59，
      // edgeMargin=max(4,round(59*0.12))=7 → stripThickness=59+7×2=73。
      final expectedThickness = DockMetrics.fromWidth(1920).stripThickness;
      expect(expectedThickness, 73.0);
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

    test('place：fullscreen 隐藏 dock，除非 overview 或 desktopVisible', () {
      const surface = KosDockPlugin();
      // compositor 层级语义：KOS dock 在 WlrLayer.Top 被全屏窗口盖住（恒可见
      // 模式无显隐动画，DockAutoHideController.qml:50,254）；Denial 由本
      // surface 按 environment.fullscreen 降 visible。
      expect(
        surface
            .place(
              _env(fullscreen: true, overview: false, desktopVisible: false),
            )!
            .visible,
        isFalse,
      );
      // overview 打开 / desktopVisible 时仍显示（KOS overview 里 dock 可用）。
      expect(
        surface.place(_env(fullscreen: true, overview: true))!.visible,
        isTrue,
      );
      expect(surface.place(_env(fullscreen: true))!.visible, isTrue);
      expect(surface.place(_env(overview: true))!.visible, isTrue);
      // fullscreen:false 时不受 fullscreen 门控影响（仍看 locked /
      // wallpaperSelector，见上一条用例）。
      expect(surface.place(_env())!.visible, isTrue);
      // 全屏下锁屏仍优先隐藏。
      expect(
        surface.place(_env(fullscreen: true, locked: true))!.visible,
        isFalse,
      );
    });

    test('place：fade == custom（opacity 由插件喂 ShellBackdropBlur）', () {
      const surface = KosDockPlugin();
      expect(surface.place(_env())!.fade, ShellSurfaceFade.custom);
    });
  });

  group('KosDockWorkArea（底部工作区预留）', () {
    const workArea = KosDockWorkArea();

    test('reserve：底部预留 = 条带厚度 + maximizePadding', () {
      const settings = ShellLayoutSettings(maximizePadding: 8);
      final reservation = workArea.reserve(settings);
      expect(reservation, isNotNull);
      expect(reservation!.edge, PanelEdge.bottom);
      expect(
        reservation.thickness,
        KosDockPlugin.thickness + settings.maximizePadding,
      );
      expect(reservation.outputNames, isEmpty);
    });

    test('reserve：systemBarSide top / hidden 都仍返回预留（dock 恒可见）', () {
      // 差异于 denial_taskbar `TaskbarWorkArea`（栏隐藏 → null）：CONSTRAINTS
      // §1 不启用 auto-hide，dock 恒在 → 无条件预留（用户 2026-10-04 决定）。
      for (final side in const [PanelEdge.top, PanelEdge.hidden]) {
        final reservation = workArea.reserve(ShellLayoutSettings(systemBarSide: side));
        expect(reservation, isNotNull, reason: 'systemBarSide=$side 仍应预留');
        expect(reservation!.edge, PanelEdge.bottom);
      }
      expect(workArea.reserve(const ShellLayoutSettings()), isNotNull);
    });

    test('reserve：透传 settings.systemBarOutputNames', () {
      final reservation = workArea.reserve(
        const ShellLayoutSettings(
          systemBarOutputNames: ['DP-1', 'HDMI-A-1'],
        ),
      );
      expect(reservation!.outputNames, ['DP-1', 'HDMI-A-1']);
    });

    test('reserve：maximizePadding 非法值（NaN / 负）按 0 计', () {
      expect(
        KosDockWorkArea.reservationThickness(
          const ShellLayoutSettings(maximizePadding: double.nan),
        ),
        KosDockPlugin.thickness,
      );
      expect(
        KosDockWorkArea.reservationThickness(
          const ShellLayoutSettings(maximizePadding: -4),
        ),
        KosDockPlugin.thickness,
      );
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
