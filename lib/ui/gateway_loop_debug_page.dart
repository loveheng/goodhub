/// 网关/熔断联调页（M2-T4c，拍板 C4 边界：最小可验操作轨）。
///
/// 全链接线：McpToolFace → PermissionGateway → AgentLoop → BlockDelegate/
/// GateDelegate → 本页轨道渲染（药丸 + 执行状态卡 + L2 确认卡 + 排查卡）。
/// 三组件按 tokens 正式实现，M3 双轨消息流可直接复用；本页不建消息流。
///
/// 会话豁免（C7）随 gateway 实例存活：每次 Run 新建 gateway = 新会话。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/context_governor.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/coordinator/fenced_cloud_engine.dart';
import 'package:goodhub/coordinator/hybrid_assembly.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/memory_tool_executor.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/coordinator/pii_fence.dart';
import 'package:goodhub/coordinator/ref_hydrator.dart';
import 'package:goodhub/coordinator/ref_store.dart';
import 'package:goodhub/coordinator/skill_activation_executor.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/sampling.dart';
import 'package:goodhub/mcp/server_capabilities.dart';
import 'package:goodhub/sandbox/memory_store.dart';

import 'components/breaker_card.dart';
import 'components/call_card.dart';
import 'components/confirmation_card.dart';
import 'components/cross_source_consent_card.dart';
import 'components/fence_block_card.dart';
import 'components/status_capsule.dart';
import 'components/stuck_watcher.dart';
import 'tokens/console_tokens.dart';

/// 轨道条目（C4 最小操作轨：阅读文本 / 执行状态 / 确认卡 / 排查卡 / 通告）。
sealed class _Entry {
  const _Entry();
}

class _TextEntry extends _Entry {
  _TextEntry(String initial) {
    text.write(initial);
  }

  final StringBuffer text = StringBuffer();
}

class _CallEntry extends _Entry {
  _CallEntry({required this.tool});
  final String tool;

  /// M3-T2 状态机（CallCard 渲染快照源；终态后页面保证不再 mutate——
  /// 终态锁定审计感）。
  CallCardPhase phase = CallCardPhase.running;
  String? progressNote;

  /// 终态结果预览（首两行）。
  String preview = '';
}

class _ConfirmEntry extends _Entry {
  _ConfirmEntry({required this.pending});
  final ToolPendingConfirmation pending;
  final completer = Completer<GateDecision>();
  GateDecision? decision;
  DateTime? decidedAt;
}

class _BreakerEntry extends _Entry {
  _BreakerEntry.breaker(this.report) : wall = null;
  _BreakerEntry.wall(this.wall) : report = null;
  final BreakerReport? report;
  final StepWallReport? wall;
  final completer = Completer<Object?>();
  String? lockedText;
  DateTime? decidedAt;
}

class _FenceEntry extends _Entry {
  _FenceEntry(this.info);
  final PiiMaskBlockInfo info;
  final completer = Completer<bool>();
  bool? decision;
  DateTime? decidedAt;
}

class _NoteEntry extends _Entry {
  _NoteEntry(this.text, {required this.danger});
  final String text;
  final bool danger;
}

class GatewayLoopDebugPage extends StatefulWidget {
  const GatewayLoopDebugPage({super.key});

  @override
  State<GatewayLoopDebugPage> createState() => _GatewayLoopDebugPageState();
}

class _GatewayLoopDebugPageState extends State<GatewayLoopDebugPage> {
  static const _systemPrompt =
      '你是 GoodHub 宿主的调试助手。可以调用工具完成用户任务；只读工具会静默执行，'
      '写操作需用户在确认卡批准。回答使用中文，完成后不要输出多余解释。';

  final _urlCtrl = TextEditingController(text: 'http://127.0.0.1:8765/mcp');

  /// MCP 令牌（goodshare「MCP 服务」页可查；与主入口 ClaimLoopPage 同口径，
  /// 不持久化——debug 页不留凭据）。
  final _keyCtrl = TextEditingController();

  final _byokUrlCtrl = TextEditingController();
  final _byokModelCtrl = TextEditingController();
  final _byokKeyCtrl = TextEditingController();

  /// 故障注入（联调熔断卡专用，debug 页限定）：环内每工具前 N 次调用强制
  /// isError——模型重试同工具即撞「同工具连续 2 次报错」。默认关。
  var _injectFaults = false;
  static const int _faultTimes = 2;

  /// 脚本引擎（确定性走环，不经云端/模型）：真实模型吃瘪后可能换工具不重试，
  /// per-tool 熔断计数永远停在 1——脚本保证同工具连调两次，必出排查卡。
  var _useScriptedEngine = false;

  /// M3 sampling 配额（D3 拍板）：per-server 滑动窗口 20 次/60min，页面级
  /// 内存态——重启清零（防滥用非计费口径）。
  final SamplingQuota _samplingQuota = SamplingQuota();

  /// M3-T2 活跃会话柄：Abort 与卡状态机的接线目标（_run 期非空，finally 清）。
  AgentLoop? _activeLoop;
  McpToolFace? _activeFace;
  _CallEntry? _activeCallEntry;
  StuckWatcher? _watcher;

  /// 工具结果摘要化（T6 上下文治理联调）：>1000T 结果回填前端侧小模型摘要，
  /// 失败保留原文（E1，[DEGRADE] 留痕）。窗口治理（N=6 轮）恒开无开关。
  /// 默认关——避免既有联调流隐式依赖端侧引擎。
  var _summarizeResults = false;

  /// 遮蔽失败注入（T7 拦截卡三态联调）：强制围栏遮蔽抛 PiiMaskException，
  /// 出双选项拦截卡（取消/明文一次）。须云端已预置（围栏挂云端引擎，端侧
  /// 与脚本引擎不经过）。默认关。
  var _injectMaskFailure = false;

  /// 预填联调任务（M3-T5 真机联调第二批·场景 B）：$ref 注水——get_item
  /// 大出参（2714 字符 >1000T）摘要化落池升级句柄 → 模型把句柄传给
  /// add_item → HydratingExecutor 注水写原文（须开「工具结果摘要化」开关）。
  final _promptCtrl = TextEditingController(
    text:
        'call get_item on id 2890388d-ba14-4652-96d4-1f6a602434c2, then '
        'call add_item to save its full original text as a new note, '
        'passing the ref handle mentioned in the host note verbatim as the '
        'content argument',
  );
  var _running = false;
  final _track = <_Entry>[];

  /// T-trans-4：已发现本地插件（扫描结果）；选中其一则 _run 走 Binder 而非 HTTP。
  List<LocalPluginInfo> _localPlugins = const [];
  LocalPluginInfo? _selectedLocal;
  final _scrollCtrl = ScrollController();
  var _pillLabel = 'idle';
  var _pillTone = CapsuleTone.idle;

  // —— 云端引擎预置（BYOK，T2 遗留项的联调版；M3 服务大厅出正式 UI）——
  var _protocol = CloudProtocol.openaiCompatible;
  var _byokStatus = '读取中…';

  @override
  void initState() {
    super.initState();
    unawaited(_refreshByokStatus());
  }

  Future<void> _refreshByokStatus() async {
    final profiles = await ByokStore().load();
    if (!mounted) return;
    setState(() {
      _byokStatus = profiles.isEmpty
          ? '未预置（Agent Loop 带工具恒走云端，端侧不承接——无云端即「无可用引擎」）'
          : '已预置: ${profiles.first.name}（${profiles.first.model}）';
    });
  }

  /// T-trans-4：扫描已安装本地插件（宿主 PackageManager），结果进下拉供 _run 选 Binder 目标。
  Future<void> _scanLocal() async {
    final found = await localPluginDiscovery.scan();
    if (!mounted) return;
    setState(() {
      _localPlugins = found;
      _selectedLocal = found.isEmpty ? null : found.first;
    });
    _add(
      _NoteEntry(
        found.isEmpty
            ? '未发现本地插件（未安装，或缺少 com.zzh.goodhub.action.MCP_SERVER）'
            : '发现本地插件: ${found.map((p) => p.serverId).join(', ')}',
        danger: found.isEmpty,
      ),
    );
  }

  Future<void> _saveByok() async {
    final baseUrl = _byokUrlCtrl.text.trim();
    final model = _byokModelCtrl.text.trim();
    final key = _byokKeyCtrl.text.trim();
    if (baseUrl.isEmpty || model.isEmpty || key.isEmpty) {
      setState(() => _byokStatus = '⚠ BaseURL / 模型 ID / Key 均必填');
      return;
    }
    const id = 'debug-loop-preset';
    final store = ByokStore();
    final existing = await store.load();
    final profile = ByokProfile(
      id: id,
      name: '联调预置',
      protocol: _protocol,
      baseUrl: baseUrl,
      model: model,
    );
    // upsert：保住非本页管理的其他 profile（现网一般没有）
    await store.save([
      for (final p in existing)
        if (p.id != id) p,
      profile,
    ]);
    await store.setApiKey(id, key);
    if (!mounted) return;
    _byokKeyCtrl.clear();
    setState(() => _byokStatus = '✓ 已预置: ${profile.model}');
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _promptCtrl.dispose();
    _byokUrlCtrl.dispose();
    _byokModelCtrl.dispose();
    _byokKeyCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _add(_Entry entry) {
    if (!mounted) return;
    setState(() => _track.add(entry));
    _pinToBottom();
  }

  void _appendText(String delta) {
    if (!mounted) return;
    setState(() {
      final last = _track.isNotEmpty ? _track.last : null;
      if (last is _TextEntry) {
        last.text.write(delta);
      } else {
        _track.add(_TextEntry(delta));
      }
    });
    _pinToBottom();
  }

  /// 轨道自动滚底：熔断/确认卡多在轨道尾部，不滚底会沉到视口外（联调误判
  /// 「没弹卡」的第一嫌疑）。
  void _pinToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _setPill(String label, CapsuleTone tone) {
    if (!mounted) return;
    setState(() {
      _pillLabel = label;
      _pillTone = tone;
    });
  }

  Future<void> _run() async {
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty || _running) return;
    setState(() {
      _running = true;
      _track.clear();
      _pillLabel = 'connecting';
      _pillTone = CapsuleTone.l1;
    });
    RefStore? refStore;
    try {
      final localTarget = _selectedLocal;
      final client = localTarget == null
          ? McpClient.http(
              baseUrl: _urlCtrl.text.trim(),
              apiKey: _keyCtrl.text.trim().isEmpty
                  ? null
                  : _keyCtrl.text.trim(),
            )
          : localPluginDiscovery.createClient(localTarget);
      final serverId = localTarget?.serverId ?? 'goodshare';
      // M2.5-T2 能力协商接线：握手结果与 Tier 判定进轨迹；Tier 2（vanilla）
      // 额外生成静态摘要（C-4：500 字符封顶 + 「自动生成」标注）。
      final caps = await client.negotiate();
      _add(
        _TextEntry(
          '能力协商：${caps.serverName ?? '?'} v${caps.serverVersion ?? '?'} ｜ '
          'protocol ${caps.protocolVersion} ｜ ${caps.isTier1 ? 'Tier 1（prompts+resources 全量）' : 'Tier 2（vanilla，Polyfill 接管）'}\n',
        ),
      );
      AgentLoop? loopBox;
      final face = McpToolFace(
        client: client,
        serverId: serverId,
        // M2.5-T7：progress 通告 → 药丸 Running(progress) 最小呈现 + M3-T2
        // 桥接 AgentLoop 事件流（LoopToolProgress，卡状态机全量数据源）。
        // Tier 2（vanilla）额外生成静态摘要（C-4：500 字符封顶 + 「自动生成」标注）。
        onProgress: (tool, progress, total, message) {
          loopBox?.emitToolProgress(tool, progress, total, message);
          _setPill(
            total != null ? '$tool $progress/$total' : '$tool $progress',
            CapsuleTone.l1,
          );
        },
      );
      final schemas = await face.listTools();
      if (caps.isTier2) {
        _add(
          _TextEntry(
            '${buildStaticSummary([for (final s in schemas) (name: s.name, description: s.description)])}\n',
          ),
        );
      } else if (caps.hasResources) {
        try {
          final resources = await client.listResources();
          _add(
            _TextEntry(
              '资源面：${resources.length} 条可读（resources/read 只读注入，§12）\n',
            ),
          );
        } on McpException catch (e) {
          _add(_TextEntry('资源面读取失败（Polyfill 降级为只读工具）：$e\n'));
        }
      }
      // M4-T2 记忆沙盒接线：应用支持目录/memory（全局持久，跨会话/跨窗口）。
      // 冷启动清扫挂 main（§11），此处直用。
      final memoryStore = MemoryStore.underSupportDir(
        (await getApplicationSupportDirectory()).path,
      );
      final gateway = PermissionGateway(
        // M4-T2：记忆工具面挂 Gateway 内侧——update_memory（写）先过 L2 裁决
        // 再执行（F4.4 记忆类写路径强制 L2），query_memory 只读 L1。
        inner: MemoryToolExecutor(inner: face, store: memoryStore),
        delegate: _PageGate(this),
        onNotice: (n) {
          _setPill(n.toolName, CapsuleTone.l1);
          unawaited(HapticFeedback.selectionClick()); // §4.1 L1 药丸极轻微 tick
        },
      );
      gateway.loadCatalog([...schemas, ...MemoryToolExecutor.toolSchemas()]);
      // M2.5-T4 注水拦截：AgentLoop → HydratingExecutor → Gateway → Face
      // （先注水再网关——L1/L2 按注水后真实入参裁决）；RefStore 会话粒度，
      // _run 一次 = 一会话，finally 即焚（§9 Session 结束直清）。
      refStore = RefStore(
        cacheDir: await getTemporaryDirectory(),
        gcInterval: null, // debug 页短会话，退出即 expireAll，不靠周期 GC
      );
      final hydration = HydratingExecutor(
        inner: gateway,
        refStore: refStore,
        targetServerId: face.serverId,
        crossSourceDelegate: (handle, from, to, preview) async {
          // M3-T4 组件化（D5 拍板：恒 L2 弹卡、无会话豁免勾选——数据面风险
          // 工具级豁免防不住）；禁盲签由卡内兜底（preview 空 → 允许禁用）。
          final r = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              contentPadding: EdgeInsets.zero,
              content: CrossSourceConsentCard(
                handle: handle,
                fromServer: from,
                toServer: to,
                preview: preview,
                onDecision: (v) => Navigator.pop(ctx, v),
              ),
            ),
          );
          return r == true;
        },
      );
      final engine = _useScriptedEngine
          ? _ScriptedEngine()
          : await assembleDefaultHybridEngine(
              // N7 围栏 D4 有人值守面：遮蔽失败出双选项拦截卡（T5c）
              piiFenceDelegate: _PageFence(this),
              // T7 拦截卡联调：注入遮蔽失败（须云端已预置，脚本引擎不经过）
              maskOverride: _injectMaskFailure
                  ? (_) async =>
                        throw const PiiMaskException('联调注入：遮蔽失败（debug 开关）')
                  : null,
            );
      _add(_NoteEntry('引擎: ${engine.name}', danger: false));
      // M3-T2 卡死判定（D4 双档）：per 活跃调用计时；sampling 反向请求在途
      // 顺延（工具等的是宿主自己的 LLM，宿主可知状态——30s 口径防误报）。
      _watcher = StuckWatcher(onStuck: _markActiveCallStuck);
      // M3 sampling 消费面（ai-app-split.md §3.11）：引擎装配后挂反向请求
      // 处理器——配额 D3 滑动窗口（serverKey = face.serverId），推理走本 Run
      // 同一引擎实例（N7 围栏单咽喉自然覆盖，临时会话语义见 sampling.dart）。
      final sampling = samplingRequestHandler(
        engine: engine,
        quota: _samplingQuota,
        serverKey: face.serverId,
      );
      client.onServerRequest = (method, params) {
        _watcher?.samplingBegin();
        return sampling(
          method,
          params,
        ).whenComplete(() => _watcher?.samplingEnd());
      };
      final executor = _injectFaults
          ? _FaultInjector(inner: hydration, failTimesPerTool: _faultTimes)
          : hydration as ToolExecutor;
      // M2.5-T5 三级 Skill：注册表会话粒度 + activate_skill 元工具最外层拦截
      // （本地工具不外发 server）；Global/App-Scoped 注入 system prompt 组装。
      final skills = SkillRegistry()..registerAll(builtinSkills());
      // M2.5-T6 CoW 继承：Tier 1 prompts 模板 → appScoped Skill（本地覆写
      // 最高优先级 + major 跃迁强制告警 + min_hub_version 兼容闸）。
      if (caps.hasPrompts) {
        try {
          final cow = CowSyncService(
            store: CowOverridesStore(
              dir: await getApplicationDocumentsDirectory(),
            ),
            onMajorJump: (name, from, to) async {
              final r = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('模板大版本更新：$name'),
                  content: Text(
                    '服务端模板 $from → $to（大版本跃迁）。\n'
                    '你本地有覆写副本：重置将弃用覆写回服务端最新版；'
                    '保留则以本地副本继续生效。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('保留本地'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('重置为服务端版'),
                    ),
                  ],
                ),
              );
              return r == true;
            },
          );
          final items = await cow.sync(client, serverId: face.serverId);
          for (final i in items) {
            if (i.content == null) continue;
            try {
              skills.register(CowSyncService.toSkill(i, face.serverId));
            } on ArgumentError catch (e) {
              _add(_NoteEntry('⚠ CoW Skill 注册跳过: $e', danger: true));
            }
          }
          _add(
            _TextEntry(
              'CoW 同步：${items.map((i) => '${i.promptName}(${i.action.name})').join(', ')}\n',
            ),
          );
        } on McpException catch (e) {
          _add(_TextEntry('CoW 同步失败（Polyfill 降级为无模板注入）：$e\n'));
        }
      }
      final skillExecutor = SkillActivationExecutor(
        inner: executor,
        registry: skills,
        opsLog: memoryStore,
      );
      if (_injectFaults) {
        _add(
          _NoteEntry(
            '⚠ 故障注入开启：每个工具前 $_faultTimes 次调用强制失败（联调熔断卡）',
            danger: true,
          ),
        );
      }
      final loop = AgentLoop(
        engine: engine,
        executor: skillExecutor,
        blockDelegate: _PageBlock(this),
        summarizer: _summarizeResults
            ? OnDeviceResultSummarizer(ChannelLlmEngine()).call
            : null,
        // M3-T3 put 端：摘要化成功路径原文落池、宿主注升级 $ref 句柄——
        // 与 HydratingExecutor 读端同一池（Session 粒度，finally 即焚 §9）。
        refStore: refStore,
        refServerId: face.serverId,
      );
      loopBox = loop;
      _activeLoop = loop;
      _activeFace = face;
      _setPill('thinking', CapsuleTone.l1);
      await for (final e in loop.run(
        systemPrompt: skills.composeSystemPrompt(
          _systemPrompt,
          connectedServerIds: [face.serverId],
        ),
        userPrompt: prompt,
        tools: [...schemas, skills.activationToolSchema()],
      )) {
        switch (e) {
          case LoopTextDelta(:final text):
            _appendText(text);
          case LoopToolCallStarted(:final call):
            _setPill(call.name, CapsuleTone.l1);
            // M3-T2 状态机全量：Started 即插卡（Emerald 执行中），等 progress
            // 帧 / 终态事件推进相位。
            final entry = _CallEntry(tool: call.name);
            _activeCallEntry = entry;
            _add(entry);
            _watcher?.start();
          case LoopToolProgress(
            :final call,
            :final progress,
            :final total,
            :final message,
          ):
            final entry = _activeCallEntry;
            if (entry != null && entry.tool == call.name) {
              setState(() {
                final tail = message == null ? '' : ' · $message';
                entry.progressNote = total != null
                    ? '$progress/$total$tail'
                    : '$progress$tail';
              });
            }
            _watcher?.onProgressFrame();
          case LoopToolCallFinished(:final call, :final result):
            final rejected = result.content.contains('"user_rejected"');
            final entry = _activeCallEntry;
            final phase = result.isError
                ? CallCardPhase.failed
                : CallCardPhase.success;
            if (entry != null && entry.tool == call.name) {
              // 真实结果优先于 Abort 的 cancelled 标记（在途调用完成后照常回填）
              setState(() {
                entry
                  ..phase = phase
                  ..preview = _preview(result.content)
                  ..progressNote = null;
              });
            } else {
              _add(
                _CallEntry(tool: call.name)
                  ..phase = phase
                  ..preview = _preview(result.content),
              );
            }
            _activeCallEntry = null;
            _watcher?.stop();
            _setPill(rejected ? 'rejected' : 'idle', CapsuleTone.l1);
          case LoopFinished(:final text, :final turns):
            _appendText(text.isEmpty ? '' : '\n');
            _add(_NoteEntry('✓ 收尾（$turns 轮）', danger: false));
            _setPill('done', CapsuleTone.idle);
        }
      }
    } on Object catch (e) {
      _add(_NoteEntry('✕ $e', danger: true));
      _setPill('failed', CapsuleTone.danger);
    } finally {
      _watcher?.stop();
      _watcher = null;
      _activeLoop = null;
      _activeFace = null;
      _activeCallEntry = null;
      await refStore?.expireAll(); // §9：Session 结束直清临时文件
      refStore?.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  /// D4 判定触发：在途卡转 stuck 相位（Amber 提示 + 顶部 [ABORT] 入口强化），
  /// 不自动中止（写操作半程悬挂，architecture §10）。
  void _markActiveCallStuck() {
    final entry = _activeCallEntry;
    if (entry == null || entry.phase != CallCardPhase.running) return;
    if (mounted) setState(() => entry.phase = CallCardPhase.stuck);
  }

  /// M3-T2 Abort（architecture §10 级联的 UI 侧）：③ notifications/cancelled
  /// 下发（face，失败 [DEGRADE] 留痕）→ 环边界停下（loop.abort）→ 在途卡
  /// Cancelled 态。在途调用真实完成后 Finished 事件照常回填（结果优先于
  /// cancelled 标记）；未 Started 的后续调用/轮次被环丢弃。
  void _abort() {
    if (!_running) return;
    _watcher?.stop();
    _activeFace?.cancelActiveRequest(reason: 'user abort');
    _activeLoop?.abort();
    final entry = _activeCallEntry;
    if (entry != null && entry.phase == CallCardPhase.running) {
      setState(() {
        entry.phase = CallCardPhase.cancelled;
        entry.progressNote = '已中止（在途调用结果仍会回填）';
      });
    }
    _setPill('idle', CapsuleTone.idle);
  }

  static String _preview(String content) {
    final lines = content.trim().split('\n');
    final head = lines.take(2).join(' ⏎ ');
    return head.length > 120 ? '${head.substring(0, 120)}…' : head;
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网关/熔断联调')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: 'MCP Endpoint（须含 /mcp 路径）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StatusCapsule(label: _pillLabel, tone: _pillTone),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<LocalPluginInfo?>(
                    initialValue: _selectedLocal,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '本地插件（选中则走 Binder，否则走上方 HTTP）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<LocalPluginInfo?>(
                        value: null,
                        child: Text('— HTTP 端点 —'),
                      ),
                      for (final p in _localPlugins)
                        DropdownMenuItem<LocalPluginInfo?>(
                          value: p,
                          child: Text('${p.serverTitle} (${p.serverId})'),
                        ),
                    ],
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _selectedLocal = v),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _running ? null : _scanLocal,
                  child: const Text('扫描'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _keyCtrl,
              enabled: !_running,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'X-Api-Key（goodshare「MCP 服务」页可查看）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetry,
              ),
            ),
          ),
          SwitchListTile(
            value: _injectFaults,
            onChanged: _running
                ? null
                : (v) => setState(() => _injectFaults = v),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text(
              '故障注入（每工具前 2 次调用强制失败）',
              style: TextStyle(fontSize: Fsz.body),
            ),
            subtitle: const Text(
              '联调熔断排查卡专用：开启后运行，模型重试即触发',
              style: TextStyle(fontSize: Fsz.micro),
            ),
          ),
          SwitchListTile(
            value: _useScriptedEngine,
            onChanged: _running
                ? null
                : (v) => setState(() => _useScriptedEngine = v),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text(
              '脚本引擎（确定性走环，不经云端/模型）',
              style: TextStyle(fontSize: Fsz.body),
            ),
            subtitle: const Text(
              '与故障注入同开 = 必出熔断卡；单开 = 确定性走 L1 真执行',
              style: TextStyle(fontSize: Fsz.micro),
            ),
          ),
          SwitchListTile(
            value: _summarizeResults,
            onChanged: _running
                ? null
                : (v) => setState(() => _summarizeResults = v),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text(
              '工具结果摘要化（>1000T 端侧小模型摘要）',
              style: TextStyle(fontSize: Fsz.body),
            ),
            subtitle: const Text(
              'T6 上下文治理联调：回填前端侧摘要、失败保留原文'
              '（DEGRADE 留痕）；滑动窗口 N=6 恒开',
              style: TextStyle(fontSize: Fsz.micro),
            ),
          ),
          SwitchListTile(
            value: _injectMaskFailure,
            onChanged: _running
                ? null
                : (v) => setState(() => _injectMaskFailure = v),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text(
              '遮蔽失败注入（联调 PII 拦截卡）',
              style: TextStyle(fontSize: Fsz.body),
            ),
            subtitle: const Text(
              'T7 拦截卡三态：强制围栏抛 PiiMaskException 出'
              '「取消/明文一次」卡；须云端已预置，脚本引擎不经过',
              style: TextStyle(fontSize: Fsz.micro),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                initiallyExpanded: _byokStatus.startsWith('未预置'),
                title: Text(
                  '云端引擎预置（BYOK）',
                  style: const TextStyle(fontSize: Fsz.listPrimary),
                ),
                subtitle: Text(
                  _byokStatus,
                  style: const TextStyle(fontSize: Fsz.telemetrySm),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                children: [
                  DropdownButtonFormField<CloudProtocol>(
                    initialValue: _protocol,
                    decoration: const InputDecoration(
                      labelText: '协议',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: CloudProtocol.openaiCompatible,
                        child: Text('OpenAI 兼容（OpenAI/DeepSeek/Qwen/GLM）'),
                      ),
                      DropdownMenuItem(
                        value: CloudProtocol.anthropic,
                        child: Text('Anthropic'),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _protocol = v ?? _protocol),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _byokUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: '如 https://api.openai.com/v1',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _byokModelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型 ID',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _byokKeyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key（只入安全存储，不落明文）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FilledButton.tonal(
                        onPressed: _saveByok,
                        child: const Text('保存预置'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _promptCtrl,
                    enabled: !_running,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '任务指令（如：列出最近条目，再存一条备忘）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _running ? null : _run,
                  child: const Text('运行'),
                ),
                // M3-T2 Abort（architecture §10 级联的 UI 侧）：环内边界停下
                // + notifications/cancelled 下发 + 在途卡 Cancelled 态。
                if (_running) ...[
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _abort,
                    style: FilledButton.styleFrom(
                      foregroundColor: consoleTokens(context).danger,
                    ),
                    child: const Text('[ABORT]'),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 16),
          Expanded(
            child: _running || _track.isNotEmpty
                ? ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: _track.length,
                    itemBuilder: (context, i) => _render(context, _track[i]),
                  )
                : const Center(child: Text('运行一次任务以验证 L1/L2 网关与熔断链路')),
          ),
        ],
      ),
    );
  }

  Widget _render(BuildContext context, _Entry entry) {
    final t = consoleTokens(context);
    switch (entry) {
      case _TextEntry(:final text):
        if (text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(
            text.toString(),
            style: const TextStyle(fontSize: Fsz.reading, height: 1.5),
          ),
        );
      case _CallEntry e:
        return CallCard(
          tool: e.tool,
          phase: e.phase,
          progressNote: e.progressNote,
          preview: e.preview,
        );
      case _ConfirmEntry(
        :final pending,
        :final decision,
        :final decidedAt,
        :final completer,
      ):
        return ConfirmationCard(
          toolName: pending.toolName,
          argumentsJson: pending.argumentsJson,
          onDecision: decision == null
              ? (d) {
                  entry.decision = d;
                  entry.decidedAt = DateTime.now();
                  completer.complete(d);
                }
              : null,
          lockedDecision: decision,
          lockedAt: decidedAt,
        );
      case _BreakerEntry(
        :final report,
        :final wall,
        :final lockedText,
        :final decidedAt,
        :final completer,
      ):
        return BreakerCard(
          report: report,
          wall: wall,
          lockedText: lockedText,
          lockedAt: decidedAt,
          onBreaker: report == null
              ? null
              : (r) {
                  entry.lockedText = switch (r) {
                    RetryOnce() => '⟳ 已单步重试',
                    SkipOnce() => '⤼ 已跳过（错误回填）',
                    ManualResult() => '👤 已人工接管',
                  };
                  entry.decidedAt = DateTime.now();
                  completer.complete(r);
                },
          onStepWall: wall == null
              ? null
              : (relax) {
                  entry.lockedText = relax ? '⤒ 已放宽 +10 续跑' : '⊘ 已终止';
                  entry.decidedAt = DateTime.now();
                  completer.complete(relax);
                },
        );
      case _FenceEntry(
        :final info,
        :final decision,
        :final decidedAt,
        :final completer,
      ):
        return FenceBlockCard(
          engineName: info.engineName,
          failureMessage: info.failureMessage,
          onDecision: decision == null
              ? (sendRaw) {
                  entry.decision = sendRaw;
                  entry.decidedAt = DateTime.now();
                  completer.complete(sendRaw);
                }
              : null,
          lockedSendRaw: decision,
          lockedAt: decidedAt,
        );
      case _NoteEntry(:final text, :final danger):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            text,
            style: TextStyle(
              fontSize: Fsz.note,
              color: danger ? t.danger : t.terminalMuted,
            ),
          ),
        );
    }
  }
}

/// L2 确认卡委托：往轨道插入待决卡并 await 用户操作（§10 结算流——轮间 await
/// 不占连接）。
/// 故障注入装饰器（联调熔断卡专用，debug 页限定）：每个工具的前
/// [failTimesPerTool] 次调用强制 isError——模型重试同工具即撞两步熔断；
/// 注入耗尽后透传真实执行（排查卡「单步重试」会真成功，完整演示重试语义）。
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
class _ScriptedEngine implements CloudLlmEngine {
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

class _PageGate implements GateDelegate {
  _PageGate(this._state);

  final _GatewayLoopDebugPageState _state;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) {
    final entry = _ConfirmEntry(pending: pending);
    _state._add(entry);
    return entry.completer.future;
  }
}

/// 熔断/步数墙排查卡委托。
class _PageBlock implements BlockDelegate {
  _PageBlock(this._state);

  final _GatewayLoopDebugPageState _state;

  @override
  Future<BreakerResolution> onBreakerTripped(BreakerReport report) {
    // logcat 埋点：真机联调「没弹卡」取证用
    debugPrint(
      '[GatewayDebug] 熔断触发: ${report.toolName} x${report.consecutiveFailures}',
    );
    _state._setPill('breaker', CapsuleTone.danger);
    final entry = _BreakerEntry.breaker(report);
    _state._add(entry);
    return entry.completer.future.then((value) => value as BreakerResolution);
  }

  @override
  Future<bool> onStepWallReached(StepWallReport report) {
    final entry = _BreakerEntry.wall(report);
    _state._add(entry);
    return entry.completer.future.then((value) => value as bool);
  }
}

/// N7 围栏拦截确认委托（D4 有人值守面）：轨道插双选项卡并 await 用户裁决
/// （true=明文发送一次/false=取消），裁决经 FencedCloudEngine 分派。
class _PageFence implements PiiFenceDelegate {
  _PageFence(this._state);

  final _GatewayLoopDebugPageState _state;

  @override
  Future<bool> onMaskBlocked(PiiMaskBlockInfo info) {
    _state._setPill('fence', CapsuleTone.danger);
    final entry = _FenceEntry(info);
    _state._add(entry);
    return entry.completer.future;
  }
}
