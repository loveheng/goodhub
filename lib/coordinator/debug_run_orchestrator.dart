/// 网关/熔断联调页面的 **Run 编排件**（window-slim P1-B，2026-10-17 自
/// `ui/gateway_loop_debug_page.dart` 迁出）：把联调页 `_run` 内联的装配中枢
/// （挂载 → 能力协商 → 记忆面 → 权限网关 → 注水拦截 → 引擎 → sampling 接线 →
/// 故障注入 → Skills/CoW 同步 → AgentLoop → 事件流）收口至此——窗口只剩
/// 「收集开关 + 事件流→轨道映射 + UI 端口实现」三件事。
///
/// 纪律（对齐 window-kernel-split §5 与 ChatRunOrchestrator 口径）：
/// - **纯编排，零 UI**：本件不 import `ui/`；L2 确认卡 / 熔断排查卡 / 围栏拦截卡
///   / 跨源同意卡 / CoW 大版本跃迁卡全部经 port 回调回窗口（UI 决策留在窗口，
///   编排件只 await 结果，不依赖 BuildContext）；
/// - **复用内核挂载原语**：`McpRuntime.mount` 与生产同一路径（拒绝 isFakeDebug
///   特权分支，§8.1-11），fake 传输经 [DebugRunConfig.clientFactory] 注入；
/// - **注入位即测试位**：三个目录解析器 + clientFactory + quota + 五个 UI 端口
///   全由配置传入，本件可在无 Flutter binding 下编排单测。
///
/// 边界声明：**不合并进 `McpRuntime.assemble`**——生产入口是多 Server 前缀路由
/// + JIT 发现（tools 静态表为空）语义，联调流是单 Server 裸名 + 静态 tools 表
/// （脚本引擎按裸名发调用），二者 Review-wise 是两条 NOT semaphore；强行合一会把
/// 生产装配面拖进 debug 分支。本件的职责是把「窗口不该持有的装配」搬走，不是重写
/// 装配语义。
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/errors/mcp_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/sampling_engine.dart';
import '../llm/llm.dart';
import '../mcp/mcp_client.dart';
import '../mcp/sampling.dart';
import '../mcp/server_capabilities.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';
import 'context_governor.dart';
import 'cow_sync.dart';
import 'fenced_cloud_engine.dart';
import 'hybrid_assembly.dart';
import 'mcp_runtime.dart';
import 'mcp_tool_face.dart';
import 'memory_tool_executor.dart';
import 'permission_gateway.dart';
import 'pii_fence.dart';
import 'ref_hydrator.dart';
import 'ref_store.dart';
import 'skill_activation_executor.dart';
import 'skill_registry.dart';
import 'tool_breaker.dart';
import 'tool_executor_chain.dart';
import 'user_prompt_store.dart';

/// 状态带色调（窗口侧的 `CapsuleTone` 是 UI 枚举，编排件只用三档语义）。
enum DebugPillTone { idle, busy, danger }

/// 编排事件流（窗口把它映射到轨道条目；编排件不持有任何 widget 状态）。
sealed class DebugRunEvent {
  const DebugRunEvent();
}

/// 正文段（整段入轨道，阅读体样式由窗口定）。
final class DebugRunText extends DebugRunEvent {
  const DebugRunText(this.text);
  final String text;
}

/// 增量文本尾追加（模型流式输出；是否与上一段合并由窗口判定）。
final class DebugRunDelta extends DebugRunEvent {
  const DebugRunDelta(this.delta);
  final String delta;
}

/// 注记（灰=常规、danger=红警：e.g. 故障注入开启 / CoW 注册跳过 / 异常收尾）。
final class DebugRunNote extends DebugRunEvent {
  const DebugRunNote(this.text, {required this.danger});
  final String text;
  final bool danger;
}

final class DebugRunCallStarted extends DebugRunEvent {
  const DebugRunCallStarted(this.tool);
  final String tool;
}

final class DebugRunCallProgress extends DebugRunEvent {
  const DebugRunCallProgress({
    required this.tool,
    required this.progress,
    required this.total,
    required this.message,
  });
  final String tool;
  final num progress;
  final num? total;
  final String? message;
}

final class DebugRunCallFinished extends DebugRunEvent {
  const DebugRunCallFinished({
    required this.tool,
    required this.content,
    required this.isError,
  });
  final String tool;
  final String content;
  final bool isError;
}

final class DebugRunFinished extends DebugRunEvent {
  const DebugRunFinished({required this.text, required this.turns});
  final String text;
  final int turns;
}

/// 一次联调 Run 的入参集合（窗口收集，编排件消费）。
class DebugRunConfig {
  const DebugRunConfig({
    required this.serverId,
    required this.userPrompt,
    required this.systemPrompt,
    required this.clientFactory,
    required this.gate,
    required this.block,
    required this.fence,
    required this.crossSource,
    required this.majorJump,
    required this.onPill,
    this.injectFaults = false,
    this.useScriptedEngine = false,
    this.summarizeResults = false,
    this.injectMaskFailure = false,
    this.quota,
    this.onSamplingBegin,
    this.onSamplingEnd,
    this.onNotice,
    this.supportDirResolver,
    this.tempDirResolver,
    this.documentsDirResolver,
  });

  /// 目标服务 id（HTTP = 'goodshare'；Binder = 插件 serverId）。
  final String serverId;

  final String userPrompt;
  final String systemPrompt;

  /// 传输注入位（生产 = `McpClient.http` / `localPluginDiscovery.createClient`；
  /// 测试 = fake 传输）。
  final McpClient Function() clientFactory;

  // —— 挂起端口（Future<T>，UI 决策，窗口实现）——
  final GateDelegate gate;
  final BlockDelegate block;
  final PiiFenceDelegate fence;

  /// D5 跨源注水同意（恒 L2 弹卡、无豁免）。
  final Future<bool> Function(String handle, String fromServerId,
      String toServerId, String preview) crossSource;

  /// CoW major 跃迁裁决（true = 弃本地覆写回 server 版）。
  final Future<bool> Function(String name, String from, String to) majorJump;

  // —— 广播（void）——
  final void Function(String label, DebugPillTone tone) onPill;

  /// 卡死判定（sampling 在途包裹）：由窗口的 StuckWatcher 实现。
  final void Function()? onSamplingBegin;
  final void Function()? onSamplingEnd;

  /// 网关放行通告（§4.1：窗口给 L1 触感 tick；编排件不知 HapticFeedback）。
  final void Function()? onNotice;

  // —— 联调开关（debug 页限定，不在生产路径出现）——
  final bool injectFaults;
  final bool useScriptedEngine;
  final bool summarizeResults;
  final bool injectMaskFailure;

  /// 反向请求配额实例（窗口持有则跨 Run 存活；null = 本次 Run 内 new）。
  final SamplingQuota? quota;

  // —— 目录解析器（测试注入，默认走 path_provider）——
  final Future<Directory> Function()? supportDirResolver;
  final Future<Directory> Function()? tempDirResolver;
  final Future<Directory> Function()? documentsDirResolver;
}

/// Run 编排 owner：窗口经 [run] 取事件流，经 [abort] 中断在途。
///
/// 实例无跨 Run 态（除运行期的 [loop]/[face] 柄，finally 清空）。
class DebugRunOrchestrator {
  /// 活跃会话柄（Run 期非空，finally 清）；Abort 目标的接线口。
  AgentLoop? loop;
  McpToolFace? face;

  /// M3-T2 Abort：先在途 appeal cancelled 下发、再在环边界停下（指针若在途调用
  /// 已真实完成，Finished 事件照常回填——结果优先于 cancelled 标记）。
  void abort() {
    face?.cancelActiveRequest(reason: 'user abort');
    loop?.abort();
  }

  Stream<DebugRunEvent> run(DebugRunConfig cfg) async* {
    RefStore? refStore;
    try {
      final client = cfg.clientFactory();
      final serverId = cfg.serverId;
      AgentLoop? loopBox;
      // 复用内核挂载原语（与生产同路径，拒绝 isFakeDebug 特权分支——§8.1-11；
      // fake 传输经 clientFactory 注入）。
      final mounted = await const McpRuntime().mount(
        serverId: serverId,
        client: client,
        // M2.5-T7：progress 通告 → 状态带 Running(progress) 最小呈现 + M3-T2
        // 桥接 AgentLoop 事件流（LoopToolProgress，卡状态机全量数据源）。
        onProgress: (tool, progress, total, message) {
          loopBox?.emitToolProgress(tool, progress, total, message);
          cfg.onPill(
            total != null ? '$tool $progress/$total' : '$tool $progress',
            DebugPillTone.busy,
          );
        },
      );
      final face = mounted.face;
      final caps = mounted.caps;
      // M2.5-T2 能力协商接线：握手结果与 Tier 判定进轨迹；Tier 2（vanilla）
      // 额外生成静态摘要（C-4：500 字符封顶 + 「自动生成」标注）。
      yield DebugRunText(
        '能力协商：${caps.serverName ?? '?'} v${caps.serverVersion ?? '?'} ｜ '
        'protocol ${caps.protocolVersion} ｜ ${caps.isTier1 ? 'Tier 1（prompts+resources 全量）' : 'Tier 2（vanilla，Polyfill 接管）'}\n',
      );
      final schemas = mounted.schemas;
      if (caps.isTier2) {
        yield DebugRunText(
          '${buildStaticSummary([for (final s in schemas) (name: s.name, description: s.description)])}\n',
        );
      } else if (caps.hasResources) {
        try {
          final resources = await client.listResources();
          yield DebugRunText(
            '资源面：${resources.length} 条可读（resources/read 只读注入，§12）\n',
          );
        } on McpException catch (e) {
          yield DebugRunText(
            '资源面读取失败（Polyfill 降级为只读工具）：$e\n',
          );
        }
      }
      // M4-T2 记忆沙盒接线：应用支持目录/memory（全局持久，跨会话/跨窗口）。
      // 冷启动清扫挂 main（§11），此处直用。
      final supportDir = await (cfg.supportDirResolver ??
          getApplicationSupportDirectory)();
      final memoryStore = MemoryStore.underSupportDir(supportDir.path);
      // M2.5-T4 注水拦截：AgentLoop → HydratingExecutor → Gateway → Face
      // （先注水再网关——L1/L2 按注水后真实入参裁决）；RefStore 会话粒度，
      // run 一次 = 一会话，finally 即焚（§9 Session 结束直清）。
      final tempDir = await (cfg.tempDirResolver ?? getTemporaryDirectory)();
      final runRefStore = RefStore(
        cacheDir: tempDir,
        gcInterval: null, // debug 页短会话，退出即 expireAll，不靠周期 GC
      );
      refStore = runRefStore;

      final engine = cfg.useScriptedEngine
          ? ScriptedDebugEngine()
          : await assembleDefaultHybridEngine(
              // N7 围栏 D4 有人值守面：遮蔽失败出双选项拦截卡（T5c）
              piiFenceDelegate: cfg.fence,
              // T7 拦截卡联调：注入遮蔽失败（须云端已预置，脚本引擎不经过）
              maskOverride: cfg.injectMaskFailure
                  ? (_) async => throw const PiiMaskException(
                      '联调注入：遮蔽失败（debug 开关）')
                  : null,
            );
      yield DebugRunNote('引擎: ${engine.name}', danger: false);
      // M3 sampling 消费面（ai-app-split.md §3.11）：引擎装配后挂反向请求
      // 处理器——配额 D3 滑动窗口（serverKey = face.serverId），推理走本 Run
      // 同一引擎实例（N7 围栏单咽喉自然覆盖，临时会话语义见 sampling.dart）。
      final sampling = samplingRequestHandler(
        engine: CloudSamplingEngine(engine),
        quota: cfg.quota ?? SamplingQuota(),
        serverKey: face.serverId,
      );
      client.onServerRequest = (method, params) {
        cfg.onSamplingBegin?.call();
        return sampling(
          method,
          params,
        ).whenComplete(() => cfg.onSamplingEnd?.call());
      };

      // M2.5-T5 三级 Skill：注册表会话粒度 + activate_skill 元工具最外层拦截
      // （本地工具不外发 server）；Global/App-Scoped 注入 system prompt 组装。
      final skills = SkillRegistry()..registerAll(builtinSkills());
      // prompt-mgmt §3.3：user 全局 prompt（注册闸 fail-fast 跳过并通告）。
      final userStore = UserGlobalPromptsStore(
        dir: await (cfg.documentsDirResolver ?? getApplicationDocumentsDirectory)(),
      );
      for (final p in await userStore.load()) {
        try {
          skills.register(p.toSkill());
        } on ArgumentError catch (e) {
          yield DebugRunNote('⚠ 全局 Prompt 注册跳过: $e', danger: true);
        }
      }
      // M2.5-T6 CoW 继承：Tier 1 prompts 模板 → appScoped Skill（本地覆写
      // 最高优先级 + major 跃迁强制告警 + min_hub_version 兼容闸）。
      if (caps.hasPrompts) {
        final docsDir = await (cfg.documentsDirResolver ??
            getApplicationDocumentsDirectory)();
        try {
          final cow = CowSyncService(
            store: CowOverridesStore(dir: docsDir),
            onMajorJump: cfg.majorJump,
          );
          final items = await cow.sync(client, serverId: face.serverId);
          for (final i in items) {
            if (i.content == null) continue;
            try {
              skills.register(CowSyncService.toSkill(i, face.serverId));
            } on ArgumentError catch (e) {
              yield DebugRunNote('⚠ CoW Skill 注册跳过: $e', danger: true);
            }
          }
          yield DebugRunText(
            'CoW 同步：${items.map((i) => '${i.promptName}(${i.action.name})').join(', ')}\n',
          );
        } on McpException catch (e) {
          yield DebugRunText(
            'CoW 同步失败（Polyfill 降级为无模板注入）：$e\n',
          );
        }
      }

      if (cfg.injectFaults) {
        yield const DebugRunNote(
          '⚠ 故障注入开启：每个工具前 2 次调用强制失败（联调熔断卡）',
          danger: true,
        );
      }
      // 执行面链经**唯一装配器** composeToolExecutorChain（架构债 #19 根治）：
      // 层按「优先级高 → 低」给出，折叠方向固定逐层向外——调用点无法再写出
      // 「inner 指向链中段」的丢层形态（该形态曾致内层整层丢弃、目录可见而调用全败）。
      PermissionGateway? gatewayRef;
      final executor = composeToolExecutorChain([
        (inner) => SkillActivationExecutor(
          inner: inner,
          registry: skills,
          opsLog: memoryStore,
        ),
        if (cfg.injectFaults)
          (inner) => _FaultInjector(inner: inner, failTimesPerTool: 2),
        (inner) => HydratingExecutor(
          inner: inner,
          refStore: runRefStore,
          targetServerId: face.serverId,
          crossSourceDelegate: (handle, from, to, preview) =>
              cfg.crossSource(handle, from, to, preview),
        ),
        (inner) {
          final g = PermissionGateway(
            // M4-T2：记忆工具面挂 Gateway 内侧——update_memory（写）先过 L2 裁决
            // 再执行（F4.4 记忆类写路径强制 L2），query_memory 只读 L1。
            inner: inner,
            delegate: cfg.gate,
            onNotice: (n) {
              cfg.onPill(n.toolName, DebugPillTone.busy);
              cfg.onNotice?.call();
            },
          );
          gatewayRef = g;
          return g;
        },
        (inner) => MemoryToolExecutor(inner: inner, store: memoryStore),
      ], fallback: face);
      gatewayRef!.loadCatalog([
        ...schemas,
        ...MemoryToolExecutor.toolSchemas(),
      ]);
      final loop = AgentLoop(
        engine: engine,
        executor: executor,
        blockDelegate: cfg.block,
        summarizer: cfg.summarizeResults
            ? OnDeviceResultSummarizer(ChannelLlmEngine()).call
            : null,
        // M3-T3 put 端：摘要化成功路径原文落池、宿主注升级 $ref 句柄——
        // 与 HydratingExecutor 读端同一池（Session 粒度，finally 即焚 §9）。
        refStore: refStore,
        refServerId: face.serverId,
      );
      loopBox = loop;
      this.loop = loop;
      this.face = face;
      cfg.onPill('thinking', DebugPillTone.busy);
      await for (final e in loop.run(
        systemPrompt: skills.composeSystemPrompt(
          cfg.systemPrompt,
          publicServerIds: [face.serverId],
        ),
        userPrompt: cfg.userPrompt,
        tools: [...schemas, skills.activationToolSchema()],
      )) {
        switch (e) {
          case LoopThinkingDelta():
            // M1：调试页不呈现思考流（展示 only 落点 = chat_page 思考轨）；
            // 禁混入 DebugRunDelta——那是正文遥测流，会污染 delta 语义。
            break;
          case LoopTextDelta(:final text):
            yield DebugRunDelta(text);
          case LoopToolCallStarted(:final call):
            cfg.onPill(call.name, DebugPillTone.busy);
            // M3-T2 状态机全量：Started 即插卡（Emerald 执行中），等 progress
            // 帧 / 终态事件推进相位。
            yield DebugRunCallStarted(call.name);
          case LoopToolProgress(
            :final call,
            :final progress,
            :final total,
            :final message,
          ):
            yield DebugRunCallProgress(
              tool: call.name,
              progress: progress,
              total: total,
              message: message,
            );
          case LoopToolCallFinished(:final call, :final result):
            cfg.onPill(
              result.content.contains('"user_rejected"')
                  ? 'rejected'
                  : 'idle',
              DebugPillTone.busy,
            );
            yield DebugRunCallFinished(
              tool: call.name,
              content: result.content,
              isError: result.isError,
            );
          case LoopFinished(:final text, :final turns):
            yield DebugRunDelta(text.isEmpty ? '' : '\n');
            yield DebugRunFinished(text: text, turns: turns);
            cfg.onPill('done', DebugPillTone.idle);
        }
      }
    } on Object catch (e) {
      yield DebugRunNote('✕ $e', danger: true);
      cfg.onPill('failed', DebugPillTone.danger);
    } finally {
      await refStore?.expireAll(); // §9：Session 结束直清临时文件
      refStore?.dispose();
      loop = null;
      face = null;
    }
  }
}

/// 故障注入装饰器（联调熔断卡专用）：每个工具的前 [failTimesPerTool] 次调用
/// 强制 isError——模型重试同工具即撞两步熔断；注入耗尽后透传真实执行（排查卡
/// 「单步重试」会真成功，完整演示重试语义）。
class _FaultInjector implements ToolExecutor {
  _FaultInjector({required this.inner, required this.failTimesPerTool});

  final ToolExecutor inner;
  final int failTimesPerTool;
  final _used = <String, int>{};

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    final used = _used[call.name] ?? 0;
    if (used < failTimesPerTool) {
      _used[call.name] = used + 1;
      return ToolExecutionResult(
        // 503 风格文案提高真实模型重试概率（联调脚本引擎下仅作展示）
        content: '${call.name} 暂时不可用（模拟 503 Service Unavailable），请稍后重试',
        isError: true,
      );
    }
    return inner.execute(call);
  }
}

/// 脚本引擎（确定性走环）：前两轮都发 list_items 工具调用（配故障注入 =
/// 同工具连续 2 次报错必出熔断卡），第三轮文本收尾。与 agent_loop 测试假件
/// 同构，不经云端不依赖模型行为。
class ScriptedDebugEngine implements CloudLlmEngine {
  var _turn = 0;

  @override
  String get name => 'scripted（联调脚本引擎）';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
    _turn++;
    if (_turn <= 2) {
      yield CloudToolCallDelta(
        index: 0,
        id: 'script-$_turn',
        name: 'list_items',
      );
      yield const CloudToolCallDelta(index: 0, argumentsDelta: '{"limit":2}');
      yield const CloudDone(finishReason: CloudFinishReason.toolCalls);
      return;
    }
    yield const CloudTextDelta('脚本引擎收尾：网关/熔断联调完成。');
    yield const CloudDone(finishReason: CloudFinishReason.stop);
  }
}
