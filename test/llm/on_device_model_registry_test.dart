import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// ModelRegistry.scan 回归钉（纯导入制身份唯一源）。
///
/// 撤实现即红的一条：
/// - **目录名不得为空串**：曾用 `entity.uri.pathSegments.last` 取目录名——
///   Dart 的 `Directory.uri` 对目录恒补尾部斜杠（`file:///…/foo/`），末段
///   恒为 ''；全部已装模型 dirName='' → 装载目标打在 `models/` 根 →
///   「资产缺失」误报（2026-10-31 真机实证）。必须从 `entity.path` 取尾段。
void main() {
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('registry-test-');
  });

  tearDown(() async {
    await support.delete(recursive: true);
  });

  Future<void> writeModel(String dirName, {String? version}) async {
    final dir = Directory('${support.path}/models/$dirName');
    await dir.create(recursive: true);
    await File('${dir.path}/model.gguf').writeAsBytes([1, 2, 3]);
    await File('${dir.path}/.asset-meta.json').writeAsString(jsonEncode({
      'version': version ?? 'local-import-1',
      'runtime': 'llama_cpp',
      'sizes': {'model.gguf': 3},
      'totalBytes': 3,
    }));
  }

  test('scan：已装模型 dirName = 真实目录名（非空、非尾斜杠伪影）', () async {
    await writeModel('qwen3-4b-q8');
    await writeModel('test-model-2', version: 'local-import-abc');

    final installed = await ModelRegistry.scan(
      supportDirResolver: () async => support,
    );

    expect(installed, hasLength(2));
    final names = installed.map((m) => m.dirName).toSet();
    expect(names, containsAll(['qwen3-4b-q8', 'test-model-2']));
    expect(names.contains(''), isFalse,
        reason: 'dirName 空串 = Directory.uri 尾斜杠伪影复发（装载目标会打在 models/ 根）');
    expect(installed.every((m) => m.imported), isTrue);
  });

  test('scan：隐藏目录（.staging-*/.trash-*）与无 meta 目录不入库', () async {
    await writeModel('good-model');
    await Directory('${support.path}/models/.staging-123').create();
    await Directory('${support.path}/models/junk-no-meta').create();

    final installed = await ModelRegistry.scan(
      supportDirResolver: () async => support,
    );

    expect(installed, hasLength(1));
    expect(installed.single.dirName, 'good-model');
  });

  test('scan：models/ 根缺失 → 空列表（不抛）', () async {
    final installed = await ModelRegistry.scan(
      supportDirResolver: () async => support,
    );
    expect(installed, isEmpty);
  });
}
