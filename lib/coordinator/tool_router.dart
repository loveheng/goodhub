/// ToolRouter——多 Server 前缀隔离路由注册表（M4-T6，F1.2）。
/// 规格 SSOT：architecture.md §1（ToolRouter 命名空间前缀隔离）/§7（JIT 二级
/// 元工具）/§14（Tier 协商）+ M4 施工设计 T6 注记。
///
/// - **不是装饰器**：直接持 `Map<serverId, McpToolFace>`；对外工具名
///   `<serverId>__<toolName>`（coding-standards §5.6：双下划线仅分隔符，各段
///   自身不含 `__`），[execute] 剥前缀路由——face 收裸名，server 侧零感知；
/// - **激活集会话粒度**（§15）：router 实例随会话建；未激活 server 的调用
///   → isError 引导先 `activate_server_tools`（幻觉调用防线 + N2 常驻开销
///   恒定的守门面——未激活工具不进 tools 列表，双保险）；
/// - **serverFor**：前缀名 → 来源 serverId（AgentLoop put 端 `$ref` 句柄
///   来源解析用；宿主本地工具名无前缀返回 null——本地结果不落池语义由调用
///   方维持 M2 引用标记形态）；
/// - 路由目标缺失（server 掉线未从注册表摘除）→ isError 不抛穿执行环。
library;

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'mcp_tool_face.dart';

/// 前缀分隔符（coding-standards §5.6：双下划线仅作两段分隔符）。
const String kToolNamespaceSep = '__';

/// 拆 `<serverId>__<toolName>`；不合规（无分隔符/空段）返回 null。
({String serverId, String toolName})? parsePrefixedToolName(String name) {
  final i = name.indexOf(kToolNamespaceSep);
  if (i <= 0 || i == name.length - kToolNamespaceSep.length) return null;
  final serverId = name.substring(0, i);
  final toolName = name.substring(i + kToolNamespaceSep.length);
  if (serverId.contains(kToolNamespaceSep) || toolName.contains(kToolNamespaceSep)) {
    return null;
  }
  return (serverId: serverId, toolName: toolName);
}

class ToolRouter implements ToolExecutor {
  ToolRouter({required Map<String, McpToolFace> faces,
      Set<String> privateServerIds = const {}})
      : _faces = Map.of(faces),
        privateServerIds = Set.of(privateServerIds);

  final Map<String, McpToolFace> _faces;

  /// 私有服务 id 集（Provider×Tier 两维，P1-4 / SSOT §1.6）：由装配层按
  /// `ServerEndpoint.tier` 注入；不在集内 = public（缺省公共，沉默即公共面）。
  final Set<String> privateServerIds;

  /// 已激活 server 集（会话粒度——实例随会话建；JIT 元工具写，T6-3 接线）。
  /// 新模型下只收 public 挂载；private 走 [activePrivateServerId] 槽位。
  final Set<String> activatedServers = {};

  /// 单一私有槽位（D-C）：私有+私有互斥由本槽位构造保证——抢占即替换，无需
  /// 额外闸门；null = 当前无激活私有域。public 不进槽位（常驻）。
  ///
  /// **写入纪律（prompt-mgmt §8.2）**：执行环内不直接写本字段——use_server 经
  /// [requestSlot] 写 pending，提交点在 ToolResultMessage 落历史之后
  /// （[commitPendingSlot]）；Run 内消费走 [effectiveSlot] 快照；断连降级经
  /// [markPrivateServerOffline] 只写 pending 标记，Run 边界收敛。
  String? activePrivateServerId;

  // ---- Run 边界快照隔离（prompt-mgmt §8.2.1）----
  // 正在执行的 Run 内部始终消费其启动时捕获的不可变槽位快照，严禁 Run 中途
  // 变异造成状态撕裂（tools 尾块与 system skill 尾块同拍同源）。

  String? _runSlot;
  bool _hasRunSlot = false;

  // ---- pending 切域事务（§8.2.2 提交点 = ToolResultMessage 落历史之后）----

  String? _pendingSlot;
  bool _hasPending = false;

  // ---- 断连降级 pending 标记（§8.2.1 僵尸槽位自愈）----

  bool _pendingSlotInvalid = false;

  /// 生效槽位：Run 内恒为启动快照（防 Run 中途变异撕裂）；Run 外 = 活跃槽位。
  String? get effectiveSlot => _hasRunSlot ? _runSlot : activePrivateServerId;

  /// Run 边界收敛 + 快照捕获（编排件 plan() 启动时调用）：① 断连 pending
  /// 标记生效——激活私有已掉线且无更新切域请求 → 槽位置 null（僵尸槽位自愈，
  /// 下一 Run 纯公共模式）；② 应用未提交切域 pending（正常路径已在提交点
  /// 收敛，此处只兜底 Run 末未提交的场景不残留）；③ 捕获本 Run 槽位快照。
  /// 返回降级通告文本（null = 无降级）。
  String? beginRun() {
    String? notice;
    if (_pendingSlotInvalid) {
      final current = activePrivateServerId;
      if (_hasPending) {
        // 显式切域请求优先：提交到新槽位（新槽存活与否由下一 Run 实测）。
        activePrivateServerId = _pendingSlot;
      } else if (current != null) {
        activePrivateServerId = null;
        notice = '⚠ 私有服务 $current 已掉线，本会话降级纯公共模式'
            '（私有工具面已摘除，恢复后需重新 use_server）';
      }
      _hasPending = false;
      _pendingSlot = null;
      _pendingSlotInvalid = false;
    } else if (_hasPending) {
      activePrivateServerId = _pendingSlot;
      _hasPending = false;
      _pendingSlot = null;
    }
    _runSlot = activePrivateServerId;
    _hasRunSlot = true;
    return notice;
  }

  /// Run 收尾：丢弃快照与未提交 pending（提交前 Abort → 槽位保持原状）。
  void endRun() {
    _hasRunSlot = false;
    _runSlot = null;
    _hasPending = false;
    _pendingSlot = null;
  }

  /// use_server/activate 的槽位请求入口（DiscoveryExecutor 调）：只写 pending，
  /// 不动活跃槽位——提交点 [commitPendingSlot] 由装配层挂在 AgentLoop
  /// 「ToolResultMessage 落历史之后」。null = 清空槽位（use_server "all"）。
  void requestSlot(String? serverId) {
    _pendingSlot = serverId;
    _hasPending = true;
  }

  /// 切域事务提交点：已 pending 的槽位请求落到活跃槽位。由 AgentLoop 在
  /// ToolResultMessage 全量回填进历史后调用；提交前取消/失败不调用本方法
  /// （pending 随 [endRun] 丢弃），提交后取消/失败不回滚（切换是显式意图）。
  void commitPendingSlot() {
    if (!_hasPending) return;
    activePrivateServerId = _pendingSlot;
    _hasPending = false;
    _pendingSlot = null;
    _pendingSlotInvalid = false; // 新槽位 = 显式意图，撤销僵尸降级标记
  }

  /// 断连联动（§8.2.1）：掉线的是当前激活私有服务 → 只写 pending 降级标记，
  /// Run 边界（[beginRun]）统一收敛生效——正在执行的 Run 快照不受影响；
  /// 禁幽灵上下文（死服务的 prompt + 空工具继续注入）。
  void markPrivateServerOffline(String serverId) {
    if (activePrivateServerId == serverId &&
        !_hasPending &&
        !_pendingSlotInvalid) {
      _pendingSlotInvalid = true;
    }
  }

  int get serverCount => _faces.length;
  List<String> get serverIds => _faces.keys.toList(growable: false);
  McpToolFace? faceOf(String serverId) => _faces[serverId];

  /// 前缀化工具名（装配层下发 tools 列表与 loadCatalog 用）。
  static String prefixed(String serverId, String toolName) =>
      '$serverId$kToolNamespaceSep$toolName';

  /// 前缀名 → 来源 serverId；宿主本地工具（无前缀）→ null。
  String? serverFor(String prefixedName) =>
      parsePrefixedToolName(prefixedName)?.serverId;

  /// 某服务的前缀化 schema 列表（face.listTools 结果 + 前缀改写；annotations
  /// 原样保留——网关 hint 按 `serverId__tool` 查询）。
  List<CloudToolSchema> schemasFor(String serverId) {
    final face = _faces[serverId];
    if (face == null) return const [];
    return face.cachedSchemas
        .map((s) => CloudToolSchema(
              name: prefixed(serverId, s.name),
              description: s.description,
              parametersSchema: s.parametersSchema,
              annotations: s.annotations,
            ))
        .toList(growable: false);
  }

  /// 全部服务的激活前缀化 schema（JIT 激活后下发面；T6-3 消费）。
  List<CloudToolSchema> activatedSchemas() => [
        for (final id in activatedServers) ...schemasFor(id),
      ];

  /// 工具面三段式确定序（P1-4 / SSOT §7.4 / §8.2）：
  /// `[全部 public 按 (serverId, toolName) 排序] → [单一 active private 尾部]`
  /// ——公共前缀恒定命中缓存，切换私有域只重排尾部块（meta/skill/memory
  /// 固定尾由装配层在 router 之外追加）。槽位读 [effectiveSlot]（Run 内 = 启动
  /// 快照，与 composeSystemPrompt 同源同拍）。
  List<CloudToolSchema> focusedSchemas() {
    final publics = [
      for (final id in _faces.keys
          .where((id) => !privateServerIds.contains(id))
          .toList()
            ..sort())
        ..._sortedSchemasFor(id),
    ];
    final priv = effectiveSlot;
    if (priv == null || !_faces.containsKey(priv)) return publics;
    return [...publics, ..._sortedSchemasFor(priv)];
  }

  /// 单服务 schema 按 toolName 字典序固定（上游 tools/list 返回序不可控）。
  List<CloudToolSchema> _sortedSchemasFor(String serverId) {
    final list = schemasFor(serverId).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    final parsed = parsePrefixedToolName(call.name);
    if (parsed == null) {
      return ToolExecutionResult(
        content: '工具名 ${call.name} 不含 $kToolNamespaceSep 服务前缀——'
            '服务工具经 get_connected_apps 查看并用 activate_server_tools 激活',
        isError: true,
      );
    }
    final face = _faces[parsed.serverId];
    if (face == null) {
      return ToolExecutionResult(
        content: '服务 ${parsed.serverId} 未挂载（可能离线）——'
            '用 get_connected_apps 查看当前可用服务',
        isError: true,
      );
    }
    if (!privateServerIds.contains(parsed.serverId)) {
      // public 常驻（§1.6）：仅保留激活集守门（挂载即默认全激活）。
      if (!activatedServers.contains(parsed.serverId)) {
        return ToolExecutionResult(
          content: '服务 ${parsed.serverId} 未激活——'
              '先调用 activate_server_tools(server_id: "${parsed.serverId}") '
              '加载其工具，再重试',
          isError: true,
        );
      }
    } else if (effectiveSlot != parsed.serverId) {
      // 私有槽位门控（D-C）：未占槽 / 被其他私有域抢占 → 引导 use_server。
      // 读快照：Run 内新切域的私有工具下一 Run 才进面，本 Run 幻觉调用被拦。
      final holder = effectiveSlot;
      return ToolExecutionResult(
        content: holder == null
            ? '私有服务 ${parsed.serverId} 未激活——'
                '用 use_server(server_id: "${parsed.serverId}") 占用私有槽位'
            : '私有槽位当前由 $holder 占用（单一私有域独占），'
                '不可调用 ${parsed.serverId}——'
                '先 use_server(server_id: "${parsed.serverId}") 抢占槽位，'
                '或 use_server(server_id: "all") 清空',
        isError: true,
      );
    }
    final bare = AssembledToolCall(
      id: call.id,
      name: parsed.toolName,
      argumentsJson: call.argumentsJson,
    );
    return face.execute(bare);
  }
}
