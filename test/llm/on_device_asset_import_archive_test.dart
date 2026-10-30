import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// 压缩包导入通道（importFromArchive，2026-10-30 增补）回归钉：
/// zip/tar.gz → 流式解压 → 压平（嵌套提升/点前缀剔除/重名拒绝）→
/// 档位体积对账 → local-import meta → 原子替换。
void main() {
  /// 造自造档位（小体积，避免 3GB 真实档位的测试 IO）。
  const fakeModel = OnDeviceModelOption(
    id: 'fake-1b',
    displayName: 'Fake（测试）',
    base: 'http://127.0.0.1:1/fake',
    dirName: 'fake-test-dir',
    expectedTotalBytes: 300, // 与下方造的压缩包内容对账
  );

  /// 内存构造 zip（精确内容：相对路径 → 字节），落盘返回路径。
  Future<String> makeZip(Directory dir, Map<String, List<int>> files) async {
    final archive = Archive();
    for (final e in files.entries) {
      archive.add(ArchiveFile.bytes(e.key, e.value));
    }
    final zipPath = '${dir.path}/model.zip';
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));
    return zipPath;
  }

  late Directory tmp;
  late OnDeviceAssetManager mgr;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gh_import_archive');
    mgr = OnDeviceAssetManager.forTest(
      supportDirResolver: () async => tmp,
      freeBytesProvider: () async => 20 * 1024 * 1024 * 1024,
      fingerprintProvider: () async => 'fp-test',
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('zip 含嵌套目录 + 点前缀文件 → 压平入库，meta 为 local-import', () async {
    final zip = await makeZip(tmp, {
      'shard-0.bin': List.filled(100, 1),
      'sub/shard-1.bin': List.filled(120, 2),
      'sub/deep/tokenizer.json': List.filled(80, 3),
      '.hidden': List.filled(5, 4), // 点前缀 → 剔除
    });
    final target = await mgr.importFromArchive(zip, model: fakeModel);
    expect(target, isNotNull);
    expect(target!.path, contains('fake-test-dir'));
    // 压平：嵌套文件全部提升到目标根。
    expect(await File('${target.path}/shard-0.bin').exists(), isTrue);
    expect(await File('${target.path}/shard-1.bin').exists(), isTrue);
    expect(await File('${target.path}/tokenizer.json').exists(), isTrue);
    expect(await File('${target.path}/.hidden').exists(), isFalse);
    // meta：local-import 前缀 + 尺寸对账面。
    final meta = await File('${target.path}/.asset-meta.json').readAsString();
    expect(meta, contains('local-import'));
    expect(meta, contains('totalBytes'));
  });

  test('体积对账不符（超容差）→ 拒绝', () async {
    final zip = await makeZip(tmp, {
      'shard-0.bin': List.filled(50, 1), // 50B ≠ 预期 300B（偏差 83%）
    });
    final target = await mgr.importFromArchive(zip, model: fakeModel);
    expect(target, isNull);
  });

  test('重名（嵌套跨目录同 basename）→ 整批拒绝', () async {
    final zip = await makeZip(tmp, {
      'a/shard.bin': List.filled(100, 1),
      'b/shard.bin': List.filled(100, 2),
    });
    final target = await mgr.importFromArchive(zip, model: fakeModel);
    expect(target, isNull);
    // 拒绝后不留 staging 残留。
    final models = Directory('${tmp.path}/models');
    if (await models.exists()) {
      expect(
        await models.list().any((e) => e.path.contains('.staging-archive')),
        isFalse,
      );
    }
  });

  test('非压缩包扩展名 → 直接拒绝', () async {
    final f = File('${tmp.path}/weights.bin');
    await f.writeAsBytes(List.filled(300, 1));
    final target = await mgr.importFromArchive(f.path, model: fakeModel);
    expect(target, isNull);
  });

  test('tar 通路 → 同样压平入库', () async {
    final archive = Archive()
      ..add(ArchiveFile.bytes('shard-0.bin', List.filled(150, 1)))
      ..add(ArchiveFile.bytes('shard-1.bin', List.filled(150, 2)));
    final tar = '${tmp.path}/model.tar';
    await File(tar).writeAsBytes(TarEncoder().encode(archive));
    final target = await mgr.importFromArchive(tar, model: fakeModel);
    expect(target, isNotNull);
    expect(await File('${target!.path}/shard-0.bin').exists(), isTrue);
    expect(await File('${target.path}/shard-1.bin').exists(), isTrue);
  });
}
