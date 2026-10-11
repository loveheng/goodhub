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
        ..preview = 'r1',
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
    final note = decoded[3] as TrackNote;
    expect(note.text, '✓ 收尾');
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
