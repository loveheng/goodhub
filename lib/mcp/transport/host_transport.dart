/// 宿主虚拟服务传输（`serverId='host'`）——把宿主原生能力伪装成标准 MCP 服务。
///
/// 设计 SSOT：`docs/design/host-tools-gateway-export.md`。装配链
/// `HostTransport implements McpTransport` → `McpClient` → `McpRuntime.mount`
/// → `faces['host']`，复用既有挂载原语，网关核心分流零改动。
///
/// **域边界（arch-guard R5/R6 红灯）**：本件住 `mcp/` 域，只准 import `core/`
/// ——宿主工具执行面经 [HostToolInvoker] 端口注入（生产实现住 `coordinator/`
/// 执行链），**严禁**反向 import `coordinator/`（`ToolExecutor` /
/// `DiscoveryExecutor` / `ToolRouter` 等）或 `llm/`（`CloudToolSchema`）；
/// 故本文件自造 JSON 级的工具声明形状，不复用 llm 域 schema 类型。
///
/// **生命周期 Owner 契约**（§1.1 规则 6）：本传输由装配方创建并持有，**无独立
/// dispose**（无 socket / 无 Timer / 无订阅通道）；释放唯一入口 = owner 调
/// `client.close()`（幂等），[close] 只翻守卫标志。
library;

import 'dart:async';
import 'dart:convert' as json;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/tool_result.dart';
import '../../core/tool_visibility.dart';
import '../server_capabilities.dart' show kMcpProtocolVersion;
import 'mcp_transport.dart';

/// 宿主虚拟服务的系统保留 serverId（`host__` 前缀的唯一归属方）。
///
/// 保留字防护见 `coordinator/reserved_namespace.dart` 的 `assertServerIdMountable`
/// （架构债 #15）：`host`
/// 仅限内置 [HostTransport] 装配，外部插件 / 手填端点声明即拒装。
const String kHostServerId = 'host';

/// 工具名两段分隔符（与 `coordinator/tool_router.dart` 的 `kToolNamespaceSep`
/// 同字面量；mcp 域不得 import coordinator，故本地声明 + 单测同步断言防漂移）。
const String _kNameSep = '__';

/// 单条宿主导出登记项（Allowlist 一行）。
///
/// 登记纪律（设计稿「Host 导出 Allowlist」）：
/// - 工具名与本机 executor 一致（**无前缀**；禁含 [kHostServerId] 之外的
///   `__` 结构分隔符——保底 = 单测断言，不落运行期 throw）；
/// - [annotations] 须显式声明 `readOnlyHint` / `destructiveHint` 其一，未声明
///   由门禁 1 强置 `destructiveHint: true`（防 L1 静默放行）；
/// - [visibility] 拟对 PC 暴露者必须 [ToolVisibility.shared]（缺省即 private →
///   不进投影，缺失即保守）；
/// - [tags] 供 `pruned` 保守白名单拾取（**未打标一律剔除**）。
class HostExportEntry {
  const HostExportEntry({
    required this.name,
    this.description,
    this.inputSchema,
    this.annotations,
    this.visibility = ToolVisibility.shared,
    this.tags = const <String>[],
  });

  /// 裸工具名（与本机 executor 一致，不带 `host__` 前缀）。
  final String name;

  /// 工具描述（coding-standards §5.1：写「怎么用才对」，非空泛说明）。
  ///
  /// **可省**：默认 owner 是宿主 executor（§5.6 文件名↔类型 + 单一 owner），
  /// 由装配层经 [HostSchemaResolver] 从执行面取——登记表只声明**导出策略**
  /// （谁能导出/什么可见性/什么 tag），不复制一份 schema 文本（禁双源漂移）。
  /// 仅当执行器未提供时才回落本字段（留空则回 '（宿主工具）' 占位）。
  final String? description;

  /// JSON Schema（`inputSchema` 原文）；同上，可省并由执行器提供。
  final Map<String, Object?>? inputSchema;

  /// MCP annotations 原文；null / 未声明读写 hint → 门禁 1 强置破坏性。
  final Map<String, Object?>? annotations;

  /// 对外可见性（`_meta.goodhub.visibility`）。
  final ToolVisibility visibility;

  /// `pruned` 策略的 tag 白名单键（`_meta.goodhub.tags`）。
  final List<String> tags;
}

/// 宿主导出静态注册表：**未登记者一律不对外导出**（留在本机 ToolRouter，
/// 本机照常可用）。严禁把宿主 executor 全量透传。
///
/// **登记表只声明「导出策略」，不复制 schema 文本**：条目不带
/// `description` / `inputSchema` 时由 `HostSchemaResolver` 从宿主执行面取
/// （owner = 执行器，见 `host_status_tool.dart`）——单一 owner，禁双源漂移。
///
/// 登记新项须同轮过三关：① 产品价值（对 PC 确有推理增益，非空操作工具）
/// ② 隐私影响评估 ③ 单测断言「至少一个 shared 且 `readOnlyHint: true` 的条目」。
const List<HostExportEntry> kHostExportAllowlist = <HostExportEntry>[
  // 宿主环境事实只读工具（首项，2026-10-23）：零隐私 + 有真实推理增益
  // （PC 据此对齐语言/时区/协议版本），非 host_ping 类占位工具。
  // schema 与描述由 `HostStatusToolExecutor` 单点拥有。
  HostExportEntry(
    name: 'get_host_status',
    annotations: <String, Object?>{'readOnlyHint': true},
    visibility: ToolVisibility.shared,
    tags: <String>['core'],
  ),
];

/// 控制面原语黑名单：宿主 JIT 元工具，**合成 `tools/list` 前强制剔除、
/// `tools/call` 显式拒绝**——PC 不得经网关改写宿主私有槽位 / 激活集
/// （私有投影切换的正道是 `gateway__select_private`，见
/// `docs/design/thirdconnect.md` §7）。
///
/// 字面量来源 = `coordinator/discovery_executor.dart` 的 `getConnectedApps` /
/// `activateServerTools` / `useServer`（mcp 域不得 import coordinator，故本地
/// 声明 + 单测同步断言防漂移）。
const Set<String> kHostControlPlaneTools = <String>{
  'get_connected_apps',
  'activate_server_tools',
  'use_server',
};

/// 宿主工具执行端口（**消费方域内定义的最小能力集**，§1.1 规则 6）：入参裸
/// 工具名 + 原始入参 JSON 串，回 core 层通用货币 [ToolExecutionResult]。
///
/// 注入位（`invoker`）：生产实现由装配方持有宿主执行链（`ToolExecutor`）并
/// 做 tearoff 适配——本传输不感知 coordinator 的执行面类型。
typedef HostToolInvoker = Future<ToolExecutionResult> Function({
  required String name,
  required String argumentsJson,
});

/// 宿主工具 schema 解析端口（**owner = 宿主执行面**，装配层接线）：按裸工具名
/// 返回 `{'description': String, 'inputSchema': Map}` 原文，或 null（该工具不在
/// 执行面上）。
///
/// 存在理由：登记表只声明导出策略，schema/描述由执行器单点拥有（§5.1 描述引导
/// 与 §5.7 契约测试都住在执行器侧）——mcp 域禁 import coordinator，故经本端口
/// 反向取，避免在 Allowlist 里复制一份必然漂移的 schema 文本。
typedef HostSchemaResolver = Map<String, Object?>? Function(String toolName);

/// 宿主虚拟服务传输：进程内直调宿主 executor 的 MCP 服务端形态。
///
/// 支持面：`initialize` / `tools/list` / `tools/call` / `ping`（+ 通知帧静默
/// 吞掉）。**无 GET SSE 订阅通道**（宿主不提供 resources/subscribe），
/// [getStream] 按 Binder 同口径抛 [UnsupportedError]，协议层退化为不监听。
class HostTransport implements McpTransport {
  HostTransport({
    required this.invoker,
    this.allowlist = kHostExportAllowlist,
    this.schemaResolver,
  });

  /// 宿主工具执行端口（注入位；生产 = 宿主执行链 tearoff）。
  final HostToolInvoker invoker;

  /// 宿主工具 schema 解析端口（注入位；生产 = 执行面，装配层接线）。
  final HostSchemaResolver? schemaResolver;

  /// 导出 Allowlist（默认 = [kHostExportAllowlist]；测试可注入自定义表）。
  final List<HostExportEntry> allowlist;

  /// `serverInfo.name`（合成面自报身份，网关侧仅作诊断展示）。
  static const String serverName = 'goodhub-host';

  /// `serverInfo.version`（与既有 `McpClient` clientInfo 同口径的固定串）。
  static const String serverVersion = '0.1.0';

  bool _closed = false;

  /// 登记项索引（惰性建表；[allowlist] 为 final，构造后不变）。
  late final Map<String, HostExportEntry> _index =
      <String, HostExportEntry>{for (final e in allowlist) e.name: e};

  /// 合成工具面（`tools/list` 的数据源；单测与调试可直读）。
  ///
  /// 合成期两道剔除：① 控制面原语黑名单 ② 工具名含结构分隔符 `__` 的畸形
  /// 登记项（登记纪律的运行期留痕，**不抛**——权威保底是单测断言）。
  List<Map<String, Object?>> get exportedTools {
    final out = <Map<String, Object?>>[];
    for (final e in allowlist) {
      if (kHostControlPlaneTools.contains(e.name)) {
        debugPrint(
            '[DEGRADE] host-transport: 剔除控制面原语 ${e.name}（不对外导出）');
        continue;
      }
      if (e.name.contains(_kNameSep)) {
        debugPrint('[DEGRADE] host-transport: 剔除畸形登记名 ${e.name}'
            '（工具名禁含 $_kNameSep，仅作两段分隔符）');
        continue;
      }
      out.add(_entryJson(e));
    }
    return List<Map<String, Object?>>.unmodifiable(out);
  }

  @override
  Future<TransportResponse> send(String requestBody) async {
    if (_closed) throw StateError('HostTransport 已关闭（生命周期归 owner）');
    final Object? decoded;
    try {
      decoded = json.jsonDecode(requestBody);
    } on FormatException catch (e) {
      return _error(null, -32700, 'Parse error: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      return _error(null, -32600, 'Invalid Request: 请求体非 JSON object');
    }
    final id = decoded['id'];
    final method = decoded['method'];
    if (method is! String || method.isEmpty) {
      return _error(id, -32600, 'Invalid Request: 缺少 method');
    }
    if (id == null) {
      // 通知帧（`notifications/initialized` / `notifications/cancelled`）：
      // 无 id → 无响应体（`McpClient.call` 空体返 null，`notify` 收 202）。
      debugPrint('[host-transport] 忽略通知帧 $method');
      return const TransportResponse(statusCode: 202, contentType: '', body: '');
    }
    return switch (method) {
      'initialize' => _ok(id, _initializeResult()),
      'tools/list' => _ok(id, _toolsListResult()),
      'tools/call' => _callTool(id, decoded['params']),
      'ping' => _ok(id, const <String, Object?>{}),
      _ => _error(id, -32601, 'Method not found: $method'),
    };
  }

  /// 流式调用（`McpClient.callWithProgress`）：宿主工具无 progress 语义，
  /// 按 Binder 同款 Polyfill 口径回**单帧**（`text/event-stream` 帧封装），
  /// 空体（如通知）走非 SSE 回退路径由协议层判空返回。
  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final resp = await send(requestBody);
    final body = resp.body.trim();
    if (body.isEmpty) {
      return StreamedTransportResponse(
        statusCode: resp.statusCode,
        contentType: 'application/json',
        lines: Stream<String>.value(''),
      );
    }
    return StreamedTransportResponse(
      statusCode: resp.statusCode,
      contentType: 'text/event-stream',
      // 末行空行不可省：SSE 断帧靠它flush（`callWithProgress` 逐行累积
      // `data:` 后遇空行才解帧——漏行即「流结束但无 result 帧」协议错）。
      lines: Stream<String>.fromIterable(['data: $body', '']),
    );
  }

  /// GET SSE 订阅通道：宿主虚拟服务不提供 `resources/subscribe`，无下行通道
  /// （同机进程内亦无需跨端推送）——按 Binder 口径抛 [UnsupportedError]，
  /// 协议层退化为不监听。
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('Host 虚拟服务无 GET SSE 订阅通道（宿主面静态注册表）');

  @override
  void close() => _closed = true;

  // ---- JSON-RPC 响应构造（Streamable HTTP：错误帧亦走 HTTP 200）----

  static TransportResponse _ok(Object? id, Map<String, Object?> result) =>
      TransportResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: json.jsonEncode(
            <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result}),
      );

  static TransportResponse _error(Object? id, int code, String message) =>
      TransportResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: json.jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{'code': code, 'message': message},
        }),
      );

  /// `initialize` 握手：**只声明 tools**——不声明 `sampling`（宿主不供给反向
  /// 请求面，否则 `McpToolFace` 会强制走流式调用）、不声明 `resources`
  /// （无订阅能力 → 协议层不建 GET SSE 监听）。
  Map<String, Object?> _initializeResult() => <String, Object?>{
        'protocolVersion': kMcpProtocolVersion,
        'capabilities': <String, Object?>{
          // listChanged=false：导出面由静态 Allowlist 决定，运行期不变。
          'tools': <String, Object?>{'listChanged': false},
        },
        'serverInfo': <String, Object?>{
          'name': serverName,
          'version': serverVersion,
        },
        'instructions': '宿主原生能力虚拟服务（serverId=$kHostServerId）：'
            '工具面以宿主导出 Allowlist 为准（未登记者不对外提供）；'
            '只读工具静默放行，破坏性工具须经宿主确认卡裁决。',
      };

  Map<String, Object?> _toolsListResult() {
    final tools = exportedTools;
    if (tools.isEmpty) {
      // 空面在 MCP 下合法（返回空数组），仅 DEGRADE 留痕不报错。
      debugPrint('[DEGRADE] host-transport: 导出工具面为空'
          '（kHostExportAllowlist 无有效登记；本机 ToolRouter 不受影响）');
    }
    return <String, Object?>{'tools': tools};
  }

  /// `tools/call`：进程内直调注入的宿主执行端口，结果包 MCP content 信封。
  Future<TransportResponse> _callTool(Object? id, Object? params) async {
    final name = params is Map ? params['name'] : null;
    if (name is! String || name.isEmpty) {
      return _error(id, -32602, 'Invalid params: tools/call 缺少 name');
    }
    if (kHostControlPlaneTools.contains(name)) {
      return _error(id, -32602,
          'Invalid params: $name 是宿主控制面原语，不经网关导出'
          '（私有投影切换请用 gateway__select_private）');
    }
    if (name.contains(_kNameSep)) {
      return _error(id, -32602,
          'Invalid params: 工具名 $name 含 $_kNameSep——本服务只接裸名，'
          '带前缀的调用应由网关投影层改写');
    }
    if (!_index.containsKey(name)) {
      return _error(id, -32602,
          'Invalid params: 工具 $name 未在宿主导出 Allowlist 登记，不对外提供');
    }
    final args = params is Map ? params['arguments'] : null;
    if (args != null && args is! Map) {
      return _error(id, -32602, 'Invalid params: arguments 必须是 JSON object');
    }
    final String argumentsJson = args is Map ? json.jsonEncode(args) : '{}';
    final ToolExecutionResult result;
    try {
      result = await invoker(name: name, argumentsJson: argumentsJson);
    } on Object catch (e) {
      // 工具级失败 = content 信封 + isError（协议错误留给上面的名字级判定）；
      // 宿主内部异常不外泄栈信息给 PC（§5.4：禁底层异常裸漏到 MCP 层）。
      debugPrint('[DEGRADE] host-transport: 宿主工具 $name 执行异常: $e');
      return _ok(id, _toolContent('宿主工具 $name 执行失败（宿主内部错误）',
          isError: true));
    }
    return _ok(id, _toolContent(result.content, isError: result.isError));
  }

  static Map<String, Object?> _toolContent(String text, {required bool isError}) =>
      <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
        'isError': isError,
      };

  /// 登记项 → `tools/list` 条目：补齐 `_meta.goodhub`（visibility / tags），
  /// 使下游 [McpToolFace.listTools] 的可见性解析与 `pruned` 过滤有据可依。
  Map<String, Object?> _entryJson(HostExportEntry e) {
    final resolved = schemaResolver?.call(e.name);
    final desc = e.description ??
        (resolved?['description'] is String ? resolved!['description'] as String : null) ??
        '（宿主工具）';
    final schema = e.inputSchema ??
        (resolved?['inputSchema'] is Map
            ? (resolved!['inputSchema'] as Map).cast<String, Object?>()
            : null) ??
        const <String, Object?>{'type': 'object'};
    return <String, Object?>{
        'name': e.name,
        'description': desc,
        'inputSchema': schema,
        'annotations': _effectiveAnnotations(e.annotations),
        '_meta': <String, Object?>{
          kToolMetaGoodhubNamespace: <String, Object?>{
            kToolVisibilityKey: e.visibility == ToolVisibility.shared
                ? 'shared'
                : 'private',
            if (e.tags.isNotEmpty) 'tags': e.tags,
          },
        },
      };
  }

  /// 门禁 1（annotations 强制声明）：宿主工具无 MCP annotations 来源，未显式
  /// 声明 `readOnlyHint` / `destructiveHint` 者一律强置 `destructiveHint: true`
  /// ——确保落 L2 确认卡（网关裁决「显式声明 → L2；未声明 → L1 静默放行」，
  /// 宿主工具严禁裸奔进 L1）。
  static Map<String, Object?> _effectiveAnnotations(Map<String, Object?>? raw) {
    final base = <String, Object?>{...?raw};
    if (base.containsKey('readOnlyHint') || base.containsKey('destructiveHint')) {
      return base;
    }
    return <String, Object?>{...base, 'destructiveHint': true};
  }
}