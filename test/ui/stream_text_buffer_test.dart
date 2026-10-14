/// P0 流控层单测（stream-perf §3）：节拍批量合并 / 运行期单定时器 /
/// 尾帧不丢（flush 强制清空）/ dispose 取消定时器。
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/components/stream_text_buffer.dart';

void main() {
  group('StreamTextBuffer（P0 流控）', () {
    test('节拍内多个 delta 合并为一次刷盘', () {
      fakeAsync((async) {
        final flushes = <String>[];
        final buf = StreamTextBuffer(onFlush: flushes.add);
        buf.add('你');
        buf.add('好');
        buf.add('，世界');
        expect(flushes, isEmpty, reason: '节拍未到不刷盘');
        async.elapse(const Duration(milliseconds: 39));
        expect(flushes, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(flushes, ['你好，世界'], reason: '40ms 节拍一次批量刷出');
        buf.dispose();
      });
    });

    test('运行期只保留一个节拍定时器（后续 delta 搭车）', () {
      fakeAsync((async) {
        final flushes = <String>[];
        final buf = StreamTextBuffer(onFlush: flushes.add);
        buf.add('a');
        async.elapse(const Duration(milliseconds: 20));
        buf.add('b'); // 不重启节拍
        async.elapse(const Duration(milliseconds: 19));
        expect(flushes, isEmpty, reason: '节拍自首个 delta 起算，不重置');
        async.elapse(const Duration(milliseconds: 1));
        expect(flushes, ['ab']);
        buf.dispose();
      });
    });

    test('尾帧不丢：流结束 flush 强制清空（未到节拍的残余立即刷出）', () {
      fakeAsync((async) {
        final flushes = <String>[];
        final buf = StreamTextBuffer(onFlush: flushes.add);
        buf.add(' Hel');
        buf.add('lo');
        // 不等到节拍：模拟 Run 在 40ms 内结束
        buf.flush();
        expect(flushes, [' Hello'], reason: 'finally 路径强制刷盘，尾帧不丢');
        buf.dispose();
      });
    });

    test('flush 幂等：无残余时静默；刷后新 delta 重启节拍', () {
      fakeAsync((async) {
        final flushes = <String>[];
        final buf = StreamTextBuffer(onFlush: flushes.add);
        buf.flush(); // 空缓冲
        expect(flushes, isEmpty);
        buf.add('x');
        buf.flush();
        expect(flushes, ['x']);
        buf.add('y');
        async.elapse(const Duration(milliseconds: 40));
        expect(flushes, ['x', 'y'], reason: 'flush 取消旧节拍，新 delta 重启');
        buf.dispose();
      });
    });

    test('dispose 后为终态：不再入池、不再刷盘', () {
      fakeAsync((async) {
        final flushes = <String>[];
        final buf = StreamTextBuffer(onFlush: flushes.add);
        buf.add('gone');
        buf.dispose();
        async.elapse(const Duration(seconds: 1));
        expect(flushes, isEmpty, reason: 'widget 已销毁，定时器取消');
        buf.add('after');
        buf.flush();
        expect(flushes, isEmpty, reason: 'dispose 后 add/flush 均静默 no-op');
      });
    });

    test('hasPending 与空 delta 语义', () {
      final buf = StreamTextBuffer();
      expect(buf.hasPending, isFalse);
      buf.add('');
      expect(buf.hasPending, isFalse, reason: '空 delta 不入池');
      buf.add('t');
      expect(buf.hasPending, isTrue);
      buf.drain();
      expect(buf.hasPending, isFalse);
      buf.dispose();
    });
  });
}
