import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/system_metrics_collector.dart';

void main() {
  test('disk samples reuse df output for one minute', () async {
    var now = DateTime(2026, 10, 7);
    var processes = 0;
    final collector = SystemMetricsCollector(
      now: () => now,
      readFile: (_) async => '',
      listDirectory: (_) async => [],
      runProcess: (_, _) async {
        processes++;
        return ProcessResult(
          0,
          0,
          'Filesystem 1B-blocks Used Available Use% Mounted on\n/dev/test 1000 400 600 40% /\n',
          '',
        );
      },
    );
    try {
      for (var i = 0; i < 6; i++) {
        await collector.sample();
        now = now.add(const Duration(seconds: 10));
      }
      expect(processes, 1);
      await collector.sample();
      expect(processes, 2);
      expect(collector.latest!.diskUsedBytes, 400);
      expect(collector.latest!.diskTotalBytes, 1000);
    } finally {
      collector.dispose();
    }
  });
}
