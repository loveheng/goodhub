/// 契约面漂移护栏 CI 镜像（meta-upgrade · 2026-10-23）。
///
/// 与全局引擎 `drift-guard.sh`（~/.agents/toolbox/scripts/，pre-commit 侧经
/// toolbox 分派）**同读同一 registry**（`scripts/agent-tools/drift-registry.txt`）：
/// CI 环境无 toolbox，故以本 Dart 镜像进 `flutter test` 全量门禁。扫描逻辑都是
/// grep 等价物（固定串 + 行级过滤），registry 是唯一数据源——镜像不是引擎副本。
///
/// 三类检查（与引擎同口径）：
/// - BANNED  退役词条（token 级）：PC 可见 copy 与 docs 出现已退役拼写；
/// - CONST   单源常量（字面量级）：lib/ 代码字面量只许出现在声明处（+登记镜像）；
/// - OVERSIZE 体量登记（行数级）：lib/ 超限件必须登记在项目超标清单。
///
/// 口径细节（与引擎逐条对齐，改其一须同轮改其二）：
/// - `.dart` 整行注释（`//` / `*` 起头）不判；任意行内 `drift:keep` 显式豁免；
/// - CONST 只扫 lib/（测试字面量是有意的独立钉子，常量变更经测试失败自曝）；
/// - OVERSIZE 按 lib/ 前缀剥离形态核对（`ui/chat_page.dart`）；
/// - registry 缺失 = 项目未接入 → 跳过（与引擎放行语义一致）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// registry 行：`类型|字段...`（`#` 起头与空行忽略；字段内多值用 `,`）。
sealed class _Rule {}

class _Banned extends _Rule {
  _Banned(this.token, this.scopes, this.reason, this.lineNo);
  final String token;
  final List<String> scopes;
  final String reason;
  final int lineNo;
}

class _Const extends _Rule {
  _Const(this.name, this.literal, this.files, this.lineNo);
  final String name;
  final String literal;
  final List<String> files; // 声明文件 + 登记镜像
  final int lineNo;
}

class _Oversize extends _Rule {
  _Oversize(this.limit, this.listFile, this.lineNo);
  final int limit;
  final String listFile;
  final int lineNo;
}

List<_Rule> _parseRegistry(String text) {
  final rules = <_Rule>[];
  final lines = text.split('\n');
  var ruleNo = 0; // 只数规则行（与引擎口径一致：注释/空行不占编号）
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final parts = line.split('|');
    ruleNo++;
    final no = ruleNo;
    switch (parts.first) {
      case 'BANNED':
        rules.add(_Banned(parts[1], parts[2].split(','), parts.length > 3 ? parts[3] : '', no));
      case 'CONST':
        rules.add(_Const(parts[1], parts[2], parts[3].split(','), no));
      case 'OVERSIZE':
        rules.add(_Oversize(int.parse(parts[1]), parts[2], no));
      default:
        fail('registry 第 $no 条规则类型「${parts.first}」未知'
            '（合法: BANNED/CONST/OVERSIZE）');
    }
  }
  return rules;
}

/// 行级豁免：.dart 整行注释（// 与 * 起头）不判；任意行内 drift:keep 显式豁免。
bool _exempt(String line, {required bool dart}) {
  if (line.contains('drift:keep')) return true;
  if (!dart) return false;
  final t = line.trimLeft();
  return t.startsWith('//') || t.startsWith('*');
}

/// scope 展开为文件列表（目录递归 .dart/.md；文件原样）。
List<File> _expandScope(String root, String scope) {
  final target = '$root/$scope';
  final out = <File>[];
  if (File(target).existsSync()) {
    out.add(File(target));
  } else if (Directory(target).existsSync()) {
    for (final e in Directory(target).listSync(recursive: true)) {
      if (e is File && (e.path.endsWith('.dart') || e.path.endsWith('.md'))) {
        out.add(e);
      }
    }
  }
  return out;
}

List<String> _rel(String root, String path) => [path.substring(root.length + 1)];

void main() {
  final root = Directory.current.path;
  final registryFile = File('$root/scripts/agent-tools/drift-registry.txt');

  if (!registryFile.existsSync()) {
    // 未接入（registry 缺失）→ 与引擎同语义放行，不造假通过也不误伤。
    test('drift-guard 镜像：registry 缺失，项目未接入，跳过', () {});
    return;
  }

  final rules = _parseRegistry(registryFile.readAsStringSync());
  final findings = <String>[];

  for (final rule in rules) {
    if (rule is _Banned) {
      for (final scope in rule.scopes) {
        for (final f in _expandScope(root, scope)) {
          final isDart = f.path.endsWith('.dart');
          final lines = f.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (_exempt(lines[i], dart: isDart)) continue;
            if (!lines[i].contains(rule.token)) continue;
            findings.add('${_rel(root, f.path).first}:${i + 1} '
                '[D1-banned#${rule.lineNo}] 退役词条「${rule.token}」'
                '不得出现在契约面（${rule.reason}）');
          }
        }
      }
    } else if (rule is _Const) {
      final libDir = Directory('$root/lib');
      for (final e in libDir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final rel = _rel(root, e.path).first;
        final lines = e.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (_exempt(lines[i], dart: true)) continue;
          if (!lines[i].contains(rule.literal)) continue;
          if (rule.files.contains(rel)) continue;
          findings.add('$rel:${i + 1} [D2-const#${rule.lineNo}] '
              '单源常量 ${rule.name} 的字面量「${rule.literal}」'
              '只许出现在: ${rule.files.join(',')}');
        }
      }
    } else if (rule is _Oversize) {
      final listFile = File('$root/${rule.listFile}');
      if (!listFile.existsSync()) {
        findings.add('registry [D3-oversize#${rule.lineNo}] '
            '登记清单文件不存在: ${rule.listFile}');
        continue;
      }
      final listText = listFile.readAsStringSync();
      for (final e in Directory('$root/lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final lines = e.readAsLinesSync().length;
        if (lines <= rule.limit) continue;
        final rel = _rel(root, e.path).first;
        final registered = rel.startsWith('lib/') ? rel.substring(4) : rel;
        if (!listText.contains(registered)) {
          findings.add('$rel [D3-oversize#${rule.lineNo}] '
              'lib/ 文件超 ${rule.limit} 行未登记超标清单（$lines 行）');
        }
      }
    }
  }

  test('drift-guard 镜像：契约面漂移零命中（registry 共 ${rules.length} 条）', () {
    expect(findings, isEmpty,
        reason: '契约面漂移 ${findings.length} 处——\n${findings.join('\n')}\n'
            '[remedy] 改文案/代码消除漂移；历史留档加 drift:keep；'
            '合法镜像登记 registry（禁为过检删词条）');
  });
}
