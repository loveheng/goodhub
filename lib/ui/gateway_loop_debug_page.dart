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
import 'package:goodhub/coordinator/debug_run_orchestrator.dart';
import 'package:goodhub/coordinator/fenced_cloud_engine.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/sampling.dart';

import 'components/breaker_card.dart';
import 'sections/byok_section.dart';
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

  /// MCP 令牌（goodshare「MCP 服务」页可查；与已归档的 ClaimLoopPage（archive/）
  /// 不持久化——debug 页不留凭据）。
  final _keyCtrl = TextEditingController();

  /// 故障注入（联调熔断卡专用，debug 页限定）：环内每工具前 N 次调用强制
  /// isError——模型重试同工具即撞「同工具连续 2 次报错」。默认关。
  /// 注入次数（每个工具前 2 次）随编排件实现，本页只持有开关。
  var _injectFaults = false;

  /// 脚本引擎（确定性走环，不经云端/模型）：真实模型吃瘪后可能换工具不重试，
  /// per-tool 熔断计数永远停在 1——脚本保证同工具连调两次，必出排查卡。
  var _useScriptedEngine = false;

  /// M3 sampling 配额（D3 拍板）：per-server 滑动窗口 20 次/60min，页面级
  /// 内存态——重启清零（防滥用非计费口径）。
  final SamplingQuota _samplingQuota = SamplingQuota();

  /// M3-T2 活跃会话柄：Abort 与卡状态机的接线目标（_run 期非空，finally 清）。
  /// Run 编排件 owner（window-slim P1-B）：装配活在 coordinator，本页只喂配置、
  /// 收事件、拿 [DebugRunOrchestrator.abort] 做中止。
  final _orchestrator = DebugRunOrchestrator();
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

  // —— 云端引擎预置（BYOK）——window-slim P1-B：本页不再自研第二份 BYOK 表单，
  // 直接嵌设置页同源的 ByokSection（同一 ByokStore，两处改动互相可见）。

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

  /// 面板级错误态（ByokSection 同口径：Rose 文案 + 重试入口）。
  Widget _panelError(
    ConsoleTokens t,
    String message,
    VoidCallback onRetry, {
    ValueKey<String>? key,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '⚠ $message',
          style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
        ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: key == null ? null : ValueKey('${key.value}-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ),
      ],
    ),
  );

  void _flash(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _promptCtrl.dispose();
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

  /// Run 启动（window-slim P1-B）：装配中枢已下沉 coordinator
  /// （`lib/coordinator/debug_run_orchestrator.dart`），本方法只剩三件事——
  /// 收集开关、实现 UI 端口（四张卡 + 状态带）、把编排事件流映射到轨道卡片。
  Future<void> _run() async {
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty || _running) return;
    setState(() {
      _running = true;
      _track.clear();
      _pillLabel = 'connecting';
      _pillTone = CapsuleTone.l1;
    });
    // M3-T2 卡死判定（D4 双档）：watcher 属窗口（UI 计时器），经回调挂进编排件
    // 的 sampling 在途包裹。
    _watcher = StuckWatcher(onStuck: _markActiveCallStuck);
    final localTarget = _selectedLocal;
    await for (final e in _orchestrator.run(
      DebugRunConfig(
        serverId: localTarget?.serverId ?? 'goodshare',
        systemPrompt: _systemPrompt,
        userPrompt: prompt,
        clientFactory: () => localTarget == null
            ? McpClient.http(
                baseUrl: _urlCtrl.text.trim(),
                apiKey: _keyCtrl.text.trim().isEmpty
                    ? null
                    : _keyCtrl.text.trim(),
              )
            : localPluginDiscovery.createClient(localTarget),
        gate: _PageGate(this),
        block: _PageBlock(this),
        fence: _PageFence(this),
        crossSource: _askCrossSource,
        majorJump: _askMajorJump,
        onPill: _setDebugPill,
        onSamplingBegin: () => _watcher?.samplingBegin(),
        onSamplingEnd: () => _watcher?.samplingEnd(),
        onNotice: () =>
            unawaited(HapticFeedback.selectionClick()), // §4.1 L1 药丸极轻微 tick
        injectFaults: _injectFaults,
        useScriptedEngine: _useScriptedEngine,
        summarizeResults: _summarizeResults,
        injectMaskFailure: _injectMaskFailure,
        quota: _samplingQuota,
      ),
    )) {
      switch (e) {
        case DebugRunText(:final text):
          _add(_TextEntry(text));
        case DebugRunDelta(:final delta):
          _appendText(delta);
        case DebugRunNote(:final text, :final danger):
          _add(_NoteEntry(text, danger: danger));
        case DebugRunCallStarted(:final tool):
          _setPill(tool, CapsuleTone.l1);
          // Started 即插卡（Emerald 执行中），等 progress 帧 / 终态事件推进相位。
          final entry = _CallEntry(tool: tool);
          _activeCallEntry = entry;
          _add(entry);
          _watcher?.start();
        case DebugRunCallProgress(
          :final tool,
          :final progress,
          :final total,
          :final message,
        ):
          final entry = _activeCallEntry;
          if (entry != null && entry.tool == tool) {
            setState(() {
              final tail = message == null ? '' : ' · $message';
              entry.progressNote = total != null
                  ? '$progress/$total$tail'
                  : '$progress$tail';
            });
          }
          _watcher?.onProgressFrame();
        case DebugRunCallFinished(
          :final tool,
          :final content,
          :final isError,
        ):
          final entry = _activeCallEntry;
          final phase = isError
              ? CallCardPhase.failed
              : CallCardPhase.success;
          final preview = _preview(content);
          if (entry != null && entry.tool == tool) {
            // 真实结果优先于 Abort 的 cancelled 标记（在途调用完成后照常回填）
            setState(() {
              entry
                ..phase = phase
                ..preview = preview
                ..progressNote = null;
            });
          } else {
            _add(_CallEntry(tool: tool)..phase = phase..preview = preview);
          }
          _activeCallEntry = null;
          _watcher?.stop();
        case DebugRunFinished(:final turns):
          _add(_NoteEntry('✓ 收尾（$turns 轮）', danger: false));
      }
    }
    _watcher?.stop();
    _watcher = null;
    _activeCallEntry = null;
    if (mounted) setState(() => _running = false);
  }

  /// 状态带口径适配：编排件三档语义 → ui `CapsuleTone`。
  void _setDebugPill(String label, DebugPillTone tone) => _setPill(
    label,
    switch (tone) {
      DebugPillTone.idle => CapsuleTone.idle,
      DebugPillTone.busy => CapsuleTone.l1,
      DebugPillTone.danger => CapsuleTone.danger,
    },
  );

  /// D5 跨源注水同意卡（窗口实现：恒 L2 弹卡、无豁免勾选；预览空 → 允许禁用）。
  Future<bool> _askCrossSource(
    String handle,
    String fromServerId,
    String toServerId,
    String preview,
  ) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: EdgeInsets.zero,
        content: CrossSourceConsentCard(
          handle: handle,
          fromServer: fromServerId,
          toServer: toServerId,
          preview: preview,
          onDecision: (v) => Navigator.pop(ctx, v),
        ),
      ),
    );
    return r == true;
  }

  /// CoW major 跃迁裁决卡（true = 弃本地覆写回 server 版）。
  Future<bool> _askMajorJump(String name, String from, String to) async {
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
    _orchestrator.abort(); // 编排件持有 face/loop 柄： cancellations 下发 + 环停
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
                title: Text(
                  '云端引擎预置（BYOK）',
                  style: const TextStyle(fontSize: Fsz.listPrimary),
                ),
                subtitle: const Text(
                  'Agent Loop 带工具恒走云端，端侧不承接——无云端即「无可用引擎」；'
                  '表单与设置页同源（同一 ByokStore，两处改动互相可见）',
                  style: TextStyle(fontSize: Fsz.telemetrySm),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                children: [
                  ByokSection(
                    store: ByokStore(),
                    onFlash: _flash,
                    errorRowBuilder: _panelError,
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
