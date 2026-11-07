/// Run 装配入参配置对象（extensibility-hardening S5 自 mcp_runtime 拆出）：
/// assemble 散参收敛件（E3）——mcp_runtime 为超标清单件「只减不增」，本类
/// 独立成件避免回涨；字段缺省值与原散参逐一等值，调用方迁移 = 包一层。
/// 注：SessionContext / RuntimeDelegates 仍住 mcp_runtime.dart——本件
/// import 之构成声明环（Dart 合法，S3 云/端腿同款先例）。
library;

import 'dart:io';

import '../llm/cloud/byok_store.dart';
import '../llm/cloud/cloud_llm.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/sampling.dart' show SamplingQuota;
import '../mcp/server_endpoints.dart';
import '../mcp/server_probe.dart' show McpClientFactory;
import '../sandbox/memory_store.dart';
import 'resource_attachment_binder.dart' show ResourceAttachment;
import '../resources/resource_store.dart' show ResourceStore;
import 'mcp_runtime.dart' show RuntimeDelegates, SessionContext;
import 'mcp_tool_face.dart';
import 'run_profile.dart';
import 'skill_registry.dart';
import 'task_plan.dart' show PlanRunState;
import 'cow_sync.dart' show CowOverridesStore;

/// Run 装配入参（E3 收敛，extensibility-hardening S5）：assemble 散参收配置
/// 对象——每加一项能力不再穿多层签名；字段缺省值与原散参逐一等值，调用方
/// 迁移 = 原具名实参外包一层 `McpRunSpec(...)`。
class McpRunSpec {
  const McpRunSpec({
    required this.context,
    required this.endpoints,
    required this.locals,
    required this.apiKeyReader,
    required this.memoryStore,
    required this.skills,
    this.delegates = const RuntimeDelegates(),
    this.quota,
    this.clientFactory,
    this.onSamplingBegin,
    this.onSamplingEnd,
    this.engine,
    this.byokStore,
    this.planState,
    this.tempDirResolver,
    this.documentsDirResolver,
    this.resourceAttachments = const [],
    this.resourceStore,
    this.sharedFaces = const {},
    this.cowStoreProvider,
    this.profile = RunProfile.chat,
  });

  final SessionContext context;
  final List<ServerEndpoint> endpoints;
  final List<LocalPluginInfo> locals;
  final Future<String?> Function(String serverId) apiKeyReader;
  final MemoryStore memoryStore;
  final SkillRegistry skills;
  final RuntimeDelegates delegates;
  final SamplingQuota? quota;
  final McpClientFactory? clientFactory;
  final void Function()? onSamplingBegin;
  final void Function()? onSamplingEnd;
  final CloudLlmEngine? engine;

  /// BYOK 配置库应用级单实例（E9 闭环）：null = 就地构造（兼容旧调用方）。
  final ByokStore? byokStore;

  /// 会话级编排状态（多插件任务编排 B1）：台账/配额跨续跑累计，grant 仍
  /// Run 级；null = 不挂计划围栏（网关 headless 装配无编排语义）。
  final PlanRunState? planState;
  final Future<Directory> Function()? tempDirResolver;
  final Future<Directory> Function()? documentsDirResolver;

  /// 资源中心附件（M1-T3）：装配期把全文落 run 级 $ref 池并产出上下文 footer。
  final List<ResourceAttachment> resourceAttachments;

  /// 测试注入位 / 生产由窗口经 lib/app 装配传入；null = 不注册本地资源工具面。
  final ResourceStore? resourceStore;

  /// 共享能力源 face 表（装配层合一 · Contract 件）：id 命中即借用该 face
  /// （跳过新建/协商/连接），client 归源所有不 close；缺省空表 = 全量自建。
  final Map<String, McpToolFace> sharedFaces;

  /// S1：CoW 覆写库的应用级单实例来源（null = 装配内就地构造，兼容旧调用方）。
  final Future<CowOverridesStore> Function()? cowStoreProvider;

  /// S2 运行场景（默认 `chat`）：决定本次装配的能力上限（哪些反向能力/
  /// 同步/编排围栏参与接线）。
  final RunProfile profile;
}

