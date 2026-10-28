/// §S4 原子写唯一入口的 Dart 镜像（与 arch-guard R10 同规则；CI 跑本件）：
/// `lib/` 下（除 `lib/core/storage/` 基准件）禁 `File.writeAsString` /
/// `File.writeAsBytes`——落盘一律经 `KeyedWriteQueue.enqueueAtomicWrite`。
library;

import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';

const _banned = r'\.writeAsString(Sync)?\(|\.writeAsBytes(Sync)?\(';
const _allowedPrefix = 'lib/core/storage/';

List<String> _scan() {
  final hits = <String>[];
  final lib = io.Directory('lib');
  final pattern = RegExp(_banned);
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! io.File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.startsWith(_allowedPrefix)) continue;
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) hits.add('${entity.path}:${i + 1}');
    }
  }
  return hits;
}

void main() {
  test('F-R10 lib/ 无裸写 File.writeAs*（原子写唯一入口）', () {
    expect(_scan(), isEmpty,
        reason: '落盘一律经 KeyedWriteQueue.enqueueAtomicWrite / '
            'SequentialFileWriter（§3.2 + §S4）');
  });

  test('金丝雀：检测器确实能抓到坏样本（防空转假绿）', () async {
    final tmp = await io.Directory.systemTemp.createTemp('atomic_rule_canary');
    addTearDown(() => tmp.delete(recursive: true));
    final f = io.File('${tmp.path}/bad.dart')..writeAsStringSync('void f() => File("x").writeAsString("y");');
    final pattern = RegExp(_banned);
    expect(pattern.hasMatch(f.readAsStringSync()), isTrue);
  });
}
