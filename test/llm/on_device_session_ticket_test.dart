import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';
import 'package:goodhub/llm/on_device_session_ticket.dart';

/// 会话票据回归钉（M1 Expand；设计 = docs/design/on-device-lifecycle-single-source.md §2.2）。
///
/// 三条钉子（撤实现即红）：
///  1. 票据解析**失败即 null**——解析不出来不许造一张（造出来就是新的说谎源）；
///  2. `sameEpoch` 只认「同实例 + 同代次」——进程重建（实例标识变）即便代次
///     相同也必须是新会话（这是 epoch 去持久化的全部依据：LMK 强杀后不做
///     磁盘计数，靠实例标识斩断复用）；
///  3. 影子对账命中「主进程 ready 而 `:engine` 非就绪」= 说谎态漂移（2026-10-31
///     真机事故的对账面），且对账**不阻断**调用方。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<Object?, Object?> ticketMap({
    String instanceId = 'inst-a',
    int seq = 7,
    int status = 2, // assetMissing
    String modelId = 'qwen3-5-2b-q4-0',
    String runtime = 'qairt',
    int issuedAtMs = 1234,
  }) =>
      <Object?, Object?>{
        SessionTicket.kInstanceId: instanceId,
        SessionTicket.kSeq: seq,
        SessionTicket.kStatus: status,
        SessionTicket.kModelId: modelId,
        SessionTicket.kRuntime: runtime,
        SessionTicket.kIssuedAtMs: issuedAtMs,
      };

  group('SessionTicket.tryParse', () {
    test('字段完整 → 解析成功且序数还原枚举', () {
      final t = SessionTicket.tryParse(ticketMap());
      expect(t, isNotNull);
      expect(t!.instanceId, 'inst-a');
      expect(t.seq, 7);
      expect(t.status, EngineStatus.assetMissing);
      expect(t.modelId, 'qwen3-5-2b-q4-0');
      expect(t.runtime, 'qairt');
    });

    test('非 Map / 缺实例标识 / 空实例标识 / 非数值代次 → null（禁造票据）', () {
      expect(SessionTicket.tryParse(null), isNull);
      expect(SessionTicket.tryParse('not-a-map'), isNull);
      expect(SessionTicket.tryParse(<Object?, Object?>{'seq': 1, 'status': 0}),
          isNull);
      expect(SessionTicket.tryParse(ticketMap(instanceId: '')), isNull);
      expect(
          SessionTicket.tryParse(ticketMap()
            ..[SessionTicket.kSeq] = 'x'),
          isNull);
    });

    test('序数越界 → unknownNeedReconcile（I2 未知≠终态，禁投毒 unsupportedDevice）', () {
      final t = SessionTicket.tryParse(ticketMap(status: 99));
      expect(t?.status, EngineStatus.unknownNeedReconcile);
    });
  });

  group('sameEpoch', () {
    final a = SessionTicket.tryParse(ticketMap())!;

    test('同实例同代次 → 同一会话', () {
      expect(a.sameEpoch(SessionTicket.tryParse(ticketMap())), isTrue);
    });

    test('代次相同但进程重建（实例标识变）→ 新会话', () {
      final other = SessionTicket.tryParse(ticketMap(instanceId: 'inst-b'));
      expect(a.sameEpoch(other), isFalse);
    });

    test('同实例代次递增 → 新会话；null → 非同会话', () {
      expect(a.sameEpoch(SessionTicket.tryParse(ticketMap(seq: 8))), isFalse);
      expect(a.sameEpoch(null), isFalse);
    });
  });

  group('sessionMirrorDrift', () {
    test('主进程 ready 而 :engine 非就绪 → 说谎态漂移', () {
      final remote = SessionTicket.tryParse(ticketMap(status: 2))!;
      expect(sessionMirrorDrift(remote, OnDeviceLoadState.ready),
          contains('说谎态'));
    });

    test('主进程非 ready 而 :engine 已就绪 → 漏状态漂移', () {
      final remote = SessionTicket.tryParse(ticketMap(status: 0))!;
      expect(sessionMirrorDrift(remote, OnDeviceLoadState.unloaded),
          contains('漏状态'));
    });

    test('两端一致（含 busy）→ 无漂移；票据取不到 → 不算状态漂移', () {
      expect(sessionMirrorDrift(SessionTicket.tryParse(ticketMap(status: 0)),
          OnDeviceLoadState.ready), isNull);
      expect(sessionMirrorDrift(SessionTicket.tryParse(ticketMap(status: 1)),
          OnDeviceLoadState.ready), isNull);
      expect(sessionMirrorDrift(null, OnDeviceLoadState.ready), isNull);
    });
  });

  group('影子对账（binding.reconcileTicket）', () {
    Object? channelReply;
    Exception? channelError;

    setUp(() {
      channelReply = null;
      channelError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
        if (call.method != 'checkSession') return null;
        final err = channelError;
        if (err != null) throw err;
        return channelReply;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
    });

    Future<List<String>> capture(Future<void> Function() body) async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      try {
        await body();
      } finally {
        debugPrint = original;
      }
      return logs;
    }

    test('漂移可见：留痕带挂点与票据，且见证入镜像', () async {
      channelReply = ticketMap(status: 2);
      final binding = OnDeviceEngineBinding();
      final logs = await capture(
          () => binding.reconcileTicket(OnDeviceLoadState.ready, 'post-load'));

      expect(logs.any((l) => l.contains('session-mirror drift @post-load')),
          isTrue);
      expect(binding.sessionMirror.ticket, isNotNull);
      expect(binding.sessionMirror.ticket!.status, EngineStatus.assetMissing);
    });

    test('一致无留痕；通道异常只留痕不抛（Expand 阶段禁阻断）', () async {
      channelReply = ticketMap(status: 0);
      final binding = OnDeviceEngineBinding();
      final okLogs = await capture(
          () => binding.reconcileTicket(OnDeviceLoadState.ready, 'generate'));
      expect(okLogs.any((l) => l.contains('session-mirror drift')), isFalse);

      channelError = PlatformException(code: 'not_bound');
      final errLogs = await capture(
          () => binding.reconcileTicket(OnDeviceLoadState.ready, 'generate'));
      expect(errLogs.any((l) => l.contains('session-mirror reconcile @generate')),
          isTrue);
    });
  });
}
