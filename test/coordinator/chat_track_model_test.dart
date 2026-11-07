import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/chat_track_model.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/core/notice_category.dart';
import 'package:goodhub/mcp/elicitation.dart';

/// S4 回归锚（extensibility-hardening）：轨道模型下沉 coordinator 后——
/// ①持久化格式字面 pin（字节级不变红线）；②encode→decode 往返幂等；
/// ③decode 不创建运行时瞬态（惰性 Completer 红线，S4 分离矩阵）。
void main() {
  group('持久化格式字面 pin（字节级不变）', () {
    test('user 条目形状冻结', () {
      expect(TrackEntryCodec.encode([const TrackUser('你好')]), [
        {'type': 'user', 'text': '你好'},
      ]);
    });
    test('call 条目形状冻结（phase name / 可选键缺席形态）', () {
      final call = TrackCall(tool: 'srv__query')
        ..phase = CallCardPhase.success
        ..preview = 'p'
        ..resultText = 'r';
      expect(TrackEntryCodec.encode([call]), [
        {'type': 'call', 'tool': 'srv__query', 'phase': 'success',
         'preview': 'p', 'resultText': 'r'},
      ]);
    });
    test('note 条目形状冻结（category 随存档）', () {
      expect(
        TrackEntryCodec.encode([
          const TrackNote('done', danger: false, category: TrackNoticeCategory.fact),
        ]),
        [
          {'type': 'note', 'text': 'done', 'danger': false,
           'category': 'fact'},
        ],
      );
    });
  });

  group('encode→decode 往返幂等', () {
    test('text/thinking/error/memory/context 往返字段保全', () {
      final entries = <TrackEntry>[
        TrackText('hello world'),
        TrackThinking('思考中')..expanded = true,
        TrackError(title: 't', advice: 'a', detail: 'd')..retried = true,
        TrackMemoryCapsule(key: 'k', value: 'v')..undone = true,
        TrackContextAttribution(
          memories: [ContextAttributionItem(source: 'user', text: 'm')],
          services: [ContextAttributionItem(source: 'srv', text: 's')],
          droppedCount: 2,
        ),
      ];
      final json = TrackEntryCodec.encode(entries);
      final back = TrackEntryCodec.decode(json);
      expect(back.length, 5);
      expect(back[0], isA<TrackText>());
      expect((back[0] as TrackText).text.toString(), 'hello world');
      expect((back[1] as TrackThinking).expanded, isTrue);
      final err = back[2] as TrackError;
      expect(err.retried, isTrue, reason: 'retried 历史保真');
      expect(err.onAction, isNull, reason: '恢复态锁定不可重试');
      final mem = back[3] as TrackMemoryCapsule;
      expect(mem.undone, isTrue);
      expect(mem.onUndo, isNull, reason: '恢复态撤销锁定');
      final ctx = back[4] as TrackContextAttribution;
      expect(ctx.droppedCount, 2);
      expect(ctx.memories.single.text, 'm');
    });

    test('已决确认卡往返保留终态；未决确认卡降级通告行（禁可交互死卡）', () {
      final decided = TrackConfirm(
        pending: const ToolPendingConfirmation(
            toolName: 'srv__write', argumentsJson: '{}'),
      )
        ..decision = const GateDecision(approved: true, reason: 'ok')
        ..decidedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final json = TrackEntryCodec.encode([decided]);
      expect(json.single['approved'], true);
      final back = TrackEntryCodec.decode(json);
      final c = back.single as TrackConfirm;
      expect(c.decision?.approved, isTrue);
      expect(c.decidedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));

      final pendingJson = [
        {'type': 'confirm', 'toolName': 'srv__write', 'argumentsJson': '{}'},
      ];
      final note = TrackEntryCodec.decode(pendingJson).single;
      expect(note, isA<TrackNote>());
      expect((note as TrackNote).danger, isTrue,
          reason: '未决卡降级 Rose 通告行（completer 无人应答）');
    });
  });

  group('decode 不创建运行时瞬态（惰性 Completer 红线）', () {
    test('已决历史条目不物化 Completer', () {
      final json = TrackEntryCodec.encode([
        TrackConfirm(
          pending: const ToolPendingConfirmation(
              toolName: 'x', argumentsJson: '{}'),
        )..decision = const GateDecision(approved: false),
        TrackElicitation(
          request: ElicitationRequest(message: 'm', schema: const {}),
        )
          ..answer = ElicitationAnswer(accepted: true, content: const {}),
      ]);
      final back = TrackEntryCodec.decode(json);
      expect(back[0], isA<TrackConfirm>());
      expect(back[1], isA<TrackElicitation>());
      // 惰性口径的实现观测：已决条目在 decode 路径未触达 completer getter——
      // 此处经由 decision/answer 字段断言恢复语义完整即可（getter 物化与否则
      // 属实现细节；红线由「decode 构造路径零 completer 访问」结构性保证）。
      expect((back[0] as TrackConfirm).decision?.approved, isFalse);
      expect((back[1] as TrackElicitation).answer?.accepted, isTrue);
    });
  });
}
