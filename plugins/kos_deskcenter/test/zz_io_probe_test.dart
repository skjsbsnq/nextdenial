// 临时探针：验证 testWidgets 的 fake-async 区里真实文件 IO 是否可完成。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('file io probe', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('io_probe_');
      final file = File('${dir.path}/a.txt');
      await file.writeAsString('hello');
      final text = await file.readAsString();
      expect(text, 'hello');
      await dir.delete(recursive: true);
    });
  });
}
