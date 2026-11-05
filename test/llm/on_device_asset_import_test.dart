import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// 导入通道回归钉（2026-10-31 纯导入制：固定 qwen 双档位退役，档位体积对账
/// 随 `expectedTotalBytes` 一并退役——「1.7B 档装 4B 分片」的档位错配不可能
/// 再发生（无固定档位目录），防 LMK 职责由**绝对体积上限**（12GB，拷贝前
/// 拦截）+ 装载期内存护栏承接。本组钉：体积上限硬拒 + 结构校验（GGUF 魔数）
/// + meta 的 runtime/displayName 登记。
void main() {
  /// 造稀疏文件（只设长度不写盘，测试不真占 13GB）。
  Future<File> sparseFile(Directory dir, String name, int bytes) async {
    final f = File('${dir.path}/$name');
    final raf = await f.open(mode: FileMode.write);
    await raf.truncate(bytes);
    await raf.close();
    return f;
  }

  late Directory tmp;
  late OnDeviceAssetManager mgr;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gh_import');
    mgr = OnDeviceAssetManager.forTest(
      supportDirResolver: () async => tmp,
      freeBytesProvider: () async => 20 * 1024 * 1024 * 1024,
      fingerprintProvider: () async => 'fp-test',
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  const target = ImportTarget(dirName: 'my-model', displayName: 'My Model');

  test('超绝对体积上限（>12GB）→ 拒绝（拷贝前拦截，无 staging 残留）', () async {
    final big = await sparseFile(tmp, 'huge.gguf', 13 * 1024 * 1024 * 1024);
    final dir = await mgr.importFromPickedFiles([big.path], target: target);
    expect(dir, isNull);
    final models = Directory('${tmp.path}/models');
    if (await models.exists()) {
      expect(
        await models.list().any((e) => e.path.contains('.staging-import')),
        isFalse,
      );
    }
  });

  test('未知布局（纯 bin 散件）→ 拒（族级导入拒绝，2026-11-02）', () async {
    final ok = await sparseFile(tmp, 'weights.bin', 1024 * 1024);
    final dir = await mgr.importFromPickedFiles([ok.path], target: target);
    expect(dir, isNull);
  });

  test('合法族文件 → 收（meta 登记 displayName + runtime/family）', () async {
    final ok = await sparseFile(tmp, 'gemma3-1b.litertlm', 1024 * 1024);
    final dir = await mgr.importFromPickedFiles([ok.path], target: target);
    expect(dir, isNotNull);
    expect(dir!.path, contains('my-model'));
    final meta =
        jsonDecode(await File('${dir.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['version'], startsWith('local-import'));
    expect(meta['displayName'], 'My Model');
    expect(meta['runtime'], OnDeviceRuntime.litertlm);
    expect(meta['family'], OnDeviceAssetFamily.litertlm);
  });

  test('坏 GGUF（头魔数非 GGUF）→ 拒（结构校验硬闸）', () async {
    final bad = File('${tmp.path}/fake.gguf');
    await bad.writeAsBytes(List.filled(64, 0xAB));
    final dir = await mgr.importFromPickedFiles([bad.path], target: target);
    expect(dir, isNull);
  });

  test('合法 GGUF 头 → 收（runtime=llamaCpp；2026-11-01 关闸已按裁决放开，'
      '仅保留魔数硬拒与三闸结构）', () async {
    final gguf = File('${tmp.path}/model.gguf');
    await gguf.writeAsBytes(
        [0x47, 0x47, 0x55, 0x46, ...List.filled(60, 0)]); // "GGUF" + padding
    final dir = await mgr.importFromPickedFiles([gguf.path], target: target);
    expect(dir, isNotNull);
    final meta =
        jsonDecode(await File('${dir!.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['runtime'], OnDeviceRuntime.llamaCpp);
  });

  test('.litertlm 资产 → 收（runtime=litertlm，family=litertlm）', () async {
    final f = await sparseFile(tmp, 'gemma3-1b.litertlm', 1024 * 1024);
    final dir = await mgr.importFromPickedFiles([f.path], target: target);
    expect(dir, isNotNull);
    final meta =
        jsonDecode(await File('${dir!.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['runtime'], OnDeviceRuntime.litertlm);
    expect(meta['family'], OnDeviceAssetFamily.litertlm); // 首发 .litertlm 族
  });

  test('familyOf 单源映射钉（runtime → 资产族，D-1 双段路由）', () {
    expect(OnDeviceAssetFamily.familyOf(OnDeviceRuntime.qairt),
        OnDeviceAssetFamily.geniex);
    expect(OnDeviceAssetFamily.familyOf(OnDeviceRuntime.llamaCpp),
        OnDeviceAssetFamily.geniex);
    expect(OnDeviceAssetFamily.familyOf(OnDeviceRuntime.litertlm),
        OnDeviceAssetFamily.litertlm);
    expect(OnDeviceAssetFamily.familyOf(OnDeviceRuntime.auto),
        OnDeviceAssetFamily.unknown);
  });

  group('per-bundle 规格表匹配（S1 数据住配置文件，代码零绑定）', () {
    const specJson = '''
{
  "schemaVersion": 1,
  "bundles": [
    {
      "id": "litertlm-gemma3-1b",
      "runtime": "litertlm",
      "artifactPattern": "gemma3-1b",
      "contextTokens": 1280,
      "recommendedSampling": { "temperature": 1.0, "topP": 0.95 }
    }
  ]
}
''';

    Future<Map<String, dynamic>> importLitertlm(
        String fileName, String spec) async {
      final tmp2 = await Directory.systemTemp.createTemp('gh_spec');
      final m = OnDeviceAssetManager.forTest(
        supportDirResolver: () async => tmp2,
        freeBytesProvider: () async => 20 * 1024 * 1024 * 1024,
        fingerprintProvider: () async => 'fp-test',
        modelSpecsSource: () async => spec,
      );
      final f = await sparseFile(tmp2, fileName, 1024 * 1024);
      final dir =
          await m.importFromPickedFiles([f.path], target: target);
      expect(dir, isNotNull);
      final meta = jsonDecode(
              await File('${dir!.path}/.asset-meta.json').readAsString())
          as Map<String, dynamic>;
      await tmp2.delete(recursive: true);
      return meta;
    }

    test('artifactPattern 命中 → 规格行回填 contextTokens/recommendedSampling',
        () async {
      final meta =
          await importLitertlm('gemma3-1b-it-q4.litertlm', specJson);
      final profile = meta['modelProfile'] as Map<String, dynamic>;
      expect(profile['contextTokens'], 1280);
      expect(profile['recommendedSampling'],
          {'temperature': 1.0, 'topP': 0.95});
    });

    test('S12 taskAffinity 命中 → 整块透传进 modelProfile（含 caveat/source）',
        () async {
      const affinitySpec = '''
{
  "schemaVersion": 1,
  "bundles": [
    {
      "id": "litertlm-gemma3-1b",
      "runtime": "litertlm",
      "artifactPattern": "gemma3-1b",
      "taskAffinity": { "qa": "degraded", "classify": "unusable" },
      "taskAffinityCaveats": { "qa": "长体量产出冗长" },
      "taskAffinitySource": "bench-archive S11"
    }
  ]
}
''';
      final meta = await importLitertlm('gemma3-1b-it-q4.litertlm', affinitySpec);
      final profile = meta['modelProfile'] as Map<String, dynamic>;
      expect(profile['taskAffinity'], {'qa': 'degraded', 'classify': 'unusable'});
      expect(profile['taskAffinityCaveats'], {'qa': '长体量产出冗长'});
      expect(profile['taskAffinitySource'], 'bench-archive S11');
    });

    test('S12 taskAffinity 畸形（非对象）→ 字段缺席不猜值', () async {
      const badSpec = '''
{
  "schemaVersion": 1,
  "bundles": [
    {
      "id": "litertlm-gemma3-1b",
      "runtime": "litertlm",
      "artifactPattern": "gemma3-1b",
      "taskAffinity": "usable"
    }
  ]
}
''';
      final meta = await importLitertlm('gemma3-1b-it-q4.litertlm', badSpec);
      final profile = meta['modelProfile'] as Map<String, dynamic>?;
      expect(profile?['taskAffinity'], isNull);
      expect(profile?['taskAffinityCaveats'], isNull);
    });

    test('无命中行 → S1 字段缺席（S2 内建缺省归目录层，不在此猜值）', () async {
      final meta = await importLitertlm('qwen-unknown.litertlm', specJson);
      final profile = meta['modelProfile'] as Map<String, dynamic>?;
      expect(profile?['contextTokens'], isNull);
      expect(profile?['recommendedSampling'], isNull);
    });

    test('规格表不可读/畸形 → 空表降级（增强面非门禁，不阻断导入）', () async {
      final meta =
          await importLitertlm('gemma3-1b.litertlm', '{ not-json');
      expect(meta['runtime'], OnDeviceRuntime.litertlm);
      final profile = meta['modelProfile'] as Map<String, dynamic>?;
      expect(profile?['recommendedSampling'], isNull);
    });
  });
}
