/// chat_page 状态/副作用收敛件（window-slim P1-B/C/D）回归 + 切片 C 自管机制验证。
///
/// 不覆盖业务（业务各域单测承担），只钉住：
/// - [ChatStatusController]：状态带/轨道列表双 Listenable 切分、Run 起止收口、
///   轨道结构性变更、会话切换生命周期重置；
/// - 切片 C 机制：[TrackText.append] / [TrackCall.patch] 写 delta/相位后**仅自身
///   通知**，渲染侧可据此做细粒度局部重绘（不再整页 setState）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/chat_status_controller.dart';
import 'package:goodhub/ui/components/call_card.dart';
import 'package:goodhub/ui/components/dual_track_stream.dart';
import 'package:goodhub/ui/components/status_capsule.dart';

void main() {
  group('ChatStatusController · 状态带（statusListenable）', () {
    test('setPill 仅在语义变更时通知一次', () {
      final c = ChatStatusController();
      var n = 0;
      c.statusListenable.addListener(() => n++);
      c.setPill('connecting', CapsuleTone.l1);
      expect(c.pillLabel, 'connecting');
      expect(c.pillTone, CapsuleTone.l1);
      // 同值再设：幂等，不重复通知（避免无谓重建）。
      c.setPill('connecting', CapsuleTone.l1);
      expect(n, 1);
      c.setPill('thinking', CapsuleTone.l1);
      expect(n, 2);
    });

    test('beginRun/endRun 收口运行态与计时', () {
      final c = ChatStatusController();
      final start = DateTime(2026, 1, 1);
      c.beginRun(startedAt: start);
      expect(c.running, isTrue);
      expect(c.pillLabel, 'connecting');
      expect(c.pillTone, CapsuleTone.l1);
      expect(c.autoFollow, isTrue);
      expect(c.runStartedAt, start);
      // 终态相位由调用处显式 setPill 决定——endRun 不覆盖。
      c.setPill('done', CapsuleTone.idle);
      c.endRun();
      expect(c.running, isFalse);
      expect(c.runStartedAt, isNull);
      expect(c.pillLabel, 'done'); // 保留显式终态
    });

    test('autoFollow 变更经 statusListenable 通知（滚动锚定判定源）', () {
      final c = ChatStatusController();
      var n = 0;
      c.statusListenable.addListener(() => n++);
      c.setAutoFollow(false);
      expect(c.autoFollow, isFalse);
      c.setAutoFollow(false); // 同值不重复
      expect(n, 1);
    });
  });

  group('ChatStatusController · 轨道列表（tracksListenable）', () {
    test('hasMemoryCapsules：记忆胶囊入轨即真（AppBar Bolt 入口显隐判据，B2）', () {
      final c = ChatStatusController();
      expect(c.hasMemoryCapsules, isFalse);
      c.addEntry(TrackMemoryCapsule(key: 'user.name', value: 'Z'));
      expect(c.hasMemoryCapsules, isTrue);
      // 会话切换清轨后即假（新会话无历史胶囊，AppBar 入口随之隐藏）。
      c.clearTracks();
      expect(c.hasMemoryCapsules, isFalse);
    });

    test('addEntry/removeWhere 仅通知 tracksListenable，不牵连 status', () {
      final c = ChatStatusController();
      var tN = 0;
      var sN = 0;
      c.tracksListenable.addListener(() => tN++);
      c.statusListenable.addListener(() => sN++);
      final note = const TrackNote('hi', danger: false);
      c.addEntry(note);
      expect(c.tracks, contains(note));
      expect(tN, 1);
      expect(sN, 0, reason: '增轨不触发状态带重建（B：双 Listenable 切分）');
      c.removeWhere((e) => e is TrackNote);
      expect(c.tracks, isEmpty);
      expect(tN, 2);
    });

    test('resetForSession 清轨道 + 复位状态带到 idle', () {
      final c = ChatStatusController();
      c.beginRun(startedAt: DateTime(2026, 1, 1));
      c.addEntry(const TrackNote('x', danger: false));
      c.resetForSession();
      expect(c.tracks, isEmpty);
      expect(c.running, isFalse);
      expect(c.pillLabel, 'idle');
      expect(c.pillTone, CapsuleTone.idle);
      expect(c.autoFollow, isTrue);
    });
  });

  group('ChatStatusController · 滚动/键盘（D）', () {
    test('attachScroll + pinToBottom 无客户端时不抛（逻辑收口端口）', () {
      final c = ChatStatusController();
      // 未 attach 滚动控制器：pinToBottom 静默 no-op，不抛。
      expect(() => c.pinToBottom(), returnsNormally);
      c.attachScroll(null);
      expect(() => c.onUserScroll(), returnsNormally);
    });
  });

  group('ChatStatusController · 流式文本保序（stream-perf §3 尾帧铁律）', () {
    test('addEntry 先刷空文本缓冲：note 不甩尾帧（真机「任务完成插正文中间」回归）', () {
      final c = ChatStatusController();
      // 复现真机时序：尾帧 delta 还在 40ms 缓冲里，LoopFinished 的 note 已
      // 同步入轨——保序铁律要求 note 之前先把文本刷盘。
      c.appendStreamText('有什么想做的');
      c.appendStreamText('吗？');
      c.addEntry(const TrackNote('✓ 任务完成', danger: false));
      expect(c.tracks.map((e) => e.runtimeType).toList(), [TrackText, TrackNote]);
      expect((c.tracks[0] as TrackText).text.toString(), '有什么想做的吗？');
    });

    test('flush 后续接同一气泡；breakTextStream 后另起', () {
      final c = ChatStatusController();
      c.appendStreamText('你');
      c.flushStreamText();
      c.appendStreamText('好');
      c.flushStreamText();
      expect(c.tracks, hasLength(1), reason: '活动条目续接，不分裂气泡');
      expect((c.tracks.single as TrackText).text.toString(), '你好');
      c.breakTextStream();
      c.appendStreamText('下一段');
      c.flushStreamText();
      expect(c.tracks, hasLength(2));
      expect((c.tracks.last as TrackText).text.toString(), '下一段');
    });

    test('工具卡入轨同样先刷盘：文本尾帧落在卡前（卡不甩文本）', () {
      final c = ChatStatusController();
      c.appendStreamText('先说话');
      c.breakTextStream(); // LoopToolCallStarted 语义：刷盘残余 + 断流
      c.addEntry(TrackCall(tool: 'f'));
      c.appendStreamText('卡后文本');
      c.flushStreamText();
      expect(c.tracks.map((e) => e.runtimeType).toList(),
          [TrackText, TrackCall, TrackText]);
    });

    test('resetForSession 先刷盘再清轨：尾帧不漏进新会话', () {
      final c = ChatStatusController();
      c.appendStreamText('旧会话尾巴');
      c.resetForSession();
      expect(c.tracks, isEmpty);
      c.appendStreamText('新会话');
      c.flushStreamText();
      expect(c.tracks, hasLength(1));
      expect((c.tracks.single as TrackText).text.toString(), '新会话',
          reason: '节拍定时器迟到的 flush 不得把旧尾帧写进新会话');
    });
  });

  group('切片 C · TrackText/TrackCall 自管机制', () {
    test('TrackText.append 写 delta 且仅自身通知（细粒度局部重绘前提）', () {
      final t = TrackText('');
      var n = 0;
      t.addListener(() => n++);
      t.append('hello');
      expect(t.text.toString(), 'hello');
      expect(n, 1, reason: 'append 应仅自身通知一次');
      // 空 delta 不写不通知。
      t.append('');
      expect(n, 1);
    });

    test('TrackCall.patch 更新相位/进度/预览/结果且仅自身通知', () {
      final call = TrackCall(tool: 'list');
      var n = 0;
      call.addListener(() => n++);
      call.patch(progressNote: '1/3');
      expect(call.progressNote, '1/3');
      expect(n, 1);
      call.patch(
        phase: CallCardPhase.success,
        preview: 'r1',
        resultText: 'r1 ⏎ r2',
      );
      expect(call.phase, CallCardPhase.success);
      expect(call.preview, 'r1');
      expect(call.resultText, 'r1 ⏎ r2');
      expect(n, 2);
    });

    test('TrackCall 构造期直接赋值字段不触发通知（历史恢复解码语义不变）', () {
      final call = TrackCall(tool: 'add')
        ..phase = CallCardPhase.cancelled
        ..progressNote = 'p';
      // 无监听者被注册；这里仅验证字段可直接写（解码路径仍可用）。
      expect(call.phase, CallCardPhase.cancelled);
    });
  });
}
