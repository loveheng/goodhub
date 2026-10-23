/// 执行面链构造机械门禁（架构债 #19 · R9 · `arch-guard.sh` R9 的 flutter-test 镜像）。
///
/// **规则（只两种合法形态）**：
/// ① `inner: inner` —— 经唯一装配器 `composeToolExecutorChain` 的层工厂；
/// ② `inner: <内联构造>` —— 终端兜底（如 `inner: _NeverExecutor()`）。
///
/// **禁止**：③ `inner: <执行面实例变量>` —— 那正是「手工逐层包裹」的链：
/// 新层可直接指向链上任一段，内层即被整层丢弃，对外表现为「工具目录可见、
/// 调用全败」（实证 2026-10-23：宿主执行链在资源面在场时丢掉 status 层）。
///
/// 规则正文见 `docs/project/coding-standards.md` §8.1「链式装配等价性」；
/// 装配器见 `lib/coordinator/tool_executor_chain.dart`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥注释（行注释 + 块注释）——防「注释里写一句 inner: 就骗过门禁」。
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// 命名参数 `inner: <标识符>`（前置 `(` 或 `,` —— Dart 命名实参只此两种位置）。
final RegExp _innerArgRe =
    RegExp(r'[(,]\s*inner:\s*([A-Za-z_][A-Za-z0-9_]*)');

/// 一条违例。
class _Hit {
  const _Hit(this.file, this.lineno, this.code);

  final String file;
  final int lineno;
  final String code;

  @override
  String toString() => '$file:$lineno → $code';
}

/// 扫描 [root] 下全部 `.dart`，返回「inner 指向执行面实例变量」的违例清单。
List<_Hit> _scanChainViolations(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const <_Hit>[];
  final out = <_Hit>[];
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final rel = f.path.replaceAll('\\', '/');
    final raw = f.readAsStringSync();
    final src = _stripComments(raw);
    for (final m in _innerArgRe.allMatches(src)) {
      final name = m.group(1)!;
      if (name == 'inner') continue; // ① 装配器层工厂形态
      final nextChar = m.end < src.length ? src[m.end] : '';
      if (nextChar == '(') continue; // ② 内联构造形态（终端兜底）
      final before = raw.substring(0, m.start);
      out.add(_Hit(rel, '\n'.allMatches(before).length + 1, m.group(0)!));
    }
  }
  return out;
}

void main() {
  group('R9 执行面链构造门禁', () {
    test('lib/ 内不得手工把执行面实例塞进另一层的 inner', () {
      final hits = _scanChainViolations('lib');
      expect(
        hits,
        isEmpty,
        reason: '执行面链层构造只允许经 composeToolExecutorChain（层工厂形态 '
            'inner: inner）或内联终端构造；手工链可致内层整层丢弃——目录可见、'
            '调用全败。hits=$hits',
      );
    });

    test('扫描范围非空（防空集假绿）', () {
      final dir = Directory('lib');
      expect(dir.existsSync(), isTrue);
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .length;
      expect(files, greaterThan(100),
          reason: 'lib/ 文件数异常偏少，扫描范围可能失效');
    });
  });

  group('扫描器自身正确性（金丝雀）', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('chain_guard_canary'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    void write(String rel, String body) {
      final f = File('${tmp.path}/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(body);
    }

    test('抓到手工链（inner 指向实例变量）', () {
      write('lib/coordinator/bad.dart', '''
library;
final memoryTool = MemoryToolExecutor(inner: router, store: store);
final gateway = PermissionGateway(inner: memoryTool);
''');
      final hits = _scanChainViolations('${tmp.path}/lib');
      expect(hits, hasLength(2),
          reason: '两处手工链都须被抓到（router 与 memoryTool 均为实例变量）');
    });

    test('放过装配器层工厂与内联终端构造', () {
      write('lib/coordinator/ok.dart', '''
library;
final executor = composeToolExecutorChain([
  (inner) => MemoryToolExecutor(inner: inner, store: store),
], fallback: const _NeverExecutor());
final classifier = PermissionGateway(inner: _NeverExecutor());
''');
      expect(_scanChainViolations('${tmp.path}/lib'), isEmpty);
    });

    test('不误报注释与字段声明', () {
      write('lib/coordinator/ok2.dart', '''
library;
// inner: memoryTool  ← 注释里的旧写法
/// 文档示例：inner: gateway
class Foo {
  final ToolExecutor inner;
}
''');
      expect(_scanChainViolations('${tmp.path}/lib'), isEmpty);
    });
  });
}
