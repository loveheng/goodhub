/// M3-T2 D4 卡死判定单测（fake_async）：双档口径 + sampling 在途顺延。
/// 取值拍板 2026-10-11：有 progress 通道 30s 无帧 / 无通道 120s 总时长兜底。
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/components/stuck_watcher.dart';

StuckWatcher watcher(void Function() onStuck) => StuckWatcher(
      progressStall: const Duration(seconds: 30),
      totalCap: const Duration(seconds: 120),
      onStuck: onStuck,
    );

void main() {
  group('StuckWatcher（D4 双档）', () {
    test('有 progress 通道：每帧重置 30s，超窗 → stuck', () {
      fakeAsync((async) {
        var fired = 0;
        final w = watcher(() => fired++);
        w.start();
        w.onProgressFrame();
        async.elapse(const Duration(seconds: 29));
        expect(fired, 0);
        w.onProgressFrame(); // 重置
        async.elapse(const Duration(seconds: 29));
        expect(fired, 0);
        async.elapse(const Duration(seconds: 1));
        expect(fired, 1, reason: '30s 无 progress 帧 → 疑似卡死');
        w.stop();
      });
    });

    test('无通道：30s 静默不判（交给总时长），120s 兜底触发', () {
      fakeAsync((async) {
        var fired = 0;
        final w = watcher(() => fired++);
        w.start();
        async.elapse(const Duration(seconds: 30));
        expect(fired, 0, reason: '窗口内无任何 progress 帧 → 无通道口径');
        async.elapse(const Duration(seconds: 89));
        expect(fired, 0);
        async.elapse(const Duration(seconds: 1));
        expect(fired, 1, reason: '120s 总时长兜底');
        w.stop();
      });
    });

    test('sampling 在途：两口径均顺延，结束后恢复判定', () {
      fakeAsync((async) {
        var fired = 0;
        final w = watcher(() => fired++);
        w.start();
        w.onProgressFrame();
        w.samplingBegin();
        async.elapse(const Duration(seconds: 30));
        expect(fired, 0, reason: '30s 到点但 sampling 在途 → 顺延');
        async.elapse(const Duration(seconds: 60));
        expect(fired, 0, reason: '顺延窗口内仍在途');
        w.samplingEnd();
        async.elapse(const Duration(seconds: 29));
        expect(fired, 0);
        async.elapse(const Duration(seconds: 1));
        expect(fired, 1, reason: 'sampling 结束后 30s 无帧 → 恢复判定');
        w.stop();
      });
    });

    test('stop 复位：旧计时器全部失效，重启后重新计时', () {
      fakeAsync((async) {
        var fired = 0;
        final w = watcher(() => fired++);
        w.start();
        async.elapse(const Duration(seconds: 100));
        w.stop();
        w.start();
        async.elapse(const Duration(seconds: 119));
        expect(fired, 0, reason: 'stop 复位后旧 totalCap 不再触发');
        async.elapse(const Duration(seconds: 1));
        expect(fired, 1);
        w.stop();
      });
    });

    test('samplingEnd 幂等（多 begin 单 end 不为负）', () {
      fakeAsync((async) {
        var fired = 0;
        final w = watcher(() => fired++);
        w.start();
        w.onProgressFrame();
        w.samplingBegin();
        w.samplingEnd();
        w.samplingEnd();
        async.elapse(const Duration(seconds: 30));
        expect(fired, 1, reason: '计数归零后正常判定');
        w.stop();
      });
    });
  });
}
