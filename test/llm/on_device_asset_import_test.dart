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

  test('正常体积散文件 → 收（meta 登记 displayName，未知布局 runtime=auto）', () async {
    final ok = await sparseFile(tmp, 'weights.bin', 1024 * 1024);
    final dir = await mgr.importFromPickedFiles([ok.path], target: target);
    expect(dir, isNotNull);
    expect(dir!.path, contains('my-model'));
    final meta =
        jsonDecode(await File('${dir.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['version'], startsWith('local-import'));
    expect(meta['displayName'], 'My Model');
    expect(meta['runtime'], OnDeviceRuntime.auto);
  });

  test('坏 GGUF（头魔数非 GGUF）→ 拒（结构校验硬闸）', () async {
    final bad = File('${tmp.path}/fake.gguf');
    await bad.writeAsBytes(List.filled(64, 0xAB));
    final dir = await mgr.importFromPickedFiles([bad.path], target: target);
    expect(dir, isNull);
  });

  test('合法 GGUF 头 → 收（runtime 检测为 llama_cpp）', () async {
    final gguf = File('${tmp.path}/model.gguf');
    await gguf.writeAsBytes(
        [0x47, 0x47, 0x55, 0x46, ...List.filled(60, 0)]); // "GGUF" + padding
    final dir = await mgr.importFromPickedFiles([gguf.path], target: target);
    expect(dir, isNotNull);
    final meta =
        jsonDecode(await File('${dir!.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['runtime'], OnDeviceRuntime.llamaCpp);
    expect(meta['family'], OnDeviceAssetFamily.geniex); // D-1 族映射单源
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
}
