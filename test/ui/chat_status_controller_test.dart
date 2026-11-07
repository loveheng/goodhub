/// chat_page 状态/副作用收敛件（window-slim P1-B/C/D）回归 + 切片 C 自管机制验证。
///
/// 不覆盖业务（业务各域单测承担），只钉住：
/// - [ChatStatusController]：状态带/轨道列表双 Listenable 切分、Run 起止收口、
///   轨道结构性变更、会话切换生命周期重置；
/// - 切片 C 机制：[TrackText.append] / [TrackCall.patch] 写 delta/相位后**仅自身
///   通知**，渲染侧可据此做细粒度局部重绘（不再整页 setState）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/notice_category.dart';
import 'package:goodhub/ui/chat_status_controller.dart';
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
      // round-record（2026-10-31）：TrackNote 已不入阅读轨（全额进记录账本），
      // 轨道结构性用例改用工具卡。
      final call = TrackCall(tool: 'x');
      c.addEntry(call);
      expect(c.tracks, contains(call));
      expect(tN, 1);
      expect(sN, 0, reason: '增轨不触发状态带重建（B：双 Listenable 切分）');
      c.removeWhere((e) => e is TrackCall);
      expect(c.tracks, isEmpty);
      expect(tN, 2);
    });

    test('resetForSession 清轨道 + 复位状态带到 idle', () {
      final c = ChatStatusController();
      c.beginRun(startedAt: DateTime(2026, 1, 1));
      c.addEntry(TrackCall(tool: 'x'));
      c.addEntry(const TrackNote('通告', danger: false));
      c.resetForSession();
      expect(c.tracks, isEmpty);
      expect(c.running, isFalse);
      expect(c.pillLabel, 'idle');
      expect(c.pillTone, CapsuleTone.idle);
      expect(c.autoFollow, isTrue);
    });
  });

  group('ChatStatusController · 会话级通告去重（P0-3 降噪，2026-10-22）', () {
    test('claimSessionNotice：同一键只放行一次，不同键各自独立', () {
      final c = ChatStatusController();
      expect(c.claimSessionNotice('unmounted-services:2'), isTrue,
          reason: '首次申领=可通告');
      expect(c.claimSessionNotice('unmounted-services:2'), isFalse,
          reason: '重复申领=本会话已说过，调用方应跳过');
      // 键随内容变（卸载数变化 = 配置真的变了）→ 仍会再告一次。
      expect(c.claimSessionNotice('unmounted-services:3'), isTrue);
      expect(c.claimSessionNotice('skill-skip:bad.yml'), isTrue);
    });

    test('resetForSession 清空通告记账（新会话重告，回历史亦不串账）', () {
      final c = ChatStatusController();
      c.claimSessionNotice('unmounted-services:2');
      expect(c.claimSessionNotice('unmounted-services:2'), isFalse);
      c.resetForSession();
      expect(c.claimSessionNotice('unmounted-services:2'), isTrue,
          reason: '切会话即焚：新会话首轮需要重新告知配置态');
    });
  });

  group('ChatStatusController · 离底未读计数（P1-10，2026-10-22）', () {
    test('脱离跟随期间入轨累加；回到跟随清零（浮钮据此判断「有没有新内容」）',
        () {
      final c = ChatStatusController();
      expect(c.missedSinceDetach, 0);
      // 跟随态入轨不计（用户正看着最新处）。
      c.addEntry(TrackCall(tool: 'follow'));
      expect(c.missedSinceDetach, 0);

      c.setAutoFollow(false); // 用户上翻看历史
      c.addEntry(TrackCall(tool: 'a'));
      c.addEntry(TrackCall(tool: 'b'));
      expect(c.missedSinceDetach, 2);

      // 点「回到最新」/ 滚回底部：恢复跟随即清零（语义站位同一件事）。
      c.setAutoFollow(true);
      expect(c.missedSinceDetach, 0);
      c.addEntry(TrackCall(tool: 'c'));
      expect(c.missedSinceDetach, 0);
    });

    test('会话重置清零未读计数（新会话不继承旧会话的未读）', () {
      final c = ChatStatusController();
      c.setAutoFollow(false);
      c.addEntry(TrackCall(tool: 'x'));
      expect(c.missedSinceDetach, 1);
      c.resetForSession();
      expect(c.missedSinceDetach, 0);
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
    test('round-record：通告到达先刷文本缓冲（尾帧不丢 + 不占阅读轨）', () {
      final c = ChatStatusController();
      // 复现真机时序：尾帧 delta 还在 40ms 缓冲里，通告已同步到达——保序铁律
      // 要求先落文本，且 2026-10-31 起通告本体不再占轨（只进记录账本）。
      c.appendStreamText('有什么想做的', run: const ChatRunId(1));
      c.appendStreamText('吗？', run: const ChatRunId(1));
      // kTaskDoneNote 现归过程类：不进阅读轨、不进账本（仅瞬态 pill）。
      c.addEntry(const TrackNote(kTaskDoneNote, danger: false, category: TrackNoticeCategory.process));
      expect(c.tracks.map((e) => e.runtimeType).toList(), [TrackText]);
      expect((c.tracks.single as TrackText).text.toString(), '有什么想做的吗？');
      expect(c.sessionNotices, isEmpty,
          reason: '过程类通告不收纳（瞬态 pill），验证尾帧保序与零占轨即可');
    });

    test('flush 后续接同一气泡；块级条目入轨后另起', () {
      final c = ChatStatusController();
      c.appendStreamText('你', run: const ChatRunId(1));
      c.flushStreamText();
      c.appendStreamText('好', run: const ChatRunId(1));
      c.flushStreamText();
      expect(c.tracks, hasLength(1), reason: '活动条目续接，不分裂气泡');
      expect((c.tracks.single as TrackText).text.toString(), '你好');
      c.addEntry(TrackCall(tool: 'x')); // 块级条目入轨 = 活动文本段关闭
      c.appendStreamText('下一段', run: const ChatRunId(1));
      c.flushStreamText();
      expect(c.tracks, hasLength(3));
      expect((c.tracks.last as TrackText).text.toString(), '下一段');
    });

    test('工具卡入轨同样先刷盘：文本尾帧落在卡前（卡不甩文本）', () {
      final c = ChatStatusController();
      c.appendStreamText('先说话', run: const ChatRunId(1));
      c.addEntry(TrackCall(tool: 'f')); // 入轨即刷盘 + 关段（页面层零纪律）
      c.appendStreamText('卡后文本', run: const ChatRunId(1));
      c.flushStreamText();
      expect(c.tracks.map((e) => e.runtimeType).toList(),
          [TrackText, TrackCall, TrackText]);
    });

    test('resetForSession 先刷盘再清轨：尾帧不漏进新会话', () {
      final c = ChatStatusController();
      c.appendStreamText('旧会话尾巴', run: const ChatRunId(1));
      c.resetForSession();
      expect(c.tracks, isEmpty);
      c.appendStreamText('新会话', run: const ChatRunId(2));
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

  group('A07/A08（review-fix-2026-10）', () {
    test('A07：beginRun 清离底未读计数（跨轮残留即红）', () {
      final c = ChatStatusController();
      c.setAutoFollow(false);
      c.addEntry(TrackCall(tool: '旧轮未读'));
      expect(c.missedSinceDetach, 1);
      c.beginRun(startedAt: DateTime(2026));
      expect(c.missedSinceDetach, 0,
          reason: 'A07：beginRun 直写 autoFollow 须与 setAutoFollow 同口径清计数');
      expect(c.autoFollow, isTrue);
    });

    test('A08：addEntries 先刷文本缓冲（保序铁律同 addEntry）', () {
      final c = ChatStatusController();
      c.appendStreamText('缓冲尾帧', run: const ChatRunId(1));
      c.addEntries([TrackCall(tool: '同步卡')]);
      expect(c.tracks.first, isA<TrackText>(),
          reason: 'A08：缓冲先刷出（文本条目在同步卡之前）');
      expect((c.tracks.first as TrackText).text.toString(), contains('缓冲尾帧'));
      expect(c.tracks.last, isA<TrackCall>());
    });
  });

  group('ChatStatusController · 本轮记录（round-record，2026-10-31）', () {
    test('通告不入阅读轨：全额进账本 + 轨道零占位', () {
      final c = ChatStatusController();
      c.addEntry(const TrackNote('告警 A', danger: true));
      c.addEntry(const TrackNote('提示 B', danger: false));
      c.addEntry(TrackCall(tool: 't'));
      expect(c.tracks.map((e) => e.runtimeType).toList(), [TrackCall],
          reason: '对话页一条通告都不留（用户拍板 2026-10-31）');
      // 事实类单槽：仅留最后一份（重复/多份不堆积）。
      expect(c.sessionNotices.map((n) => n.text).toList(), ['提示 B'],
          reason: '事实类单槽仅留最新一份');
      expect(c.noticeCount, 2, reason: '累计次数仍计全');
      expect(c.hasDangerNotice, isTrue);
    });

    test('removeWhere 撤下即出账（临时状态行不留既成事实）', () {
      final c = ChatStatusController();
      c.addEntry(const TrackNote('⏳ 临时状态', danger: false));
      expect(c.noticeCount, 1);
      c.removeWhere((e) => e is TrackNote && e.text.startsWith('⏳'));
      expect(c.sessionNotices, isEmpty, reason: '撤下的通告不该留在记录里');
    });

    test('恢复会话：旧快照事实入账（单槽仅留最后一份）并从阅读轨摘净', () {
      final c = ChatStatusController();
      c.addEntries([
        TrackCall(tool: 't'),
        const TrackNote('旧通告 1', danger: false),
        const TrackNote('旧通告 2', danger: true),
      ]);
      expect(c.tracks.map((e) => e.runtimeType).toList(), [TrackCall],
          reason: '还原口径与在线口径必须一致（历史会话不得退回刷屏）');
      expect(c.sessionNotices.map((n) => n.text).toList(), ['旧通告 2'],
          reason: '事实类单槽：仅留最后一份');
      expect(c.noticeCount, 2, reason: '累计次数仍计全');
    });

    test('会话切换清记录（记录 = 本轮口径，不跨会话累积）', () {
      final c = ChatStatusController();
      c.addEntry(const TrackNote('x', danger: false));
      expect(c.noticeCount, 1);
      c.resetForSession();
      expect(c.sessionNotices, isEmpty);
    });

    test('通告不计离底未读（阅读轨无新增，浮钮不虚报）', () {
      final c = ChatStatusController();
      c.setAutoFollow(false);
      c.addEntry(const TrackNote('通告', danger: false));
      expect(c.missedSinceDetach, 0,
          reason: '通告不入轨 = 没有「下方 N 条没看」这一说');
      c.addEntry(TrackCall(tool: 't'));
      expect(c.missedSinceDetach, 1);
    });
  });

  group('ChatStatusController · 通告三分路由（2026-10-31 后续治理）', () {
    test('事实类进账本单槽：重复文案覆盖式收敛', () {
      final c = ChatStatusController();
      c.addEntry(const TrackNote('✓ 引擎就绪', danger: false, category: TrackNoticeCategory.fact));
      c.addEntry(const TrackNote('✓ 引擎就绪', danger: false, category: TrackNoticeCategory.fact));
      c.addEntry(const TrackNote('✓ 插件挂载', danger: false, category: TrackNoticeCategory.fact));
      expect(c.noticeCount, 3, reason: '累计次数计全');
      expect(c.sessionNotices.map((n) => n.text).toList(), ['✓ 插件挂载'],
          reason: '单槽仅留最后一份，重复文案不堆积');
    });

    test('错误类回对话流内联：不进账本', () {
      final c = ChatStatusController();
      c.addEntry(const TrackNote('⚠ 记忆写入失败', danger: true, category: TrackNoticeCategory.error));
      expect(c.sessionNotices, isEmpty, reason: '错误类不进账本');
      expect(c.tracks.single, isA<TrackNote>(), reason: '错误类内联对话流');
      expect(c.hasDangerNotice, isTrue, reason: '危险错通知告警档');
    });

    test('过程类不收纳：瞬态 pill 由页面层处理，本件零存储', () {
      final c = ChatStatusController();
      c.addEntry(const TrackNote('✓ 任务完成', danger: false, category: TrackNoticeCategory.process));
      expect(c.sessionNotices, isEmpty, reason: '过程类不进账本');
      expect(c.tracks, isEmpty, reason: '过程类不进阅读轨');
      expect(c.noticeCount, 0, reason: '过程类不计数');
    });
  });
}
