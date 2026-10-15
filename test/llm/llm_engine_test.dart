/// 端侧引擎链单测：`ChannelLlmEngine` 的原生桥协议映射与降级语义（桥缺失 /
/// 平台异常一律降级，绝不把异常穿透到任务循环），以及 `UnavailableLlmEngine`
/// 兜底实现。
///
/// 通道用 `TestDefaultBinaryMessenger` 的 mock handler，不发真实平台调用。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/llm/llm_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var seq = 0;

  MethodChannel newChannel() => MethodChannel('test/llm/${seq++}');

  void mock(MethodChannel ch, Future<Object?> Function(MethodCall) handler) =>
      messenger.setMockMethodCallHandler(ch, handler);

  void mockMissing(MethodChannel ch) =>
      mock(ch, (call) async => throw MissingPluginException('no impl'));

  group('ChannelLlmEngine · 可用性与原因', () {
    test('isAvailable 透传原生真值', () async {
      final ch = newChannel();
      mock(ch, (call) async {
        expect(call.method, 'isAvailable');
        return true;
      });
      expect(await ChannelLlmEngine(channel: ch).isAvailable, isTrue);
    });

    test('原生桥缺失 → false（不抛，绝不上穿任务循环）', () async {
      final ch = newChannel();
      mockMissing(ch);
      expect(await ChannelLlmEngine(channel: ch).isAvailable, isFalse);
    });

    test('PlatformException → false 并留痕', () async {
      final ch = newChannel();
      mock(ch, (call) async => throw PlatformException(code: 'ERR'));
      expect(await ChannelLlmEngine(channel: ch).isAvailable, isFalse);
    });

    test('unavailableReasonAsync 取真值；桥缺失回退平台文案', () async {
      final ch = newChannel();
      mock(ch, (call) async {
        expect(call.method, 'unavailableReason');
        return '模型未下载';
      });
      final e = ChannelLlmEngine(channel: ch);
      expect(await e.unavailableReasonAsync(), '模型未下载');

      final ch2 = newChannel();
      mockMissing(ch2);
      expect(
        await ChannelLlmEngine(channel: ch2).unavailableReasonAsync(),
        '当前平台无端侧大模型引擎',
      );
    });

    test('同步 unavailableReason 为桥层兜底文案（真值走异步）', () {
      expect(ChannelLlmEngine(channel: newChannel()).unavailableReason,
          isNotNull);
    });
  });

  group('ChannelLlmEngine · 生成', () {
    test('正常产出（trim 后非空）', () async {
      final ch = newChannel();
      mock(ch, (call) async => '  hello ');
      expect(await ChannelLlmEngine(channel: ch).generate('p'), 'hello');
    });

    test('空产出 / null → null（翻译式降级，不抛）', () async {
      final ch1 = newChannel();
      mock(ch1, (call) async => '   ');
      expect(await ChannelLlmEngine(channel: ch1).generate('p'), isNull);

      final ch2 = newChannel();
      mock(ch2, (call) async => null);
      expect(await ChannelLlmEngine(channel: ch2).generate('p'), isNull);
    });

    test('参数映射：system / maxTokens / response_format（含约束解码）', () async {
      final ch = newChannel();
      Map<Object?, Object?>? seen;
      mock(ch, (call) async {
        seen = call.arguments as Map<Object?, Object?>?;
        return '{"ok":true}';
      });
      await ChannelLlmEngine(channel: ch).generate(
        'prompt',
        system: 'sys',
        maxTokens: 128,
        responseFormat: const LlmResponseFormat.jsonSchema('{"type":"object"}'),
      );
      expect(seen!['prompt'], 'prompt');
      expect(seen!['system'], 'sys');
      expect(seen!['max_tokens'], 128);
      expect(seen!['response_format'], {'type': 'json', 'value': '{"type":"object"}'});
    });

    test('未传 responseFormat → 不带该参数（Tier 2 零破坏）', () async {
      final ch = newChannel();
      Map<Object?, Object?>? seen;
      mock(ch, (call) async {
        seen = call.arguments as Map<Object?, Object?>?;
        return 'x';
      });
      await ChannelLlmEngine(channel: ch).generate('p');
      expect(seen!.containsKey('response_format'), isFalse);
    });

    test('桥缺失 / 平台异常 → null', () async {
      final ch1 = newChannel();
      mockMissing(ch1);
      expect(await ChannelLlmEngine(channel: ch1).generate('p'), isNull);

      final ch2 = newChannel();
      mock(ch2, (call) async => throw PlatformException(code: 'E'));
      expect(await ChannelLlmEngine(channel: ch2).generate('p'), isNull);
    });
  });

  group('ChannelLlmEngine · 生命周期与探针', () {
    test('warmup / isWarmed / cancelActive 透传；异常与桥缺失 → false', () async {
      final ch = newChannel();
      mock(ch, (call) async => call.method == 'release' ? null : true);
      final e = ChannelLlmEngine(channel: ch);
      expect(await e.warmup(), isTrue);
      expect(await e.isWarmed(), isTrue);
      expect(await e.cancelActive(), isTrue);
      await e.release(); // void，异常不穿透

      final ch2 = newChannel();
      mockMissing(ch2);
      final e2 = ChannelLlmEngine(channel: ch2);
      expect(await e2.warmup(), isFalse);
      expect(await e2.isWarmed(), isFalse);
      expect(await e2.cancelActive(), isFalse);
      await e2.release(); // 非 Android 无原生桥，无引擎可释放
    });

    test('deviceProbe / socModel：桥缺失 → null（未知放行）', () async {
      final ch = newChannel();
      mockMissing(ch);
      final e = ChannelLlmEngine(channel: ch);
      expect(await e.deviceProbe(), isNull);
      expect(await e.socModel(), isNull);
    });

    test('deviceProbe 平台异常 → null（门禁按未知放行）', () async {
      final ch = newChannel();
      mock(ch, (call) async => throw PlatformException(code: 'E'));
      expect(await ChannelLlmEngine(channel: ch).deviceProbe(), isNull);
    });
  });

  group('UnavailableLlmEngine 兜底', () {
    test('恒不可用且 generate 恒 null（测试 / 无原生桥平台）', () async {
      const e = UnavailableLlmEngine('未下载模型');
      expect(await e.isAvailable, isFalse);
      expect(e.unavailableReason, '未下载模型');
      expect(await e.unavailableReasonAsync(), '未下载模型');
      expect(await e.generate('p'), isNull);
      expect(await e.warmup(), isFalse);
      expect(await e.cancelActive(), isFalse);
      expect(await e.isWarmed(), isFalse);
      await e.release();
    });
  });

  group('SoC 可见性', () {
    test('通用包恒可见；专包仅同 SoC 可见（大小写不敏感）', () {
      final generic = LlmModel(
          id: 'g', name: 'g', desc: 'd', file: 'g.litertlm', sizeBytes: 1);
      final npu = LlmModel(
          id: 'n', name: 'n', desc: 'd', file: 'n.litertlm', sizeBytes: 1,
          socModel: 'sm8750');
      expect(llmModelVisibleOnDevice(generic, null), isTrue);
      expect(llmModelVisibleOnDevice(npu, null), isFalse);
      expect(llmModelVisibleOnDevice(npu, 'SM8750'), isTrue);
      expect(llmModelVisibleOnDevice(npu, 'sm8650'), isFalse);
    });
  });
}
