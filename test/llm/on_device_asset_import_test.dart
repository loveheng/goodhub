import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// 导入通道「档位 ↔ 内容」一致性回归钉（2026-10-30 真机实证）。
///
/// 真机 `ls` 实测：`models/qwen3_1_7b-geniex_qairt-w4a16/`（**1.7B 档**目录）
/// 里装的是 `qwen3_4b_w4a16_part_*.bin`（4B 分片，合计 **3.17GB**）——导入
/// 通道只核对文件尺寸/重名，不核对「所选档位 ↔ 内容体积」是否同档。
///
/// 后果（真机连锁）：装载内存峰值翻倍（4B 权重 + ION 瞬态 ≈5.4GB）→ 击穿整机
/// min watermark → `:engine` 被 LMK 连杀 5 次 → Dart 退避重试（3.5/8/12/30/60s
/// ≈2 分钟一轮）→ 用户「2 分钟没有首 token」。故导入必须**拒绝档位错配**。
void main() {
  /// 造稀疏文件（只设长度不写盘，测试不真占 3GB）。
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

  test('3.19GB（4B 真实体积）导入 1.7B 档 → 拒绝（防峰值翻倍）', () async {
    final big = await sparseFile(tmp, 'qwen3_4b_w4a16_part_1_of_4.bin',
        3190000000);
    final target = await mgr.importFromPickedFiles(
      [big.path],
      model: kOnDeviceModelCatalog.first, // 1.7B 档
    );
    expect(target, isNull);
  });

  test('1.05GB（1.7B 档真实体积）导入 1.7B 档 → 接受', () async {
    final ok = await sparseFile(tmp, 'qwen3_1_7b_w4a16_part_1_of_2.bin',
        1050000000);
    final target = await mgr.importFromPickedFiles(
      [ok.path],
      model: kOnDeviceModelCatalog.first,
    );
    expect(target, isNotNull);
  });

  test('3.19GB 导入 4B 档 → 接受（同档）', () async {
    final big = await sparseFile(tmp, 'qwen3_4b_w4a16_part_1_of_4.bin',
        3190000000);
    final target = await mgr.importFromPickedFiles(
      [big.path],
      model: kOnDeviceModelCatalog.last, // 4B 档
    );
    expect(target, isNotNull);
  });

  test('模型目录登记了档位预期体积真值（导入校验的前提）', () {
    for (final o in kOnDeviceModelCatalog) {
      expect(o.expectedTotalBytes, isNotNull,
          reason: '${o.id} 未登记预期体积 → 导入校验失效');
      expect(o.expectedTotalBytes, greaterThan(500 * 1024 * 1024));
    }
    // 4B 档落盘目录名必须与真机实际目录一致（连字符名会让资产找不到）。
    expect(kOnDeviceModelCatalog.last.dirName, 'qwen3_4b-genie-w4a16');
  });
}
