/// M2-T3 grammar spike 探针页（仅 kDebugMode 可见入口）：LiteRT-LM
/// `ResponseFormat` 约束解码实证（architecture §2 首个 UNCERTAIN 的裁决输入）。
/// M4-T3 自 main.dart 拆出（ChatPage 首页接管后的 debug 菜单入口）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../llm/device_tier.dart';
import '../llm/llm.dart';

/// M2-T3 grammar spike 探针页（仅 kDebugMode 可见）：LiteRT-LM `ResponseFormat`
/// 约束解码实证（architecture §2 首个 UNCERTAIN 的裁决输入）。
///
/// 三探测同机同模型顺序跑，输出原文 + 耗时原样展示，不做任何静默修饰：
/// 1. 对照——无约束普通生成（随迁基线行为，兼测引擎冷启动耗时）；
/// 2. regex——正则约束（产出是否严格合模式）；
/// 3. json——JSON Schema 约束（产出是否严格合 schema）。
/// 判读口径：原生不支持时 sendMessage 抛错 → PlatformException → 日志带 message，
/// 探针行显示「失败」，即 UNCERTAIN 的证伪证据；合规产出 = 证实证据。
class GrammarSpikePage extends StatefulWidget {
  const GrammarSpikePage({super.key});

  @override
  State<GrammarSpikePage> createState() => _GrammarSpikePageState();
}

class _ProbeSpec {
  const _ProbeSpec(this.label, this.prompt, {this.format, this.maxTokens = 64});

  final String label;
  final String prompt;
  final LlmResponseFormat? format;
  final int maxTokens;
}

class _ProbeOutcome {
  _ProbeOutcome(this.spec);

  final _ProbeSpec spec;
  String? output;
  int? elapsedMs;
  bool failed = false;

  /// 失败时的人类可读原因（引擎不可用真值等），原样展示免排查盲区。
  String? error;
}

class _GrammarSpikePageState extends State<GrammarSpikePage> {
  static const _note =
      '周三下午 3 点和设计师对齐新版图标评审，周五前把 Q3 复盘初稿发到团队邮箱。';

  static final _probes = <_ProbeSpec>[
    _ProbeSpec(
      '① 对照（无约束）',
      '用一句话输出下面笔记的摘要：\n$_note',
    ),
    _ProbeSpec(
      '② regex 约束（严格 YYYY-MM-DD）',
      '输出一个日期，格式严格为 YYYY-MM-DD，取 2026 年 10 月 11 日：',
      format: LlmResponseFormat.regex(r'\d{4}-\d{2}-\d{2}'),
      maxTokens: 16,
    ),
    _ProbeSpec(
      '③ json schema 约束（summary + tags）',
      '对笔记输出 JSON：summary 为一句话摘要，tags 为 2-3 个关键词数组。\n$_note',
      format: LlmResponseFormat.jsonSchema(
        '{"type":"object","properties":{"summary":{"type":"string"},'
        '"tags":{"type":"array","items":{"type":"string"}}},'
        '"required":["summary","tags"]}',
      ),
      maxTokens: 128,
    ),
  ];

  final _outcomes = _probes.map(_ProbeOutcome.new).toList();
  bool _running = false;

  /// ④ 取消实证结果（§10 ①步机制验证：cancelProcess 能否秒级掐断在途生成）。
  String? _cancelProbeLine;

  /// ⑤ 预热实证结果（§2 预热策略验证：冷初始化耗时 vs 热后首生成）。
  String? _warmupProbeLine;

  /// ⑥ 设备探针结果（§16 门禁数据源与裁决展示）。
  String? _deviceProbeLine;

  @override
  void initState() {
    super.initState();
    // 打开即自动跑一轮：重跑闭环只差一次进页，不再依赖手点按钮
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    final engine = ChannelLlmEngine();
    if (!await engine.isAvailable) {
      final reason = await engine.unavailableReasonAsync();
      setState(() {
        for (final o in _outcomes) {
          o
            ..failed = true
            ..output = null
            ..elapsedMs = null
            ..error = reason;
        }
      });
      setState(() => _running = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('端侧引擎不可用：${reason ?? '未知原因'}')),
        );
      }
      return;
    }
    for (final o in _outcomes) {
      final sw = Stopwatch()..start();
      // generate 契约不抛（失败/空产出= null），失败判定与日志见 ChannelLlmEngine
      final out = await engine.generate(o.spec.prompt,
          maxTokens: o.spec.maxTokens, responseFormat: o.spec.format);
      sw.stop();
      if (!mounted) return;
      setState(() {
        o
          ..output = out
          ..elapsedMs = sw.elapsedMilliseconds
          ..failed = out == null;
      });
    }
    if (mounted) setState(() => _running = false);
  }

  /// ④ 取消实证：启动一个长生成（json 约束大 token 上限），800ms 后取消，
  /// 观测 generate 何时返回、返回什么。判读：若远早于正常产出时长返回
  /// （null 或部分产出）= cancelProcess 真掐断了原生推理（§10 ①步实证通过）。
  Future<void> _runCancelProbe() async {
    setState(() => _cancelProbeLine = '运行中…');
    final engine = ChannelLlmEngine();
    if (!await engine.isAvailable) {
      setState(() =>
          _cancelProbeLine = '✕ 端侧引擎不可用（先跑三探测取真值原因）');
      return;
    }
    final sw = Stopwatch()..start();
    final genDone = engine.generate(
      '写一篇 300 字关于端侧大模型的小短文：\n',
      maxTokens: 512,
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final cancelSw = Stopwatch()..start();
    final hit = await engine.cancelActive();
    final cancelMs = cancelSw.elapsedMilliseconds;
    final text = await genDone;
    sw.stop();
    if (!mounted) return;
    setState(() => _cancelProbeLine =
        'cancelActive 命中=$hit（取消调用耗时 ${cancelMs}ms）｜'
        'generate ${sw.elapsedMilliseconds}ms 后返回：'
        '${text == null ? 'null（无产出）' : '部分产出 ${text.length} 字：${text.trim()}'}');
  }

  /// ⑤ 预热实证：强制释放 → 冷预热计时（「离线引擎唤醒中」窗口实测）→ 热后首生成。
  /// 判读：冷预热秒级 vs 热后首生成亚秒级 = 预热策略收益实证。
  Future<void> _runWarmupProbe() async {
    setState(() => _warmupProbeLine = '释放引擎中…');
    final engine = ChannelLlmEngine();
    if (!await engine.isAvailable) {
      setState(() => _warmupProbeLine = '✕ 端侧引擎不可用（先跑三探测取真值原因）');
      return;
    }
    await engine.release();
    if (await engine.isWarmed()) {
      setState(() => _warmupProbeLine = '✕ 释放后仍报告已热（release 语义异常）');
      return;
    }
    setState(() => _warmupProbeLine = '离线引擎唤醒中…（冷加载权重）');
    final sw = Stopwatch()..start();
    final ok = await engine.warmup();
    sw.stop();
    if (!ok) {
      setState(() => _warmupProbeLine = '✕ 预热失败（见 debugPrint 日志）');
      return;
    }
    final warmMs = sw.elapsedMilliseconds;
    final sw2 = Stopwatch()..start();
    final text = await engine.generate('输出两个字：好的', maxTokens: 8);
    sw2.stop();
    if (!mounted) return;
    setState(() => _warmupProbeLine =
        '冷预热 ${warmMs}ms → 热后首生成 ${sw2.elapsedMilliseconds}ms'
        '（产出：${text == null ? 'null' : text.trim()}）');
  }

  /// ⑥ 设备探针：§16 门禁数据源与裁决展示（T7 调参的实测抓手）。
  Future<void> _runDeviceProbe() async {
    setState(() => _deviceProbeLine = '探测中…');
    final probe = await ChannelLlmEngine().deviceProbe();
    if (!mounted) return;
    if (probe == null) {
      setState(() => _deviceProbeLine = '✕ 探针不可用（非 Android/未实现）→ 门禁按未知放行');
      return;
    }
    final v = DeviceTierGate.check(probe);
    setState(() => _deviceProbeLine = '$probe → ${v.pass ? '✓ 放行' : '✕ 关闸'}（${v.reason}）');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grammar spike · 约束解码实证'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _running ? null : _run,
                      child: Text(_running ? '探测中…（冷启动较久）' : '运行三探测'),
                    ),
                    OutlinedButton(
                      onPressed: _running ? null : _runCancelProbe,
                      child: const Text('④ 取消实证'),
                    ),
                    OutlinedButton(
                      onPressed: _running ? null : _runWarmupProbe,
                      child: const Text('⑤ 预热实证'),
                    ),
                    OutlinedButton(
                      onPressed: _running ? null : _runDeviceProbe,
                      child: const Text('⑥ 设备探针'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '输出原样展示；失败 = 原生不支持（见 debugPrint 日志）',
                  style: TextStyle(fontSize: 12),
                ),
                if (_cancelProbeLine != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '④ 取消实证：$_cancelProbeLine',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ],
                if (_warmupProbeLine != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⑤ 预热实证：$_warmupProbeLine',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ],
                if (_deviceProbeLine != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⑥ 设备探针：$_deviceProbeLine',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 24),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final o in _outcomes)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(
                              child: Text(o.spec.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              o.elapsedMs == null
                                  ? (_running ? '' : '待运行')
                                  : '${o.elapsedMs}ms${o.failed ? ' · 失败(null)' : ''}',
                              style: TextStyle(
                                fontSize: 12,
                                color: o.failed ? Theme.of(context).colorScheme.error : null,
                              ),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          Text(
                            o.failed && o.error != null
                                ? '✕ ${o.error}'
                                : (o.output ?? (o.failed ? '（无产出）' : '—')),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: o.failed && o.error != null
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
