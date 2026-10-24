/// 网关工具面策略投影管道（host-tools-gateway-export PR2）。
///
/// 设计 SSOT：`docs/design/host-tools-gateway-export.md` §投影策略规范 / §会话
/// 绑定契约 / §过滤顺序铁律 / §single 入站前缀补齐。本文件是该章的**唯一实现**
/// ——纯函数 + 不可变值对象，无 IO、无状态、可独立单测；`GatewayHandler`
/// 只做接线（`toolsList` 投影 + `toolsCall` 入站判定），`McpGatewayServer`
/// 只做 `initialize` 期的策略绑定。
///
/// **四级单向铁律**（顺序不可调换）：visibility 海关 → 私有投影防火墙 →
/// 策略过滤 → 命名格式化。策略过滤若先于前两级，`single` 会成为绕开私有投影
/// 的后门，并产生「目录看得到、调用被拒」的不一致。
///
/// **结构化过滤铁律**：全流程在 `(serverId, face, schema)` 元组层做对象比对，
/// **禁止**在已拼装的 `name` 字符串上做 `startsWith` / 前缀剥离（那会让
/// `host__other__tool` 这类畸形名被 `parsePrefixedToolName` 判 null 而混入）。
library;

import '../coordinator/mcp_tool_face.dart';
import '../coordinator/tool_router.dart';
import '../llm/cloud/cloud_llm.dart';

/// 投影策略枚举（**字面量与 URL 参数同名**，唯一拼写）。
enum ProjectionStrategy {
  /// 全量 `visibility == shared` 工具，对外保留 `<serverId>__<tool>` 前缀。
  full,

  /// 跨服务聚合，但**仅含打上指定 tag 的工具**（保守白名单：未打标一律剔除）。
  pruned,

  /// 仅指定 serverId 的工具，对外**剥前缀**直出原生名；系统工具零泄漏。
  single,

  /// 完整联邦面 **+ 指定私有服务**（一轴化新增档：`policy=private`）。
  ///
  /// 与 [full] 的差别 = **私有叠加**：私有服务须由本连接显式绑定才进投影面
  /// （绑定只改本连接投影，不触碰宿主槽位机 → MO6「PC 无权改写宿主状态」）。
  private,

  /// 宿主内部档（**不经网关暴露**，仅 App 内链路构造）：机主全权视图——
  /// visibility 海关全豁免（private 工具照常进目录，对齐 ToolRouter
  /// focusedSchemas「声明而非访问控制」口径）、私有防火墙照常（由调用方传
  /// `activePrivateServerId` 表达会话绑定）、命名沿用前缀化。
  ///
  /// 「一个能力源、一个管道、多档策略」的机制归一：App 内视图 =
  /// `policy=owner` 的管道求值（2026-10-23 方向裁决）。**不可经 URL query /
  /// `gateway__select_private` 切入**（[ProjectionPolicy.parse] 显式拒绝）
  /// ——owner 等于对一切私有域免海关，泄露给 PC 即 MO6 崩塌。
  owner,
}

/// 策略参数违规（非法字面量 / 缺参 / 目标未挂载）——`initialize` 期 Fail-Fast
/// 抛该异常，由服务器层转 `-32602`，**严禁**静默初始化为空工具面。
class ProjectionPolicyException implements Exception {
  const ProjectionPolicyException(this.message);

  final String message;

  @override
  String toString() => 'ProjectionPolicyException: $message';
}

/// 会话绑定的投影策略（**不可变值对象**，随 `forSession(policy:)` 派生、
/// 随连接回收销毁）。
///
/// **会话内可被本连接改写**（2026-10-23 用户裁决）：`gateway__select_private(
/// policy=single|private|full)` 允许改写**本连接**的投影策略——改的是
/// per-connection 投影视图（随 `forSession` 派生、随连接回收销毁），与既有
/// `gateway__select_private` 同性质，**权限集合未扩张**；被禁的 `use_server`
/// 改的是宿主 `ToolRouter` 槽位机（跨 Run / 跨会话共享的宿主态），二者不同源。
class ProjectionPolicy {
  const ProjectionPolicy._({
    required this.strategy,
    this.targetServerId,
    this.tags = const <String>{},
  });

  /// 默认策略 = `full`（对既有 PC 客户端保持既有暴露面语义）。
  const ProjectionPolicy.full()
      : this._(strategy: ProjectionStrategy.full);

  /// `pruned` 策略（`?policy=pruned&tag=core`）：[tags] 为非空打标白名单集。
  factory ProjectionPolicy.pruned(Set<String> tags) {
    if (tags.isEmpty) {
      throw const ProjectionPolicyException(
          'policy=pruned 须带非空 tag（如 ?policy=pruned&tag=core）');
    }
    return ProjectionPolicy._(
        strategy: ProjectionStrategy.pruned, tags: Set.unmodifiable(tags));
  }

  /// `single` 策略（`?policy=single&server=host`）：仅 [targetServerId]。
  factory ProjectionPolicy.single(String targetServerId) {
    if (targetServerId.isEmpty) {
      throw const ProjectionPolicyException('policy=single 须带 server 参数');
    }
    return ProjectionPolicy._(
        strategy: ProjectionStrategy.single, targetServerId: targetServerId);
  }

  /// `private` 策略（`?policy=private&server=<私有服务>`）：完整联邦面 **+**
  /// 该私有服务（私有叠加仅对本连接生效，宿主槽位机不受影响）。
  factory ProjectionPolicy.private(String targetServerId) {
    if (targetServerId.isEmpty) {
      throw const ProjectionPolicyException('policy=private 须带 server 参数');
    }
    return ProjectionPolicy._(
        strategy: ProjectionStrategy.private, targetServerId: targetServerId);
  }

  /// `owner` 档（宿主内部，**无 URL 入口**）：机主全权视图——海关全豁免、
  /// 防火墙照常（`activePrivateServerId` 由调用方传会话绑定）。仅限 App 内
  /// 链路代码构造；[ProjectionPolicy.parse] 对网关侧显式拒绝该字面量。
  factory ProjectionPolicy.owner() =>
      const ProjectionPolicy._(strategy: ProjectionStrategy.owner);

  final ProjectionStrategy strategy;

  /// `single` 的目标服务 id（其余策略为 null）。
  final String? targetServerId;

  /// `pruned` 的 tag 白名单集（其余策略为空集）。
  final Set<String> tags;

  bool get isSingle => strategy == ProjectionStrategy.single;
  bool get isPruned => strategy == ProjectionStrategy.pruned;

  /// `private` 档（完整联邦面 + 指定私有服务）。
  bool get isPrivate => strategy == ProjectionStrategy.private;

  /// `owner` 档（宿主内部档，不经网关暴露）。
  bool get isOwner => strategy == ProjectionStrategy.owner;

  /// 从 `initialize` 请求的 URL query 解析投影策略（**绑定时机仅此一处**，
  /// 后续 `tools/list` / `tools/call` 一律忽略 URL 参数）。
  ///
  /// **单轴化（2026-10-23 用户裁决 D1）**：策略字面量取**并集**
  /// `single | private | full | pruned`，URL 键统一为 `policy`；旧键 `strategy`
  /// 作**兼容别名**保留（两者同传时 `policy` 优先），故既有 PC 客户端的
  /// `?strategy=single&server=…` 零改动继续工作。
  ///
  /// - [query]：通常取 `req.uri.queryParameters`；
  /// - [isAccessible]：目标 serverId 是否**可访问**的判定函数（注入位；
  ///   `single` / `private` 专用）。口径 = **已挂载**（生产注入
  ///   `faces.containsKey`）：私有服务**无需宿主先激活**——`single` 指向私有
  ///   服务时由服务器层做**连接级私有绑定**
  ///   （`forSession(activePrivateServerId: target)`），四级管道的私有投影
  ///   防火墙据此放行；故「未挂载」是唯一不可达情形，此时必须 Fail-Fast
  ///   （否则 PC 拿到**空目录且无提示**，设计稿 §Fail-Fast 明令禁止）。
  /// - [isPrivate]：目标 serverId 是否为**私有服务**（注入位；`private` 档
  ///   专用——私有叠加只对已配置的私有域开放）。
  ///
  /// 未知字面量 / `pruned` 缺 tag / `single`·`private` 缺 server / 目标未挂载 /
  /// `private` 目标非私有，一律抛 [ProjectionPolicyException]（不猜、不静默
  /// 降级到 `full`）。
  factory ProjectionPolicy.parse(
    Map<String, String> query, {
    required bool Function(String serverId) isAccessible,
    bool Function(String serverId)? isPrivate,
  }) {
    // 兼容别名：`policy` 为主键，`strategy` 为旧键（两者同传时 `policy` 优先）。
    final raw = (query['policy'] ?? query['strategy'])?.trim();
    if (raw == null || raw.isEmpty) return const ProjectionPolicy.full();
    switch (raw) {
      case 'full':
        return const ProjectionPolicy.full();
      case 'pruned':
        final tags = <String>{
          for (final t in (query['tag'] ?? '').split(','))
            if (t.trim().isNotEmpty) t.trim(),
        };
        return ProjectionPolicy.pruned(tags);
      case 'single':
        final target = (query['server'] ?? '').trim();
        if (target.isEmpty) {
          throw const ProjectionPolicyException('policy=single 须带 server 参数');
        }
        if (!isAccessible(target)) {
          // 唯一不可达情形 = 该服务当前**未挂载**（私有服务不走此路：私有服务
          // 经连接级绑定即可见可调，无需宿主先激活）。措辞只说「未挂载」——
          // 按旧口径写「须宿主先激活」会把 PC 侧排障支到一条不存在的路上。
          throw ProjectionPolicyException(
              'target server not found: $target'
              '（该服务当前未挂载——私有服务无需宿主先激活；'
              '请先调 gateway__list_servers 查看已挂载服务再重连）');
        }
        return ProjectionPolicy.single(target);
      case 'private':
        final target = (query['server'] ?? '').trim();
        if (target.isEmpty) {
          throw const ProjectionPolicyException('policy=private 须带 server 参数');
        }
        if (!isAccessible(target)) {
          throw ProjectionPolicyException(
              'target server not found: $target（该服务当前未挂载）');
        }
        if (isPrivate != null && !isPrivate(target)) {
          throw ProjectionPolicyException(
              'server "$target" 不是私有服务——policy=private 仅可叠加已配置的'
              '私有域（看非私有服务请用 policy=single）');
        }
        return ProjectionPolicy.private(target);
      case 'owner':
        // 宿主内部档不经网关暴露：owner = 对一切私有域免海关，泄露给 PC 即
        // MO6 崩塌。App 内链路直接构造 [ProjectionPolicy.owner()]，不走此处。
        throw const ProjectionPolicyException(
            'policy=owner 是宿主内部档，不经网关暴露（合法字面量：'
            'single / private / full / pruned）');
      default:
        throw ProjectionPolicyException(
            '未知 policy「$raw」（合法字面量：single / private / full / pruned）');
    }
  }}

/// 一条对外可见的工具声明（命名格式化之后的形态）。
class ProjectedTool {
  const ProjectedTool({
    required this.name,
    required this.serverId,
    required this.bareName,
    required this.description,
    required this.parametersSchema,
    required this.annotations,
  });

  /// 对外工具名：`full`/`pruned` 为 `<serverId>__<tool>`；`single` 为裸名。
  final String name;

  /// 来源 serverId（入站补齐 / 审计用；不从对外名反解）。系统工具为空串。
  final String serverId;

  /// 剥前缀后的裸工具名（= 宿主 executor 的工具名）。
  final String bareName;

  final String description;
  final Map<String, Object?> parametersSchema;
  final Map<String, Object?>? annotations;

  /// 转 MCP `tools/list` 条目（与既有网关目录形状一致：`annotations` 缺省不带）。
  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': parametersSchema,
        if (annotations != null) 'annotations': annotations,
      };
}

/// 一次投影的产物：工具声明 + 投影集签名（广播差分与入站边界判定共用）。
class ProjectionResult {
  ProjectionResult(List<ProjectedTool> tools)
      : tools = List<ProjectedTool>.unmodifiable(tools),
        signature = Set.unmodifiable({
          for (final t in tools)
            if (t.serverId.isNotEmpty) '${t.serverId}/${t.bareName}',
        });

  final List<ProjectedTool> tools;

  /// 投影集签名 = `serverId/bareName` 集（**结构化**，不含对外前缀——`single`
  /// 与 `full` 对同一批工具的签名相同，差异在策略而非集合）。
  final Set<String> signature;
}

/// 策略投影管道（四级单向）。
class ProjectionFilter {
  const ProjectionFilter._();

  /// 全量投影：按四级铁律过滤 face 集，产出对外工具声明。
  ///
  /// [privateServerIds] / [activePrivateServerId] = MO6 私有投影防火墙输入
  /// （仅当前连接激活的私有域进面）；[systemTools] = 网关级系统工具清单
  ///（**已由调用方按策略裁剪**：`full`/`pruned` 给全集，`single` 只给
  /// `gateway__select_private` 这一个出口工具——全隐匿会让 PC 切进去后
  /// 无法回到联邦面，即死锁）。
  static ProjectionResult project({
    required Map<String, McpToolFace> faces,
    required Set<String> privateServerIds,
    required String? activePrivateServerId,
    required ProjectionPolicy policy,
    required List<Map<String, Object?>> systemTools,
  }) {
    final out = <ProjectedTool>[];
    for (final entry in faces.entries) {
      final serverId = entry.key;
      final face = entry.value;
      // —— 2. 私有投影防火墙（MO6）：仅本连接激活私有域进面 ——
      if (privateServerIds.contains(serverId) &&
          serverId != activePrivateServerId) {
        continue;
      }
      // —— 3. 策略过滤：single 收敛到单一目标服务 ——
      if (policy.isSingle && serverId != policy.targetServerId) continue;
      for (final schema in face.cachedSchemas) {
        // —— 1. visibility 海关：只回 shared（缺失即 private = 不放大暴露面）。
        // 豁免一：本连接显式绑定的激活私有域不做声明收窄——绑定即信任边界
        // （用户显式选择该私有服务全能力），且调用侧「声明非 ACL」本就放行，
        // 目录面收窄只会制造「能调不能看」的反向不对称（2026-10-23 用户裁决）。
        // 豁免二（owner 档）：宿主内部机主全权视图，海关整体不生效（私有
        // 防火墙照常——仍由 activePrivateServerId 门控私有域进面）。
        if (!policy.isOwner &&
            !schema.isShared &&
            serverId != activePrivateServerId) {
          continue;
        }
        // —— 3. 策略过滤（续）：pruned 保守白名单，未打标一律剔除 ——
        if (policy.isPruned && !tagsOf(schema).any(policy.tags.contains)) {
          continue;
        }
        // —— 4. 命名与输出格式化 ——
        out.add(ProjectedTool(
          name: policy.isSingle
              ? schema.name
              : ToolRouter.prefixed(serverId, schema.name),
          serverId: serverId,
          bareName: schema.name,
          description: schema.description,
          parametersSchema: schema.parametersSchema,
          annotations: schema.annotations,
        ));
      }
    }
    // 系统工具：**是否纳入由调用方按策略裁剪**（本函数不裁决——`single` 下
    // 并非全隐匿：保留 `gateway__select_private` 作为「退出 single」的唯一出口，
    // 否则 PC 切进去后无法回到联邦面 = 死锁）。见 `GatewayHandler.project()`。
    {
      for (final t in systemTools) {
        final name = t['name'];
        if (name is! String || name.isEmpty) continue;
        out.add(ProjectedTool(
          name: name,
          serverId: '',
          bareName: name,
          description:
              t['description'] is String ? t['description'] as String : '',
          parametersSchema: t['inputSchema'] is Map
              ? (t['inputSchema'] as Map).cast<String, Object?>()
              : const <String, Object?>{},
          annotations: null,
        ));
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return ProjectionResult(out);
  }

  /// `_meta.goodhub.tags`（宿主 Allowlist 登记项声明；缺失/形状异常 → 空集）。
  static Set<String> tagsOf(CloudToolSchema schema) {
    final meta = schema.meta;
    if (meta == null) return const <String>{};
    final goodhub = meta['goodhub'];
    if (goodhub is! Map) return const <String>{};
    final tags = goodhub['tags'];
    if (tags is! List) return const <String>{};
    return {
      for (final t in tags)
        if (t is String && t.trim().isNotEmpty) t.trim(),
    };
  }
}

/// 入站工具名判定结果。
sealed class InboundToolName {
  const InboundToolName();
}

/// 放行：[resolvedName] 为补齐后的带前缀名（下游复用既有
/// `parsePrefixedToolName` 分发路径）。
class InboundAllowed extends InboundToolName {
  const InboundAllowed(this.resolvedName, {required this.prefixNormalized});

  /// 补齐/规范化后的 `<serverId>__<tool>` 名。
  final String resolvedName;

  /// 是否发生了「无前缀 → 补齐」（false = PC 已带正确前缀，原样放行，幂等）。
  final bool prefixNormalized;
}

/// 策略级拒绝（isError 回填 + 可自纠话术，不走协议级 error 帧）。
class InboundRejected extends InboundToolName {
  const InboundRejected(this.reason);

  final String reason;
}

/// 协议级拒绝（服务器层按 [code] 转 JSON-RPC error 帧）。
class InboundProtocolError extends InboundToolName {
  const InboundProtocolError(this.code, this.message);

  final int code;
  final String message;
}

/// 入站工具名判定（`tools/call` 侧纵深防线）。
///
/// 顺序（设计稿 §single 入站前缀补齐）：系统工具拒绝 → 本判定 → 既有
/// `parsePrefixedToolName` 之后的全部分发逻辑。
///
/// | 入站形态 | 处理 |
/// |---|---|
/// | 解析成功且 `serverId == target` | 原样放行（PC 已带正确前缀，天然幂等） |
/// | 解析失败（无前缀） | 补 `${target}__` 后重解析；仍失败返 -32602 |
/// | 解析成功但 `serverId != target` | 显式拒绝（越出本连接投影面） |
///
/// [isProjected] 额外承担「`single` 投影即调用边界」：投影集外的工具
/// （含 `visibility=private` 未进投影者）一律拒绝。
InboundToolName resolveInboundToolName({
  required String name,
  required ProjectionPolicy policy,
  required bool Function(String serverId, String bareName) isProjected,
}) {
  // —— 系统工具：`single` 零泄漏（不列出 + 调用显式拒绝）——
  if (name.startsWith('gateway__')) {
    if (policy.isSingle) {
      return const InboundRejected(
          'gateway__* 是网关连接级系统工具，single 策略下不提供控制面；'
          '回完整联邦面请调 gateway__select_private(server_id="all", '
          'policy=full)');
    }
  }
  if (!policy.isSingle) {
    // `full`/`pruned` 的入站形态与既有口径**逐字一致**（缺前缀 = isError
    // 回填，非协议级 error）——投影只收窄目录面，不改既有调用语义。
    if (parsePrefixedToolName(name) == null) {
      return const InboundRejected(
          '工具名缺少服务前缀（应形如 <server_id>__<tool>）');
    }
    // B15（review-fix-2026-10 拍板②）：pruned = 显式白名单投影——目录=调用
    // 边界（配置了白名单却拦不住名单外调用违背配置预期）；full 显式保持
    // 目录-only（visibility 非 ACL，§1.1 规则 7；裁决记录见
    // host-tools-gateway-export.md「入站边界裁决」）。
    final parsed = parsePrefixedToolName(name)!;
    if (policy.isPruned && !isProjected(parsed.serverId, parsed.toolName)) {
      return InboundRejected(
          '工具 ${parsed.toolName} 不在当前投影集内（pruned 白名单外不可调用）');
    }
    return InboundAllowed(name, prefixNormalized: false);
  }

  final target = policy.targetServerId!;
  final parsed = parsePrefixedToolName(name);
  if (parsed == null) {
    // 无前缀 → 补 target 前缀后重解析（结构化补齐，非字符串拼接）。
    final completed =
        parsePrefixedToolName('$target$kToolNamespaceSep$name');
    if (completed == null) {
      // 补齐后仍失败 = 工具名自身含 __（畸形名），协议级拒绝。
      return const InboundProtocolError(
          -32602, '工具名含双下划线，无法解析为 <server_id>__<tool> 结构');
    }
    if (!isProjected(completed.serverId, completed.toolName)) {
      return InboundRejected('工具 ${completed.toolName} 不在当前投影集内'
          '（single 策略仅暴露 $target 的工具面）');
    }
    return InboundAllowed('$target$kToolNamespaceSep${completed.toolName}',
        prefixNormalized: true);
  }
  if (parsed.serverId != target) {
    return InboundRejected('single 策略仅可调用 $target 的工具，'
        '${parsed.serverId}__* 越出本连接投影面');
  }
  if (!isProjected(parsed.serverId, parsed.toolName)) {
    return InboundRejected('工具 ${parsed.toolName} 不在当前投影集内'
        '（single 策略仅暴露 $target 的工具面）');
  }
  return InboundAllowed(name, prefixNormalized: false);
}
