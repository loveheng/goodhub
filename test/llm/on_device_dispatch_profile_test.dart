import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_dispatch_profile.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// DispatchProfile 准入画像回归钉（2026-11-01 拍板：准入探针与坏后端记忆合并）。
/// 设计 SSOT：docs/design/on-device-admission-probe.md §1/§2/§6。
void main() {
  group('DispatchProfile 契约', () {
    test('toJson/fromJson 往返无损', () {
      final p = DispatchProfile(
        driverFingerprint: 'fp-abc',
        probedAtMs: 1793571499687,
        backends: {
          'NPU': const BackendProfile(
            verdict: BackendVerdict.healthy,
            ttftMs: 271,
            memBytes: 1900,
            probedAtMs: 1793571499687,
          ),
          'GPU': const BackendProfile(
            verdict: BackendVerdict.excluded,
            reason: BackendReason.zeroOutput,
          ),
        },
      );
      final round = DispatchProfile.fromJson(jsonEncode(p.toJson()));
      expect(round, isNotNull);
      expect(round!.driverFingerprint, 'fp-abc');
      expect(round.backends['NPU']!.verdict, BackendVerdict.healthy);
      expect(round.backends['NPU']!.ttftMs, 271);
      expect(round.backends['GPU']!.verdict, BackendVerdict.excluded);
      expect(round.backends['GPU']!.reason, BackendReason.zeroOutput);
    });

    test('损坏 JSON / 缺指纹 → null（脏数据不阻断路由）', () {
      expect(DispatchProfile.fromJson('not-json'), isNull);
      expect(DispatchProfile.fromJson(jsonEncode({'backends': {}})), isNull);
    });

    test('routeTarget 语义（设计稿 §6）', () {
      DispatchProfile profile(BackendProfile npu, BackendProfile gpu) =>
          DispatchProfile(driverFingerprint: 'fp', backends: {
            'NPU': npu,
            'GPU': gpu,
          });
      const healthy = BackendProfile(verdict: BackendVerdict.healthy);
      const excluded = BackendProfile(
          verdict: BackendVerdict.excluded, reason: BackendReason.timeout);
      // NPU 健康 → NPU
      expect(profile(healthy, excluded).routeTarget(), 'NPU');
      // NPU 排除 + GPU 健康 → GPU
      expect(profile(excluded, healthy).routeTarget(), 'GPU');
      // 双坏 → null（切云）
      expect(profile(excluded, excluded).routeTarget(), isNull);
    });
  });

  group('.admission.json 读写（asset_manager 同源生命周期）', () {
    late Directory supportDir;
    var fingerprint = 'fp-v79-a';

    setUp(() async {
      supportDir =
          await Directory.systemTemp.createTemp('admission-profile-test');
    });

    tearDown(() async {
      await supportDir.delete(recursive: true);
    });

    OnDeviceAssetManager mgr() => OnDeviceAssetManager.forTest(
          fingerprintProvider: () async => fingerprint,
          supportDirResolver: () async => supportDir,
        );

    OnDeviceModelOption model(String dirName) =>
        OnDeviceModelOption(dirName: dirName, id: dirName,
            displayName: dirName, base: '');

    Directory modelDir(String dirName) {
      final d = Directory('${supportDir.path}/models/$dirName')
        ..createSync(recursive: true);
      // 资产在位（meta 在场 = 已装语义）
      File('${d.path}/.asset-meta.json').writeAsStringSync('{}');
      return d;
    }

    test('写入 → 读回一致', () async {
      modelDir('m1');
      await mgr().writeDispatchProfile(model('m1'), {
        'NPU': const BackendProfile(verdict: BackendVerdict.healthy, ttftMs: 300),
        'GPU': const BackendProfile(verdict: BackendVerdict.excluded,
            reason: BackendReason.driverIncompatible),
      });
      final p = await mgr().readDispatchProfile(model('m1'));
      expect(p, isNotNull);
      expect(p!.backends['NPU']!.verdict, BackendVerdict.healthy);
      expect(p.backends['GPU']!.reason, BackendReason.driverIncompatible);
      expect(await File('${supportDir.path}/models/m1/.admission.json').exists(),
          isTrue);
    });

    test('指纹漂移 → 画像失效并清脏文件（§1 键含 FINGERPRINT）', () async {
      modelDir('m2');
      final m = mgr();
      await m.writeDispatchProfile(model('m2'), {
        'NPU': const BackendProfile(verdict: BackendVerdict.healthy),
      });
      // 驱动 OTA：指纹变化
      fingerprint = 'fp-v79-b';
      final p = await m.readDispatchProfile(model('m2'));
      expect(p, isNull);
      expect(
          await File('${supportDir.path}/models/m2/.admission.json').exists(),
          isFalse);
    });

    test('损坏画像文件 → 视为缺失并清脏', () async {
      modelDir('m3');
      File('${supportDir.path}/models/m3/.admission.json')
          .writeAsStringSync('broken');
      final p = await mgr().readDispatchProfile(model('m3'));
      expect(p, isNull);
      expect(
          await File('${supportDir.path}/models/m3/.admission.json').exists(),
          isFalse);
    });
  });
}
