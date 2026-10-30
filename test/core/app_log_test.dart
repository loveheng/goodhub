import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/app_log.dart';

void main() {
  setUp(() {
    AppLog.resetForTest();
  });

  group('AppLog 环形缓冲', () {
    test('显式打点按级别入缓冲，line 含时间戳与级别标记', () {
      AppLog.instance.i('hello');
      AppLog.instance.w('[DEGRADE] something degraded');
      AppLog.instance.e('boom');

      final entries = AppLog.instance.entries;
      expect(entries.length, 3);
      expect(entries[0].level, LogLevel.info);
      expect(entries[1].level, LogLevel.warning);
      expect(entries[2].level, LogLevel.error);
      expect(entries[0].line.length, greaterThanOrEqualTo(13));
      expect(entries[0].line.substring(13), 'I hello');
    });

    test('超容量淘汰最旧（FIFO 环形）', () {
      for (var i = 0; i < AppLog.kMaxEntries + 50; i++) {
        AppLog.instance.d('line-$i');
      }
      final entries = AppLog.instance.entries;
      expect(entries.length, AppLog.kMaxEntries);
      expect(entries.first.message, 'line-50');
      expect(entries.last.message, 'line-${AppLog.kMaxEntries + 49}');
    });

    test('clear 清空缓冲', () {
      AppLog.instance.i('x');
      AppLog.instance.clear();
      expect(AppLog.instance.length, 0);
    });

    test('revision 随写入/清空递增', () {
      final before = AppLog.instance.revision.value;
      AppLog.instance.i('a');
      AppLog.instance.i('b');
      expect(AppLog.instance.revision.value, greaterThan(before));
    });

    test('resetForTest 清缓冲并复位 revision', () {
      AppLog.instance.i('x');
      AppLog.resetForTest();
      expect(AppLog.instance.length, 0);
      expect(AppLog.instance.revision.value, 0);
    });
  });
}
