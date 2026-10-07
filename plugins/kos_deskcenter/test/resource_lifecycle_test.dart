import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/pim/pim_store.dart';
import 'package:kos_deskcenter/src/data/system_metrics_collector.dart';
import 'package:kos_deskcenter/src/widgets/desk_center_view.dart';
import 'package:kos_deskcenter/src/widgets/system_card.dart';

class _DelayedStorage implements PimStorage {
  final restored = Completer<String?>();
  int watches = 0;
  int writes = 0;
  @override
  Future<String?> readString(String path) => restored.future;
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<void> writeStringAtomic(String path, String contents) async {
    writes++;
  }

  @override
  Future<void> ensureDirectory(String path) async {}
  @override
  Stream<void> watch(String path) {
    watches++;
    return const Stream.empty();
  }
}

void main() {
  testWidgets('late PIM load cannot reopen a disposed watcher or timer', (
    tester,
  ) async {
    final storage = _DelayedStorage();
    final store = PimStore(storage: storage);
    final loading = store.load();
    unawaited(store.dispose());
    await tester.pump();
    storage.restored.complete(null);
    await loading;
    await tester.pump();
    expect(storage.watches, 0);
    expect(storage.writes, 0);
  });
  testWidgets('CPU fallback provider is reused across desktop rebuilds', (
    tester,
  ) async {
    final collector = SystemMetricsCollector(
      readFile: (_) async => '',
      listDirectory: (_) async => [],
      runProcess: (_, _) async => ProcessResult(0, 1, '', ''),
    );
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: KosDeskCenterView(metricsCollector: collector),
        ),
      ),
    );
    await tester.pump();
    final provider = tester
        .widget<KosSystemCard>(find.byType(KosSystemCard))
        .cpu;
    final state = tester.state<KosDeskCenterViewState>(
      find.byType(KosDeskCenterView),
    );
    for (var i = 0; i < 10; i++) {
      state.enterEditMode();
      await tester.pump();
      expect(
        tester.widget<KosSystemCard>(find.byType(KosSystemCard)).cpu,
        provider,
      );
      state.leaveEditMode();
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox());
    collector.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
