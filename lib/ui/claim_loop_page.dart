/// M1 最小壳任务循环页（认领→心跳→回写闭环验证）。M4-T3/D9 起 ChatPage 接管
/// 应用首页，本页降级为 debug 入口（ChatPage 调试菜单），页面本体不变。
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../coordinator/degradation_controller.dart';
import '../coordinator/hybrid_assembly.dart';
import '../coordinator/hybrid_inference.dart';
import '../task/task_loop_service.dart';
import 'gateway_loop_debug_page.dart';
import 'grammar_spike_page.dart';
import 'services_hall_page.dart';
import 'tokens/console_tokens.dart';

/// M1 最小壳：claim → 推理占位 → touch 心跳 → apply 回写 闭环验证页。
/// 人类入口（本页按钮）与未来自动循环（AI 入口）共用 [TaskLoopService]——
/// 双入口对称（仿 goodshare：业务住服务层，两个入口都是薄壳）。
class ClaimLoopPage extends StatefulWidget {
  const ClaimLoopPage({super.key});

  @override
  State<ClaimLoopPage> createState() => _ClaimLoopPageState();
}

class _ClaimLoopPageState extends State<ClaimLoopPage> {
  static const _defaultUrl = 'http://10.0.2.2:8765/mcp';
  final _urlCtrl = TextEditingController(text: _defaultUrl);
  final _keyCtrl = TextEditingController();
  TaskLoopService? _service;

  /// 降级判据记忆（超时/5xx 冷却）跨 Run 保留——围栏映射会话随引擎按 Run
  /// 重建（D2），判据状态不随之丢失。
  DegradationController? _degradation;
  bool _running = false;
  String _status = 'idle';
  final _log = <String>[];

  void _logLine(String line) {
    setState(() {
      _log.insert(
        0,
        '${DateTime.now().toIso8601String().substring(11, 19)} $line',
      );
    });
  }

  /// 事件流 → 日志行（人类入口的渲染适配；AI 入口在此换遥测收集器）。
  String _describe(TaskLoopEvent e) => switch (e) {
    ClaimStarted() => '→ claim_ai_task',
    QueueIdle() => '✓ idle（队列无任务）',
    TaskClaimed(
      :final taskId,
      :final taskAction,
      :final textLength,
      :final version,
    ) =>
      '✓ 认领 $taskId action=$taskAction len=$textLength v=$version',
    HeartbeatSent() => '✓ touch',
    Applied(:final taskId, :final snapshotKeys) =>
      '✓ apply 回写成功 ($taskId keys: $snapshotKeys)',
    NotFoundClosed(:final taskId, :final note) =>
      '⚠ not_found $taskId: $note（已收尾）',
    LoopFailed(:final error) => '✕ $error',
  };

  /// 事件处理器（build 重挂与 _runOnce 懒构造后直挂共用——service 每次 Run
  /// 重建，build 只发生在重建前，运行中事件若不在构造后直挂会全部丢失）。
  void _onLoopEvent(TaskLoopEvent e) {
    _logLine(_describe(e));
    if (e is TaskClaimed) setState(() => _status = 'running ${e.taskId}');
  }

  Future<void> _runOnce() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      // 按 Run 装配（N7 围栏 D2：映射会话=一次 Run；T5b）：BYOK profile + 密钥
      // → 云端（外包围栏装饰器）；端侧桥兜底（装配内部 DEGRADE 留痕）。
      final engine = await assembleDefaultHybridEngine(
        controller: _degradation ??= DegradationController(),
      );
      _service = buildApi(
        baseUrl: _urlCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim().isEmpty ? null : _keyCtrl.text.trim(),
        inference: HybridTaskInference(engine: engine),
      );
      // 事件直挂：build 的重挂发生在本赋值之前（service 是新实例），不直挂
      // 则本次运行的事件（含 LoopFailed 失败原因）到不了日志区。
      _service!.onEvent = _onLoopEvent;
    } on FormatException catch (e) {
      _logLine('✕ URL 无效: $e');
      setState(() => _running = false);
      return;
    }
    final service = _service!;
    try {
      final processed = await service.runOnce();
      setState(() => _status = processed ? 'done' : 'idle');
    } on Exception {
      // 失败日志已由 LoopFailed 事件行输出，此处只落终态
      setState(() => _status = 'error');
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 服务懒构造后挂事件回调（build 重挂兜底；运行中事件由 _runOnce 构造后直挂）
    _service?.onEvent = _onLoopEvent;
    final t = consoleTokens(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('GoodHub · M1 壳'),
        actions: [
          // M2-T3 grammar spike 探针入口（仅 debug 构建）：约束解码实证用
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.science_outlined),
              tooltip: 'Grammar spike 探针',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const GrammarSpikePage(),
                ),
              ),
            ),
          // M3-T4 服务大厅：Skill 覆写管理 + 跨源授权面板（正式面）
          IconButton(
            icon: const Icon(Icons.hub_outlined),
            tooltip: '服务大厅',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ServicesHallPage()),
            ),
          ),
          // M2-T4c 网关/熔断联调入口（仅 debug 构建）：L1/L2 网关 + 熔断排查卡验证
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: '网关/熔断联调',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const GatewayLoopDebugPage(),
                ),
              ),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            TextField(
              controller: _urlCtrl,
              // 运行中锁输入；运行结束后允许改地址重跑（_runOnce 按 Run 重建）。
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: 'MCP Endpoint',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.body),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keyCtrl,
              enabled: !_running,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'X-Api-Key（goodshare MCP 服务页，可留空）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.body),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: _running ? null : _runOnce,
                  child: Text(_running ? 'Running…' : 'Claim & Apply 一次'),
                ),
                const SizedBox(width: 12),
                Text('状态: $_status'),
              ],
            ),
            const Divider(height: 24),
            const Align(alignment: .centerLeft, child: Text('日志（新→旧）')),
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
