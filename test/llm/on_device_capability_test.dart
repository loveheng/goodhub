// 端侧能力原语回归钉（task-capability W3 · S16）。
//
// 红线：complete = 供给面唯一入口（禁第二原语）；无状态 / 语义幂等（K20：
// 单轮自足、不驱动工具往返、无外部状态累积）；不触发装载（懒加载边界）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// 供给面假件：仅实现原语实际触达的面（loadState + generate），其余成员
/// noSuchMethod 收敛（测试假件不承载真实引擎语义）。
class _FakeSupplyFace implements OnDeviceSupplyFace {
  _FakeSupplyFace({this.script = const [], this.state});

  /// 每次 generate 消费一个脚本项；耗尽后抛 StateError（防测试脚本缺口静默）。
  final List<Stream<EngineChunk>> script;
  int _calls = 0;

  /// 当前装载态（S18 可用性/显式装载钉：可注入切换；enable 内置就绪故可变）。
  OnDeviceLoadState? state;

  /// enable 实际调用次数（红线钉：complete 不触发装载；loadExplicit 主动
  /// 发起才 +1）。
  int enableCalls = 0;

  /// generate 实际调用次数（无状态钉：连续调用独立发起）。
  int get generateCalls => _calls;

  @override
  ValueListenable<OnDeviceLoadState> get loadState =>
      ValueNotifier(state ?? OnDeviceLoadState.ready);

  @override
  Future<EngineStatus> enable(
      {OnDeviceModelOption? model, String? backendHint}) async {
    enableCalls++;
    state = OnDeviceLoadState.ready;
    return EngineStatus.ready;
  }

  @override
  Stream<EngineChunk> generate({
    required String requestId,
    required String prompt,
    GenerationConfig config = const GenerationConfig(),
  }) {
    if (_calls >= script.length) throw StateError('脚本耗尽');
    return script[_calls++];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('S16 无状态 / 语义幂等（K20）', () {
    test('连续两次调用结果独立（无会话状态泄漏，prompt 独立构造）', () async {
      final face = _FakeSupplyFace(script: [
        Stream.value(const EngineChunk(deltaText: '第一次产出')),
        Stream.value(const EngineChunk(deltaText: '第二次产出')),
      ]);
      final svc = AidlOnDeviceCapabilityService(face);
      final a = await svc.complete(instruction: 'i', input: 'a');
      final b = await svc.complete(instruction: 'i', input: 'a');
      expect(a, '第一次产出');
      expect(b, '第二次产出', reason: '同参重调 = 重新推理，不残留前轮状态');
      expect(face.generateCalls, 2);
    });

    test('单轮边界：产出即完整终值，原语不追加任何轮次后缀', () async {
      final face = _FakeSupplyFace(script: [
        Stream.value(const EngineChunk(deltaText: '结果')),
      ]);
      final svc = AidlOnDeviceCapabilityService(face);
      final out = await svc.complete(instruction: 'i', input: 'x');
      expect(out, '结果');
    });
  });

  group('S16 降级与熔断双轨（既有语义回归）', () {
    test('空产出 → failFast 抛 OnDevicePrimitiveException（禁静默空串）',
        () async {
      final face = _FakeSupplyFace(script: [
        Stream.value(const EngineChunk(deltaText: '   ')),
      ]);
      final svc = AidlOnDeviceCapabilityService(face);
      await expectLater(
        svc.complete(instruction: 'i', input: 'x'),
        throwsA(isA<OnDevicePrimitiveException>()),
      );
    });
  });

  group('S18 可用性查询与显式装载', () {
    test('availability 三态映射：ready/cold/unavailable（只读零副作用）',
        () async {
      final readyFace = _FakeSupplyFace(state: OnDeviceLoadState.ready);
      expect(await AidlOnDeviceCapabilityService(readyFace).availability(),
          OnDeviceCapabilityAvailability.ready);
      final loadingFace =
          _FakeSupplyFace(state: OnDeviceLoadState.loading);
      expect(await AidlOnDeviceCapabilityService(loadingFace).availability(),
          OnDeviceCapabilityAvailability.cold,
          reason: '装载中 = 冷态（非终态失败）');
      final failedFace = _FakeSupplyFace(state: OnDeviceLoadState.failed);
      expect(await AidlOnDeviceCapabilityService(failedFace).availability(),
          OnDeviceCapabilityAvailability.unavailable);
    });

    test('loadExplicit 幂等：ready 时 no-op（enable 零调用）', () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.ready);
      final svc = AidlOnDeviceCapabilityService(face);
      await svc.loadExplicit();
      await svc.loadExplicit();
      expect(face.enableCalls, 0, reason: '已 ready = 幂等 no-op');
    });

    test('loadExplicit 冷态 → 显式触发装载（enable 调用 + 就绪后可产出）',
        () async {
      final face = _FakeSupplyFace(
        state: OnDeviceLoadState.unloaded,
        script: [Stream.value(const EngineChunk(deltaText: 'ok'))],
      );
      final svc = AidlOnDeviceCapabilityService(face);
      await svc.loadExplicit();
      expect(face.enableCalls, 1);
      // 显式装载后原语可用（假件 loadState 已被 enable 置 ready）。
      expect(
        await svc.complete(instruction: 'i', input: 'x'),
        'ok',
      );
    });

    test('红线：complete 不触发装载（冷态下 enable 零调用，按降级策略收口）',
        () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.unloaded);
      final svc = AidlOnDeviceCapabilityService(face);
      await expectLater(
        svc.complete(instruction: 'i', input: 'x'),
        throwsA(isA<OnDevicePrimitiveException>()),
      );
      expect(face.enableCalls, 0,
          reason: '懒加载边界：原语调用绝不作为装载触发源（S18/S16 红线）');
    });
  });

  group('S19 降级矩阵与结构化保证回归', () {
    test('degradeToCloud + 云兜底注入 → 走云端完成（未就绪形态）', () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.unloaded);
      final svc = AidlOnDeviceCapabilityService(
        face,
        cloudFallback: (i, input, cfg) async => '云端兜底产出',
      );
      expect(
        await svc.complete(
            instruction: 'i',
            input: 'x',
            fallback: PrimitiveFallbackPolicy.degradeToCloud),
        '云端兜底产出',
      );
    });

    test('degradeToCloud 未注入云兜底 → 落 truncate 地板（原文 ≤8192 原样）',
        () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.unloaded);
      final svc = AidlOnDeviceCapabilityService(face);
      expect(
        await svc.complete(
            instruction: 'i',
            input: '原文内容',
            fallback: PrimitiveFallbackPolicy.degradeToCloud),
        '原文内容',
      );
    });

    test('degradeToTruncate 超长折叠：Head 80% + 标记 + Tail 20%', () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.unloaded);
      final svc = AidlOnDeviceCapabilityService(face);
      final long = 'A' * 9000 + 'B' * 1000;
      final out = await svc.complete(
          instruction: 'i',
          input: long,
          fallback: PrimitiveFallbackPolicy.degradeToTruncate);
      expect(out.length, 8192 + '\n[……已按端侧原语地板折叠……]\n'.length);
      expect(out.startsWith('A'), isTrue);
      expect(out.endsWith('B'), isTrue);
      expect(out.contains('已按端侧原语地板折叠'), isTrue);
    });

    test('降级窗口：连续 3 次失败入冷却，窗口内不再压引擎（受理段即降级）',
        () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.unloaded);
      final svc = AidlOnDeviceCapabilityService(face);
      for (var i = 0; i < 3; i++) {
        try {
          await svc.complete(instruction: 'i', input: 'x');
        } on OnDevicePrimitiveException {
          // failFast：预期失败路径（计数累计）。
        }
      }
      // 第 4 次：熔断窗口内——受理段直接抛，不触碰引擎流（零新增受理）。
      await expectLater(
        svc.complete(instruction: 'i', input: 'x'),
        throwsA(isA<OnDevicePrimitiveException>()),
      );
    });

    test('失败计数复位：成功后计数归零（失败重新累计，不跨成功延续）',
        () async {
      final face = _FakeSupplyFace(
        script: <Stream<EngineChunk>>[], // 显式可变列表（复位后注入成功产出）
        state: OnDeviceLoadState.unloaded,
      );
      final svc = AidlOnDeviceCapabilityService(face);
      // 两次失败（计数=2，未达阈值 3）。
      for (var i = 0; i < 2; i++) {
        await expectLater(
          svc.complete(instruction: 'i', input: 'x'),
          throwsA(isA<OnDevicePrimitiveException>()),
        );
      }
      // 成功一次（挂载就绪 + 注入产出）→ 计数复位。
      face.state = OnDeviceLoadState.ready;
      face.script.add(Stream.value(const EngineChunk(deltaText: 'ok')));
      expect(await svc.complete(instruction: 'i', input: 'x'), 'ok');
      // 复位后重新累计：3 次失败仍是受理段原因（未就绪）——若未复位，
      // 第 3 次累计已达阈值入冷却窗，消息将变为「降级窗口内」。
      face.state = OnDeviceLoadState.unloaded;
      for (var i = 0; i < 3; i++) {
        await expectLater(
          svc.complete(instruction: 'i', input: 'x'),
          throwsA(predicate((e) =>
              e is OnDevicePrimitiveException &&
              e.message.contains('未就绪'))),
          reason: '复位生效：失败重新累计，第 3 次未入冷却窗',
        );
      }
      // 第 4 次失败（复位后累计满 3）→ 入冷却窗，消息变为窗口原因。
      await expectLater(
        svc.complete(instruction: 'i', input: 'x'),
        throwsA(predicate((e) =>
            e is OnDevicePrimitiveException &&
            e.message.contains('降级窗口内'))),
      );
    });
  });
  group('S18c 流式原语与挂起态', () {
    test('聚合等价：complete 结果 = completeStream 产出拼接（全量降为包装）',
        () async {
      // 单次受理的流可含多块（流内拼接 = 消费方聚合口径）。
      final face = _FakeSupplyFace(script: [
        Stream.fromIterable([
          const EngineChunk(deltaText: '结'),
          const EngineChunk(deltaText: '果'),
        ]),
      ]);
      final svc = AidlOnDeviceCapabilityService(face);
      // 流式直拼（流多块顺序拼接）。
      final streamed = StringBuffer();
      await for (final c in svc.completeStream(
          instruction: 'i', input: 'x')) {
        streamed.write(c.deltaText);
      }
      expect(streamed.toString(), '结果');
      // complete 聚合包装与流式拼接等价（同脚本再跑一次 complete）。
      final face2 = _FakeSupplyFace(script: [
        Stream.fromIterable([
          const EngineChunk(deltaText: '结'),
          const EngineChunk(deltaText: '果'),
        ]),
      ]);
      expect(
        await AidlOnDeviceCapabilityService(face2)
            .complete(instruction: 'i', input: 'x'),
        streamed.toString(),
        reason: '全量完成 = 流式聚合包装（S18c 降级等价）',
      );
    });

    test('受理段收口：未就绪 → completeStream 直接抛（流式消费方自行降级）',
        () async {
      final face = _FakeSupplyFace(state: OnDeviceLoadState.unloaded);
      final svc = AidlOnDeviceCapabilityService(face);
      await expectLater(
        svc.completeStream(instruction: 'i', input: 'x').toList(),
        throwsA(isA<OnDevicePrimitiveException>()),
      );
      expect(face.enableCalls, 0, reason: '受理段不触发装载（懒加载边界）');
    });

    test('取消随退订下沉：订阅取消即让槽（引擎层 onCancel 透传 cancel）',
        () async {
      // 假件流用 StreamController(onCancel:) 承载——与引擎层同构，
      // 退订 → onCancel 触发（真实 :engine 在此透传 cancel(requestId)）。
      var cancelled = false;
      final ctrl = StreamController<EngineChunk>(
        onCancel: () => cancelled = true,
      );
      ctrl.add(const EngineChunk(deltaText: 'a'));
      final face = _FakeSupplyFace(script: [ctrl.stream]);
      final svc = AidlOnDeviceCapabilityService(face);
      final sub = svc.completeStream(instruction: 'i', input: 'x').listen(null);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue,
          reason: '退订取消下沉到流层——算力立即让槽，无孤儿任务空跑');
      await ctrl.close();
    });

    test('挂起态契约：PrimitiveSuspension 承载已算完产物 + 继续签名重入锚',
        () {
      // K21 三红线：已算完产物（非半截生成态）/ 宿主不驻留等待实例（签名
      // 即重入锚）/ 挂起不占执行槽（流收口后构造，禁算力占用期内等确认）。
      const s = PrimitiveSuspension(
        intent: '发送邮件',
        params: {'to': 'a@b.c', 'body': r'$ref:x:1'},
        resumeToken: 'rsm_abc123',
        payload: '邮件草稿已生成',
      );
      expect(s.resumeToken, 'rsm_abc123');
      expect(s.params['body'], r'$ref:x:1',
          reason: '超长载荷用既有 \$ref 引用句柄承载');
      expect(s.payload, isNotNull, reason: '挂起载荷 = 已算完的产物');
    });
  });

  group('S18b 前缀复用句柄（契约留位，K12）', () {
    test('acquire 签发：scope 透传 + 纪元单调递增（纯值零副作用）', () {
      final svc = AidlOnDeviceCapabilityService(_FakeSupplyFace());
      final h1 = svc.acquirePrefixReuseHandle(scope: 'summarize');
      final h2 = svc.acquirePrefixReuseHandle(scope: 'summarize');
      final h3 = svc.acquirePrefixReuseHandle(scope: 'classify');
      expect(h1.scope, 'summarize');
      expect(h2.scope, 'summarize');
      expect(h2.epoch, greaterThan(h1.epoch),
          reason: '同 scope 重新签发 = 新纪元（旧句柄可辨）');
      expect(h3.scope, 'classify');
      expect(h3.epoch, greaterThan(h2.epoch), reason: '纪元进程内单调');
    });

    test('句柄值语义：==/hashCode 按 scope+epoch（调用方可显式持有与比对）', () {
      const a = PrefixReuseHandle(scope: 's', epoch: 1);
      const b = PrefixReuseHandle(scope: 's', epoch: 1);
      const c = PrefixReuseHandle(scope: 's', epoch: 2);
      const d = PrefixReuseHandle(scope: 't', epoch: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(d));
    });

    test('invalidate 幂等 no-op：不抛、可重复调用（契约壳语义）', () async {
      final svc = AidlOnDeviceCapabilityService(_FakeSupplyFace());
      final h = svc.acquirePrefixReuseHandle(scope: 'summarize');
      await svc.invalidatePrefixReuse(h);
      await svc.invalidatePrefixReuse(h); // 幂等：重复调用不抛
    });

    test('句柄传递：config.prefixReuse 随原语调用接受（缺省 null 零变化）',
        () async {
      final face = _FakeSupplyFace(script: [
        Stream.value(const EngineChunk(deltaText: '带句柄产出')),
      ]);
      final svc = AidlOnDeviceCapabilityService(face);
      final h = svc.acquirePrefixReuseHandle(scope: 'summarize');
      const cfgWith = OnDevicePrimitiveConfig(
        prefixReuse: PrefixReuseHint(
            handle: PrefixReuseHandle(scope: 'summarize', epoch: 0),
            expectedPrefixChars: 512),
      );
      // 缺省 config：prefixReuse 为 null（既有行为零变化）。
      expect(const OnDevicePrimitiveConfig().prefixReuse, isNull);
      // 携带 hint 的调用照常受理（提示的引擎侧承载待实证，本面只传递）。
      final out = await svc.complete(
        instruction: '摘要',
        input: '原文',
        config: cfgWith,
      );
      expect(out, '带句柄产出');
      expect(face.generateCalls, 1, reason: 'hint 经原语面受理，调用链零分支变化');
      expect(h.scope, 'summarize');
    });
  });
}
