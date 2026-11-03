import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goodhub/llm/device_tier.dart';
import 'package:goodhub/llm/on_device_admission_probe.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_dispatch_profile.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// 准入探针编排回归钉（DispatchProfile 设计稿 §4 执行协议）。
/// 覆盖：HEALTHY / 零产出 / 硬超时 / 生成异常 / 装载失败 / 门禁跳过 /
/// 已有画像跳过 / 双后端条目合并。
void main() {
  late Directory supportDir;

  setUp(() async {
    supportDir =
        await Directory.systemTemp.createTemp('admission-probe-test');
    // 模型目录在位（画像落盘面依赖目录存在；资产在位由 meta 文件语义承载，
    // 探针编排不校验 meta，这里只补目录）。
    Directory('${supportDir.path}/models/probe-model')
        .createSync(recursive: true);
  });

  tearDown(() async {
    if (await supportDir.exists()) {
      await supportDir.delete(recursive: true);
    }
  });

  OnDeviceModelOption model() =>
      OnDeviceModelOption.fromInstalled('probe-model');

  OnDeviceAssetManager mgr() => OnDeviceAssetManager.forTest(
        fingerprintProvider: () async => 'fp-a',
        supportDirResolver: () async => supportDir,
      );

  AdmissionProbe probe({
    Future<bool> Function(OnDeviceModelOption, String?)? onLoad,
    Stream<String> Function(String, {required int maxTokens})? onGenerate,
    Future<String?> Function()? onObservedRuntime,
    Future<DeviceProbe?> Function()? onDeviceProbe,
    Duration hardTimeout = const Duration(milliseconds: 200),
  }) {
    return AdmissionProbe(
      onLoad: onLoad ?? ((_, _) async => true),
      onUnload: () async {},
      onGenerate: onGenerate ??
          (_, {required maxTokens}) =>
              Stream.fromIterable(const ['Hel', 'lo']),
      onObservedRuntime:
          onObservedRuntime ?? (() async => 'litertlm-npu'),
      onDeviceProbe: onDeviceProbe ?? () async => null,
      assetManager: mgr(),
      hardTimeout: hardTimeout,
      now: () => DateTime.fromMillisecondsSinceEpoch(1793571499687),
    );
  }

  test('生成合法出字 → HEALTHY + ttft，落 NPU 条目（runtime 含 npu）', () async {
    final p = await probe().probe(model());
    expect(p, isNotNull);
    expect(p!.backends['NPU'], isNotNull);
    expect(p.backends['NPU']!.verdict, BackendVerdict.healthy);
    expect(p.backends['NPU']!.ttftMs, isNotNull);
  });

  test('runtime 不含 npu → 落 GPU 条目', () async {
    final p = await probe(
      onObservedRuntime: () async => 'litertlm-gpu',
    ).probe(model());
    expect(p!.backends['GPU']!.verdict, BackendVerdict.healthy);
  });

  test('冒烟通过：正常出字 → HEALTHY + ttft', () async {
    final p = await probe(
      onGenerate: (_, {required maxTokens}) => Stream.fromIterable(
        const ['我是', '一个端侧', '助手，', '运行在', '你的手机上。'],
      ),
    ).probe(model());
    expect(p!.backends['NPU']!.verdict, BackendVerdict.healthy);
    expect(p.backends['NPU']!.ttftMs, isNotNull);
  });

  test('冒烟复读环 → EXCLUDED repetition（§4.1 冒烟第二校验）', () async {
    final p = await probe(
      onGenerate: (_, {required maxTokens}) => Stream.fromIterable(
        const ['12', '1212', '12121212', '1212121212121212'],
      ),
    ).probe(model());
    expect(p!.backends['NPU']!.verdict, BackendVerdict.excluded);
    expect(p.backends['NPU']!.reason, BackendReason.repetition);
  });

  test('复读环判定边界：正常句尾不误判（判据纯函数钉）', () {
    expect(AdmissionProbe.looksLikeRepetitionLoop('12222'), isFalse);
    expect(
        AdmissionProbe.looksLikeRepetitionLoop('这是一个正常的回答。'), isFalse);
    expect(AdmissionProbe.looksLikeRepetitionLoop('12' * 20), isTrue);
    expect(AdmissionProbe.looksLikeRepetitionLoop('2' * 20), isTrue);
  });

  test('零产出（空 delta）→ EXCLUDED zeroOutput（§4.3 有效性校验）', () async {
    final p = await probe(
      onGenerate: (_, {required maxTokens}) => Stream.fromIterable(const ['', '']),
    ).probe(model());
    expect(p!.backends['NPU']!.verdict, BackendVerdict.excluded);
    expect(p.backends['NPU']!.reason, BackendReason.zeroOutput);
  });

  test('挂流不产出 → 硬超时 EXCLUDED timeout（§4 硬超时）', () async {
    final p = await probe(
      onGenerate: (_, {required maxTokens}) =>
          Stream<String>.fromFuture(Completer<String>().future),
      hardTimeout: const Duration(milliseconds: 50),
    ).probe(model());
    expect(p!.backends['NPU']!.verdict, BackendVerdict.excluded);
    expect(p.backends['NPU']!.reason, BackendReason.timeout);
  });

  test('流内异常 → EXCLUDED crash', () async {
    final p = await probe(
      onGenerate: (_, {required maxTokens}) =>
          Stream<String>.error(Exception('fast rpc hung')),
    ).probe(model());
    expect(p!.backends['NPU']!.verdict, BackendVerdict.excluded);
    expect(p.backends['NPU']!.reason, BackendReason.crash);
  });

  test('装载失败 → EXCLUDED opNotSupported 且不跑微基准', () async {
    var genCalled = false;
    final m = mgr();
    final p = await probe(
      onLoad: (_, _) async => false,
      onGenerate: (_, {required maxTokens}) {
        genCalled = true;
        return Stream.fromIterable(const ['x']);
      },
    ).probe(model());
    // 装载失败路径 probe 返回 null，画像落盘经读取面断言。
    expect(p, isNull);
    final recorded = await m.readDispatchProfile(model());
    expect(recorded!.backends['NPU']!.verdict, BackendVerdict.excluded);
    expect(recorded.backends['NPU']!.reason, BackendReason.opNotSupported);
    expect(genCalled, isFalse);
  });

  test('设备门禁不过 → 跳过探针不装载（§3 设备门禁，经 probeIfNeeded）', () async {
    var loaded = false;
    final p = await probe(
      onLoad: (_, _) async {
        loaded = true;
        return true;
      },
      onDeviceProbe: () async => const DeviceProbe(totalRamBytes: 4 << 30),
    ).probeIfNeeded(model());
    expect(p, isNull);
    expect(loaded, isFalse);
  });

  test('已有有效画像 → 原样返回不重探（§3 重探条件）', () async {
    final m = mgr();
    final dir = Directory('${supportDir.path}/models/probe-model')
      ..createSync(recursive: true);
    File('${dir.path}/.asset-meta.json').writeAsStringSync('{}');
    await m.writeDispatchProfile(model(), {
      'NPU': const BackendProfile(verdict: BackendVerdict.healthy, ttftMs: 300),
    });
    var loaded = false;
    final p = await probe(onLoad: (_, _) async {
      loaded = true;
      return true;
    }).probeIfNeeded(model());
    expect(p!.backends['NPU']!.ttftMs, 300);
    expect(loaded, isFalse);
  });

  test('合并写入：探针只写观测后端，保另一后端既有条目（§1 双 verdict 同体）', () async {
    final m = mgr();
    final dir = Directory('${supportDir.path}/models/probe-model')
      ..createSync(recursive: true);
    File('${dir.path}/.asset-meta.json').writeAsStringSync('{}');
    await m.writeDispatchProfile(model(), {
      'GPU': const BackendProfile(
          verdict: BackendVerdict.excluded, reason: BackendReason.timeout),
    });
    final p = await probe(
      onObservedRuntime: () async => 'litertlm-npu',
    ).probe(model());
    expect(p!.backends['NPU']!.verdict, BackendVerdict.healthy);
    expect(p.backends['GPU']!.reason, BackendReason.timeout);
  });
}
