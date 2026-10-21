import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/fenced_cloud_engine.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/ui/components/call_card.dart';
import 'package:goodhub/ui/components/dual_track_stream.dart';

/// TrackEntry 序列化往返 + 恢复降级语义（M4-T3b）。
void main() {
  test('text/user/note/call(success) 往返保真', () {
    final text = TrackText('# 标题\n正文');
    final entries = <TrackEntry>[
      const TrackUser('任务指令'),
      text,
      TrackCall(tool: 'list_items')
        ..phase = CallCardPhase.success
        ..preview = 'r1'
        ..description = '读取单个收集条目的完整内容（原文 + 机器态）',
      const TrackNote('✓ 收尾', danger: false),
    ];

    final decoded = TrackEntryCodec.decode(TrackEntryCodec.encode(entries));
    expect(decoded, hasLength(4));
    expect((decoded[0] as TrackUser).text, '任务指令');
    expect((decoded[1] as TrackText).text.toString(), '# 标题\n正文');
    final call = decoded[2] as TrackCall;
    expect(call.tool, 'list_items');
    expect(call.phase, CallCardPhase.success);
    expect(call.preview, 'r1');
    expect(call.description, '读取单个收集条目的完整内容（原文 + 机器态）',
        reason: 'A2：描述全文持久化往返保真（恢复会话人话行不丢）');
    final note = decoded[3] as TrackNote;
    expect(note.text, '✓ 收尾');
  });

  test('思考轨（2026-10-21 M1）往返：正文 + 展开态保真（缺省收起）', () {
    final entries = <TrackEntry>[
      TrackThinking('思维一')..expanded = true,
      TrackThinking('思维二'),
    ];

    final encoded = TrackEntryCodec.encode(entries);
    expect(encoded[0]['type'], 'thinking');
    expect(encoded[0]['text'], '思维一');
    expect(encoded[0]['expanded'], true);

    final decoded = TrackEntryCodec.decode(encoded);
    final t1 = decoded[0] as TrackThinking;
    expect(t1.text.toString(), '思维一');
    expect(t1.expanded, true, reason: '展开态随存档恢复（历史保真）');
    final t2 = decoded[1] as TrackThinking;
    expect(t2.text.toString(), '思维二');
    expect(t2.expanded, false, reason: '缺省 expanded = 收起（默认收起拍板口径）');
  });

  test('记忆胶囊（P2-6）往返：字段保真 + 恢复态不接撤销回调（锁定呈现）', () {
    final capsule = TrackMemoryCapsule(key: 'page_size', value: '20');
    final entries = <TrackEntry>[
      capsule,
      TrackMemoryCapsule(key: 'k2', value: 'v2')..undone = true,
    ];

    final decoded = TrackEntryCodec.decode(TrackEntryCodec.encode(entries));
    final c1 = decoded[0] as TrackMemoryCapsule;
    expect(c1.key, 'page_size');
    expect(c1.value, '20');
    expect(c1.undone, isFalse);
    expect(c1.onUndo, isNull, reason: '恢复历史胶囊不可撤销（锁定同 completer 口径）');
    final c2 = decoded[1] as TrackMemoryCapsule;
    expect(c2.undone, isTrue);
  });

  test('上下文归因条（展示 only）往返：快照保真 + 恢复态不接排除回调', () {
    final entries = <TrackEntry>[
      TrackContextAttribution(
        memories: const [
          ContextAttributionItem(source: 'user', text: '偏好 Dart 强类型'),
          ContextAttributionItem(source: 'srv:goodshare', text: '方案 B（单槽隔离）'),
        ],
        services: const [
          ContextAttributionItem(source: 'goodshare', text: 'goodshare Tier 2'),
        ],
        droppedCount: 2,
      ),
    ];

    final decoded = TrackEntryCodec.decode(TrackEntryCodec.encode(entries));
    final c = decoded.single as TrackContextAttribution;
    expect(c.memories, hasLength(2));
    expect(c.memories[0].source, 'user');
    expect(c.memories[0].text, '偏好 Dart 强类型');
    expect(c.memories[1].source, 'srv:goodshare');
    expect(c.services.single.text, 'goodshare Tier 2');
    expect(c.droppedCount, 2);
    expect(c.onItemExclude, isNull, reason: '历史恢复归因条不接排除回调（锁定同 capsule 口径）');
  });

  test('错误行动卡（P0-2）往返：字段保真 + 恢复态不接重试回调', () {
    final card = TrackError(
      title: '连不上推理服务',
      advice: '检查网络连接与端点地址是否可达，然后重试',
      detail: 'CloudNetworkException: connection reset',
    )..retried = true;

    final decoded = TrackEntryCodec.decode(TrackEntryCodec.encode([card]));
    final e = decoded.single as TrackError;
    expect(e.title, '连不上推理服务');
    expect(e.advice, '检查网络连接与端点地址是否可达，然后重试');
    expect(e.detail, 'CloudNetworkException: connection reset');
    expect(e.retried, isTrue);
    expect(e.onAction, isNull,
        reason: '恢复历史无可重跑的任务（锁定同 capsule 口径）');
  });

  test('引导卡不持久化（P0-1）：编码兜底降级为通告行（瞬态条目）', () {
    final decoded = TrackEntryCodec.decode(TrackEntryCodec.encode([
      const TrackGuide(text: '尚未配置任何 MCP 服务', actionLabel: '去配置'),
    ]));
    final note = decoded.single as TrackNote;
    expect(note.text, '尚未配置任何 MCP 服务');
    expect(note.danger, isFalse);
  });

  test('恢复降级：进行态 call → cancelled +「(会话中断)」（恢复历史无在途工具）', () {
    final decoded = TrackEntryCodec.decode([
      {
        'type': 'call',
        'tool': 'add_item',
        'phase': 'running',
        'progressNote': '执行中…',
        'preview': '',
      },
      {
        'type': 'call',
        'tool': 'x',
        'phase': 'stuck',
        'preview': '',
      },
    ]);
    for (final e in decoded) {
      expect((e as TrackCall).phase, CallCardPhase.cancelled);
      expect(e.preview, '(会话中断)');
    }
  });

  test('恢复降级：未决交互卡 → Rose 通告行（严禁恢复成无人应答的死卡）', () {
    final decoded = TrackEntryCodec.decode([
      {'type': 'confirm', 'toolName': 'add_item', 'argumentsJson': '{}'},
      {'type': 'fence', 'engineName': 'e', 'failureMessage': 'm'},
      {'type': 'unknown-kind'},
    ]);
    expect(decoded, hasLength(3));
    for (final e in decoded) {
      expect(e, isA<TrackNote>(), reason: '未决/未知一律降级为通告');
      expect((e as TrackNote).danger, isTrue);
    }
  });

  test('已决交互卡往返：终态锁定字段保真', () {
    final confirm = TrackConfirm(
      pending: const ToolPendingConfirmation(
          toolName: 'update_memory', argumentsJson: '{"content":"偏好"}'),
    )
      ..decision = const GateDecision(approved: true)
      ..decidedAt = DateTime.fromMillisecondsSinceEpoch(1760155200000);
    final breaker = TrackBreaker.breaker(const BreakerReport(
      toolName: 'add_item',
      consecutiveFailures: 2,
      lastError: 'boom',
      argumentsJson: '{}',
    ))
      ..lockedText = '⟳ 已单步重试'
      ..decidedAt = DateTime.fromMillisecondsSinceEpoch(1760155200001);
    final fence = TrackFence(const PiiMaskBlockInfo(
      engineName: 'cloud',
      failureMessage: '遮蔽失败',
      cause: 'x',
    ))
      ..decision = false
      ..decidedAt = DateTime.fromMillisecondsSinceEpoch(1760155200002);

    final decoded = TrackEntryCodec.decode(
        TrackEntryCodec.encode([confirm, breaker, fence]));

    final confirm2 = decoded[0] as TrackConfirm;
    expect(confirm2.decision!.approved, isTrue);
    expect(confirm2.pending.toolName, 'update_memory');
    expect(confirm2.decidedAt!.millisecondsSinceEpoch, 1760155200000);

    final breaker2 = decoded[1] as TrackBreaker;
    expect(breaker2.report!.toolName, 'add_item');
    expect(breaker2.lockedText, '⟳ 已单步重试');

    final fence2 = decoded[2] as TrackFence;
    expect(fence2.decision, isFalse);
    expect(fence2.info.failureMessage, '遮蔽失败');
  });

  test('breaker 与 wall 序列化类型区分（同一 TrackBreaker 两形态）', () {
    final wall = TrackBreaker.wall(const StepWallReport(turnsUsed: 10, limit: 10))
      ..lockedText = '⊘ 已终止';
    final decoded = TrackEntryCodec.decode(TrackEntryCodec.encode([wall]));
    final restored = decoded.single as TrackBreaker;
    expect(restored.report, isNull);
    expect(restored.wall!.turnsUsed, 10);
    expect(restored.lockedText, '⊘ 已终止');
  });
}
