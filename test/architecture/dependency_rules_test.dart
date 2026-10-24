/// 架构依赖护栏（arch-hardening 断点②立 · 2026-10-17 P0-C 加固）。
///
/// 2026-10-17 架构盘点发现原护栏只盖 2/5 红线，且正则只匹**行首单行 import**
/// （`export` 转发与多行 import 可绕过）→ 违例可 analyze 0 issue + 门禁全绿入库。
/// 本轮改为**通用扫描器 + 规则表**：
///
/// - 扫描器先剥注释（行注释 + 块注释），再匹配 `import` / `export` 的 URI——
///   **不锚行首**，覆盖 `export` 转发链与折行 import；
/// - 规则表与 `docs/project/coding-standards.md` §1.0 护栏表同源，缺一条即红灯：
///   R1 core 零出向 / R2 mcp·sandbox↛coordinator / R3 mcp·sandbox↛llm /
///   R4 ui↛gateway_controller / R5 gateway↛ui / R6 禁引 mcp/tool_router.dart。
///
/// 纯静态扫描（零外部依赖，`dart:io` + flutter_test 即可），随 `flutter test` 运行；
/// 同一组规则在 `scripts/agent-tools/arch-guard.sh` R4~R8 有 shell 秒级镜像
/// （pre-commit 钩子 10s 预算跑不动 flutter test，故双实现互为兜底）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// goodhub 扁平域目录（与 `docs/project/coding-standards.md` §1.0 分层矩阵同源；
/// 新增域须同步此表 + goodhub-index 落点登记）。
const Set<String> kGoodhubDomains = <String>{
  'app',
  'coordinator',
  'core',
  'gateway',
  'gateway_api',
  'llm',
  'mcp',
  'resources',
  'sandbox',
  'task',
  'ui',
  'update',
};

/// `import` / `export` 的 URI 捕获：两引号风格，前面允许任意缩进（含块注释内
/// 已剥离，故不锚行首）。URI 总紧跟关键字，折行的 `show`/`hide` 子句不影响捕获。
final RegExp _directiveRe =
    RegExp(r"\b(?:import|export)\s+(?:'([^']+)'|" r'"([^"]+)")');

/// 剥注释：防「注释里写了一句 import 就骗过护栏」。
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// 路径规范化（只处理 `.` / `..` / 空段；Android 单平台，不做分隔符转换）。
String _normalize(String path) {
  final out = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(seg);
    }
  }
  return out.join('/');
}

/// 一条 import/export 引用。
class _Ref {
  const _Ref({
    required this.file,
    required this.from,
    required this.uri,
    required this.to,
  });

  /// 源文件（`lib/` 相对路径）。
  final String file;

  /// 源域（根目录下散文件为 `''`）。
  final String from;

  /// 指令中的 URI 原文（用于 URI 级规则匹配与报错）。
  final String uri;

  /// 目标域（同域内部引用 / 外部包 / dart: 为 null）。
  final String? to;

  @override
  String toString() => '$file: import \'$uri\' (from=$from to=$to)';
}

/// 扫描 [root] 下全部 `.dart`，产出引用清单。
List<_Ref> _collectRefs(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const <_Ref>[];
  final out = <_Ref>[];
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final rel = f.path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp('^${RegExp.escape(root)}/'), '');
    final from = _domainOfFile(rel);
    final src = _stripComments(f.readAsStringSync());
    for (final m in _directiveRe.allMatches(src)) {
      final uri = m.group(1) ?? m.group(2);
      if (uri == null) continue;
      out.add(_Ref(
        file: rel,
        from: from,
        uri: uri,
        to: _domainOfUri(rel, uri),
      ));
    }
  }
  return out;
}

/// 源文件所属域（`lib/<域>/...` 的第一段；根目录散文件为 `''`）。
String _domainOfFile(String rel) {
  final seg = rel.split('/').first;
  return kGoodhubDomains.contains(seg) ? seg : '';
}

/// 解析 URI 目标域：外部包 / `dart:` / 同域内部引用一律 null（不参与跨域判定）。
String? _domainOfUri(String sourceRel, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    if (!uri.startsWith('package:goodhub/')) return null;
    final rest = uri.substring('package:goodhub/'.length);
    final seg = rest.split('/').first;
    return seg.endsWith('.dart') ? '' : seg;
  }
  final base = sourceRel.contains('/')
      ? sourceRel.substring(0, sourceRel.lastIndexOf('/'))
      : '';
  final joined = _normalize(base.isEmpty ? uri : '$base/$uri');
  final seg = joined.split('/').first;
  return kGoodhubDomains.contains(seg) ? seg : null;
}

/// 一条依赖规则（域级禁止 + 可选 URI 级禁止，两者取并集）。
class _Rule {
  const _Rule({
    required this.id,
    required this.name,
    required this.from,
    this.forbiddenDomains = const <String>{},
    this.forbiddenUriPatterns = const <String>[],
    this.exemptFiles = const <String>{},
    required this.hint,
  });

  final String id;
  final String name;

  /// 约束的源域集合（空集 = 全部域）。
  final Set<String> from;

  /// 禁止指向的目标域。
  final Set<String> forbiddenDomains;

  /// 禁止出现的 URI 片段（URI 级：精确钉某个文件，防同名双件误导入）。
  /// 用字面量子串而非 RegExp——保持规则表可 const（RegExp 无 const 构造）。
  final List<String> forbiddenUriPatterns;

  /// 豁免文件（`lib/` 相对路径）。
  final Set<String> exemptFiles;

  /// 命中时的修复指向。
  final String hint;

  List<_Ref> violations(List<_Ref> refs) => refs.where((r) {
        if (exemptFiles.contains(r.file)) return false;
        if (from.isNotEmpty && !from.contains(r.from)) return false;
        if (forbiddenDomains.contains(r.to)) return true;
        for (final p in forbiddenUriPatterns) {
          if (r.uri.contains(p)) return true;
        }
        return false;
      }).toList();
}

/// 规则表（与 coding-standards.md §1.0 护栏表同源，改规则须同步 shell 镜像
/// `scripts/agent-tools/arch-guard.sh` R4~R8）。
const List<_Rule> _kDependencyRules = <_Rule>[
  _Rule(
    id: 'R1',
    name: 'core 零出向（叶层不得反向依赖任何域）',
    from: <String>{'core'},
    forbiddenDomains: <String>{
      'app',
      'coordinator',
      'gateway',
      'gateway_api',
      'llm',
      'mcp',
      'resources',
      'sandbox',
      'task',
      'ui',
      'update',
    },
    hint: 'core 是叶层：跨域类型须下沉 core（DTO/端口），或改由上层注入',
  ),
  _Rule(
    id: 'R2',
    name: 'mcp / sandbox 不反向依赖 coordinator',
    from: <String>{'mcp', 'sandbox'},
    forbiddenDomains: <String>{'coordinator'},
    hint: '应经 mcp/connection_face.dart 注入；共享类型下沉 core/tool_result.dart、'
        '审计走 core/audit_sink.dart 端口',
  ),
  _Rule(
    id: 'R3',
    name: 'mcp / sandbox 不反向依赖 llm',
    from: <String>{'mcp', 'sandbox'},
    forbiddenDomains: <String>{'llm'},
    hint: 'sampling 走 SamplingEngine 端口（货币 core/chat_message_data.dart）；'
        'transcript 编解码属 llm/cloud/chat_message_codec.dart，存储层只认 JSON Map',
  ),
  _Rule(
    id: 'R4',
    name: 'ui 不直接 import gateway/gateway_controller（断点① ui→gateway 斩断）',
    from: <String>{'ui'},
    forbiddenUriPatterns: <String>['gateway/gateway_controller'],
    hint: 'ui 应经 lib/gateway_api/gateway_control 间接依赖网关',
  ),
  _Rule(
    id: 'R5',
    name: 'gateway 不 import ui（防 gateway→ui 反向边复燃）',
    from: <String>{'gateway'},
    forbiddenDomains: <String>{'ui'},
    hint: 'Flutter 弹层已迁 ui/gateway_consent_dialog.dart，gateway 只留接口 + '
        'fail-closed',
  ),
  _Rule(
    id: 'R6',
    name: '生产不引用 lib/mcp/tool_router.dart（双 ToolRouter 不删不引）',
    from: <String>{},
    forbiddenUriPatterns: <String>['mcp/tool_router.dart'],
    exemptFiles: <String>{'mcp/tool_router.dart'},
    hint: 'SA-Q6 拍板「保留待接线」：海关过滤件不得被引用，生产路由只引 '
        'coordinator/tool_router.dart，防同名误导入',
  ),
];


// —— F16（review-fix-2026-10）：域级正向出向枚举（白名单制）——
// 规则表 R1~R6 是「已知坏边黑名单」，新文件落错域不报警；本表镜像
// coding-standards.md §1.0 分层矩阵的**允许出向**（改矩阵须同轮改此表），
// 清单外任何域级出向即违例。
const Map<String, Set<String>> kAllowedDomainEdges = <String, Set<String>>{
  'core': <String>{}, // 叶层零出向
  'llm': <String>{'core', 'mcp'}, // mcp = SamplingEngine 端口实现（依赖倒置）
  'mcp': <String>{'core'},
  'sandbox': <String>{'core'},
  'task': <String>{'mcp', 'core'},
  'resources': <String>{'core'},
  'app': <String>{'mcp', 'coordinator', 'task', 'llm', 'resources'},
  'coordinator': <String>{'core', 'llm', 'mcp', 'sandbox', 'task', 'resources'},
  'gateway': <String>{'coordinator', 'mcp', 'llm', 'sandbox', 'app'},
  'gateway_api': <String>{'gateway', 'coordinator', 'mcp'},
  'ui': <String>{'coordinator', 'core', 'app', 'gateway', 'gateway_api', 'update'},
  'update': <String>{}, // 独立叶子域
};

/// ui 对 mcp/sandbox/llm 的**文件级**白名单镜像（index.md「直连白名单基线」，
/// 只减不增；清单外 ui 文件引这三域即违例——§1.4 类别 4）。
const Map<String, Set<String>> kUiDirectLinkWhitelist = <String, Set<String>>{
  'ui/settings_page.dart': <String>{'mcp', 'llm'},
  'ui/sections/byok_section.dart': <String>{'llm'},
  'ui/sections/nodes_section.dart': <String>{'mcp'},
  'ui/sections/local_plugins_section.dart': <String>{'mcp'},
  'ui/memory_board_page.dart': <String>{'sandbox'},
  'ui/resource_center_page.dart': <String>{'mcp'},
  'ui/trust_plugin_dialog.dart': <String>{'mcp'},
  'ui/components/server_endpoint_forms.dart': <String>{'mcp'},
  'ui/chat_page.dart': <String>{'llm', 'mcp', 'sandbox'},
  'ui/components/conversation_drawer.dart': <String>{'sandbox'},
  'ui/components/session_context_sheet.dart': <String>{'mcp'},
  'ui/components/dual_track_stream.dart': <String>{'mcp'},
  'ui/components/chat_gate_delegates.dart': <String>{'mcp'},
  'ui/components/elicitation_card.dart': <String>{'mcp'},
  'ui/gateway_loop_debug_page.dart': <String>{'llm', 'mcp'}, // 联调豁免（§1.4 类别 3）
  // F16 账实补登（2026-10-24 正向矩阵首轮实证的漏登边）：
  'ui/sections/resource_center_section.dart': <String>{'resources'},
  'ui/sections/task_ledger_section.dart': <String>{'task'},
};

/// gateway → coordinator 执行面白名单（index.md §1.4 类别 5，默认拒绝）：
/// gateway 只许 import 这 9 件；coordinator 新文件默认对 gateway 不可见。
const Set<String> kGatewayCoordinatorAllowlist = <String>{
  'coordinator/agent_loop.dart',
  'coordinator/mcp_runtime.dart',
  'coordinator/mcp_tool_face.dart',
  'coordinator/permission_gateway.dart',
  'coordinator/pii_fence.dart',
  'coordinator/hybrid_assembly.dart',
  'coordinator/ref_store.dart',
  'coordinator/tool_router.dart',
  'coordinator/host_tool_invoker.dart',
};

void main() {
  final refs = _collectRefs('lib');

  group('依赖护栏（反向边纪律）', () {
    for (final rule in _kDependencyRules) {
      test('${rule.id} ${rule.name}', () {
        final violations = rule.violations(refs);
        expect(
          violations,
          isEmpty,
          reason: '${rule.hint}；violations=$violations',
        );
      });
    }

    test('扫描器确实扫到了东西（防空集假绿）', () {
      expect(refs.length, greaterThan(100),
          reason: 'lib/ 引用条数异常偏少，扫描器可能失效');
      expect(
        refs.where((r) => r.to != null).length,
        greaterThan(30),
        reason: '跨域引用条数异常偏少，域解析可能失效',
      );
    });
  });

  group('扫描器自身正确性（金丝雀）', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('arch_guard_canary'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    void write(String rel, String body) {
      final f = File('${tmp.path}/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(body);
    }

    test('能抓到折行 import、export 转发与 package: 写法', () {
      write('lib/sandbox/leak.dart', '''
library;
import '../coordinator/agent_loop.dart'
    show AgentLoop;
export '../llm/cloud/cloud_llm.dart';
import 'package:goodhub/coordinator/tool_router.dart';
''');
      final local = _collectRefs('${tmp.path}/lib');
      final sandboxToCoordinator =
          _kDependencyRules.firstWhere((r) => r.id == 'R2').violations(local);
      final sandboxToLlm =
          _kDependencyRules.firstWhere((r) => r.id == 'R3').violations(local);
      expect(sandboxToCoordinator, hasLength(2),
          reason: '折行 import + package: 写法须都被抓到');
      expect(sandboxToLlm, hasLength(1), reason: 'export 转发须被抓到');
    });

    test('不误报注释里的 import 文本与同域内部引用', () {
      write('lib/mcp/ok.dart', '''
library;
// import '../coordinator/agent_loop.dart';
/// 设计见 coordinator/tool_router.dart，实现在 llm/cloud/sampling_engine.dart
/* import '../llm/cloud/cloud_llm.dart'; */
import 'tool_router.dart';
import '../core/errors.dart';
''');
      final local = _collectRefs('${tmp.path}/lib');
      for (final rule in _kDependencyRules) {
        expect(rule.violations(local), isEmpty,
            reason: '${rule.id} 误报：${rule.violations(local)}');
      }
    });

    test('R6 对 mcp/tool_router.dart 自身豁免、对其余域一律拦截', () {
      write('lib/mcp/tool_router.dart', 'library;\n');
      write('lib/coordinator/bad.dart', "import '../mcp/tool_router.dart';\n");
      final local = _collectRefs('${tmp.path}/lib');
      final r6 = _kDependencyRules.firstWhere((r) => r.id == 'R6');
      expect(r6.violations(local).map((v) => v.file), <String>['coordinator/bad.dart']);
    });
  });

  // F16：正向白名单——域级出向必须落在矩阵允许集内；ui→mcp/sandbox/llm 与
  // gateway→coordinator 两处走文件级白名单（镜像 index.md 基线）。撤表即红。
  group('F16 正向出向枚举（域级白名单制）', () {
    test('所有域级出向都在 §1.0 矩阵允许集内（清单外即违例）', () {
      final violations = <String>[];
      for (final r in refs) {
        if (r.from.isEmpty) continue; // main.dart 装配入口（矩阵立法例外）
        if (r.to == null || r.to!.isEmpty || r.to == r.from) continue; // 外部包/同域内部不出矩阵
        final allowed =
            kAllowedDomainEdges[r.from] ?? const <String>{};
        if (allowed.contains(r.to)) continue;
        // 文件级例外：ui 直连白名单（§1.4 类别 1/3/4）。
        final uiExtra = kUiDirectLinkWhitelist[r.file];
        if (uiExtra != null && uiExtra.contains(r.to)) continue;
        // gateway → coordinator 执行面白名单（§1.4 类别 5）。
        if (r.from == 'gateway' && r.to == 'coordinator') {
          final seg = r.uri
              .replaceFirst('../', '')
              .replaceFirst('package:goodhub/', '');
          if (kGatewayCoordinatorAllowlist.contains(seg)) continue;
          violations.add(
              'gateway→coordinator 清单外执行面: ${r.file} → ${r.uri}');
          continue;
        }
        violations.add(
            '${r.from} → ${r.to} 不在允许矩阵: ${r.file} → ${r.uri}');
      }
      expect(violations, isEmpty,
          reason: 'F16：域级出向白名单制（矩阵见 coding-standards §1.0 + 本表）');
    });

    test('金丝雀：矩阵确实会拦清单外边（防空转假绿）', () {
      const r = _Ref(from: 'task', to: 'coordinator', file: 'task/x.dart', uri: '../coordinator/y.dart');
      final allowed = kAllowedDomainEdges[r.from] ?? const <String>{};
      expect(allowed.contains(r.to), isFalse,
          reason: 'task 只许出向 mcp——若本断言红，说明矩阵表失守');
    });
  });
}
