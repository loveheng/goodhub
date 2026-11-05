/// 资源中心 · 端侧模型段（资产面，2026-11-02）：模型目录展示、本地导入（2026-10-30
/// 拍板：模型改导入制，废弃在线 OTA——模型体积过大无在线存储）、选择持久化、删除。
///
/// **IA 归位（2026-11-02）**：本段只管「资产面」（导入/删除/选择）；端侧**配置**
/// （启用偏好 / GenieX 增配运行库 / 电池白名单）已迁出至设置页 `OnDeviceConfigSection`
/// （用户拍板：配置归设置、资产归资源中心——导入留资源中心，配置回设置）。引擎装载 /
/// 会话创建仍由启动引导与 hybrid 装配承载（导入完成后受理 loadModel 的就绪轮询照旧）。
/// 导入进度经 [OnDeviceAssetManager.importFromPickedFiles] 的 onProgress 驱动。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../components/panel_error_row.dart';
import '../components/on_device_model_import.dart';
import '../tokens/console_tokens.dart';
import '../../coordinator/on_device_admin.dart';
import '../../llm/on_device_model_catalog.dart';
import '../../llm/on_device_history_policy_store.dart';

/// 段 widget：注入 [assetManager]（生产 = 单例，测试传假件）、[onFlash]
/// （页面级 toast 口径）、[errorRowBuilder]（面板级错误态统一件）。
class OnDeviceModelSection extends StatefulWidget {
  const OnDeviceModelSection({
    super.key,
    OnDeviceAssetManager? assetManager,
    this.onFlash,
    this.errorRowBuilder,
  }) : _assetManagerOverride = assetManager;

  final OnDeviceAssetManager? _assetManagerOverride;
  final void Function(String message)? onFlash;
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key})? errorRowBuilder;

  @override
  State<OnDeviceModelSection> createState() => _OnDeviceModelSectionState();
}

class _OnDeviceModelSectionState extends State<OnDeviceModelSection>
    with AutomaticKeepAliveClientMixin {
  /// ListView 懒构建会把滚出视口的 sliver child 销毁重建——段内领域态
  /// （选择/进度/错误态）随之丢失，故段一律申请 keepAlive（闸门测试在案）。
  @override
  bool get wantKeepAlive => true;

  OnDeviceAssetManager get _assets =>
      widget._assetManagerOverride ?? OnDeviceAssetManager.instance;

  String? _selectedDir;
  List<InstalledModel> _models = <InstalledModel>[];
  bool _busy = false;
  String? _error;

  /// 每模型历史策略偏好快照（键 = dirName；缺省 = 默认 ①，读失败不阻塞资产面）。
  final Map<String, String> _policyIds = <String, String>{};

  /// 运行环境实况票据（2026-11-05 用户裁决：资源中心列模型运行环境有助
  /// 发现系统误判）。null = :engine 不可达/未知态——**不猜**，行内不渲染
  /// 实况行（未装载是常态，不可达只在实际使用端侧时报错面可见）。
  SessionTicket? _ticket;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// 注册表（身份唯一源，2026-10-31）：已装模型来自磁盘扫描（经注入的
  /// assetManager 支持目录）；选择持久化按 dirName 解析。选择器经静态
  /// read() 读真实支持目录（测试环境降级为 null，不影响主功能；生产与
  /// listInstalled 同目录，一致）。
  Future<void> _refresh() async {
    try {
      final installed = await _assets.listInstalled();
      final selected = await OnDeviceModelSelection.read();
      final policyIds = <String, String>{
        for (final m in installed)
          m.dirName: await HistoryPolicySelection.readForModel(m.dirName,
              device: true),
      };
      // 实况票据（诊断只读，失败不阻塞资产面——null 语义 = 不渲染实况行）。
      SessionTicket? ticket;
      try {
        ticket = await OnDeviceAdmin.sessionTicket();
      } on Object catch (_) {
        ticket = null;
      }
      if (!mounted) return;
      setState(() {
        _models = installed;
        _selectedDir = selected?.dirName;
        _policyIds
          ..clear()
          ..addAll(policyIds);
        _ticket = ticket;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '端侧模型目录读取失败：$e');
    }
  }

  Future<void> _delete(InstalledModel m) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除端侧模型'),
        content:
            Text('移除已导入的 ${m.displayName} 资产？（下次使用需重新导入）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _assets.markDirty(model: m.toOption());
      if (!mounted) return;
      await _refresh();
      if (!mounted) return;
      widget.onFlash?.call('${m.displayName} 已删除');
    } catch (e) {
      if (mounted) setState(() => _error = '删除失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _select(InstalledModel m) async {
    // 首发节奏关闸（decisions.md ADR 2026-11-01）：llama.cpp 通路模型不可选。
    if (!kOnDeviceLlamaCppEnabled && m.runtime == OnDeviceRuntime.llamaCpp) {
      widget.onFlash?.call('llama.cpp 通路暂未开放（首发从 LiteRT-LM 起步）');
      return;
    }
    await OnDeviceModelSelection.write(m.dirName);
    if (!mounted) return;
    setState(() => _selectedDir = m.dirName);
    widget.onFlash?.call(
        '端侧模型已切换为 ${m.displayName}，首次使用端侧时自动加载');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('端侧模型',
                style: TextStyle(
                    fontSize: Fsz.telemetry, color: t.l2Accent)),
            const SizedBox(height: 4),
            // 已装模型（注册表，身份唯一源）；导入入口同段（2026-11-02 能力中心
            // 拍板：整段迁入资源中心「端侧模型」tab，流程走共享组件
            // OnDeviceModelImport 单源，禁复制；配置部分另迁设置页）。
            TextButton(
              key: const ValueKey('on-device-model-import-free'),
              onPressed: _busy ? null : () {
                unawaited(OnDeviceModelImport.run(
                  context,
                  onFlash: widget.onFlash,
                  onImported: _refresh,
                ));
              },
              child: const Text('＋ 导入模型（GGUF / QAIRT 包）'),
            ),
            const SizedBox(height: 6),
            for (final m in _models) ...[
              _modelRow(t, m),
              const SizedBox(height: 6),
            ],
            if (_error != null) ...[
              const SizedBox(height: 4),
              (widget.errorRowBuilder ?? panelErrorRow)(
                  t, _error!, () => unawaited(_refresh())),
            ],
          ],
        ),
      ),
    );
  }

  /// 运行时标识 → 白话徽标（NPU / CPU / LiteRT-LM / 自动）。
  String _runtimeLabel(String r) =>
      r == OnDeviceRuntime.qairt ? 'NPU'
          : r == OnDeviceRuntime.llamaCpp ? 'CPU'
              : r == OnDeviceRuntime.litertlm ? 'LiteRT-LM'
                  : '自动';

  /// runtimeDetail 解析（Kotlin 侧格式：`runtime/计算单元[|unfit=原因]
/// |sdk=版本`，2026-11-05 实况面）。null = 非本段承载格式（LiteRT-LM 系
  /// 空串），行内不渲染实况。
  ({String runtime, String unit, String? unfit, String sdk})? _parseDetail(
      String d) {
    if (d.isEmpty) return null;
    final parts = d.split('|');
    final head = parts.first.split('/');
    final unit = head.length > 1 ? head[1] : '';
    String? unfit;
    String sdk = '';
    for (final p in parts.skip(1)) {
      if (p.startsWith('unfit=')) {
        unfit = p.substring(5);
      } else if (p.startsWith('sdk=')) {
        sdk = p.substring(4);
      }
    }
    return (runtime: head.first, unit: unit, unfit: unfit, sdk: sdk);
  }

  /// 实况档位白话（误判发现面）：正常 = 「实况：NPU 档」；失配留痕 =
  /// 「实况：GPU 档（NPU 不适用已记录：…）」——直接回答「为什么跑 GPU」。
  String? _liveLabel(SessionTicket ticket, InstalledModel m) {
    if (!ticket.modelId.startsWith('${m.dirName}@') &&
        ticket.modelId != m.dirName) {
      return null; // 票据不属于本模型（当前装载的是别的模型）
    }
    final d = _parseDetail(ticket.runtimeDetail);
    if (d == null) return null;
    final unit = d.unit.isEmpty ? '' : '${d.unit} 档';
    if (d.unfit != null) {
      return '实况：$unit（NPU 不适用已记录：${d.unfit}）';
    }
    return '实况：$unit'
        '${d.sdk.isEmpty ? '' : ' · geniex ${d.sdk}'}'
        ' · 状态 ${ticket.status.name}';
  }

  String _sizeLabel(int bytes) =>
      bytes >= (1 << 30)
          ? '${(bytes / (1 << 30)).toStringAsFixed(1)}GB'
          : '${bytes ~/ (1 << 20)}MB';

  /// 已装模型行（注册表条目）：展示名 + 运行时徽标 + 体积 + 使用/删除 +
  /// 历史策略选择（策略挂模型本身，2026-11-02 用户拍板）。
  Widget _modelRow(ConsoleTokens t, InstalledModel m) {
    final selected = _selectedDir == m.dirName;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.displayName,
                  style: TextStyle(
                      fontSize: Fsz.body,
                      color: selected ? t.l1Ok : t.l1Info)),
              Text(
                '${_runtimeLabel(m.runtime)}  ${_sizeLabel(m.totalBytes)}'
                '${m.templateVerified == false ? '  未验证' : ''}'
                '${selected ? '  当前使用' : ''}',
                style: TextStyle(
                    fontSize: Fsz.note,
                    color: selected ? t.l1Ok : t.terminalMuted),
              ),
              if (_ticket != null && _liveLabel(_ticket!, m) != null)
                Text(
                  _liveLabel(_ticket!, m)!,
                  key: ValueKey('on-device-model-live-${m.dirName}'),
                  style: TextStyle(
                      fontSize: Fsz.telemetrySm,
                      color: _ticket!.runtimeDetail.contains('unfit=')
                          ? t.l2Warn
                          : t.terminalMuted),
                ),
              _policyPicker(t, m.dirName),
            ],
          ),
        ),
        if (!selected)
          TextButton(
            key: ValueKey('on-device-model-select-${m.dirName}'),
            onPressed: _busy ? null : () => unawaited(_select(m)),
            child: const Text('使用'),
          ),
        TextButton(
          key: ValueKey('on-device-model-delete-${m.dirName}'),
          onPressed: _busy ? null : () => unawaited(_delete(m)),
          child: Text('删除', style: TextStyle(color: t.danger)),
        ),
      ],
    );
  }

  /// 单模型历史策略选择（紧凑下拉；写偏好即时生效，下次请求按新策略拼装）。
  Widget _policyPicker(ConsoleTokens t, String dirName) {
    final id = _policyIds[dirName] ?? HistoryPolicySelection.kDeviceDefaultPolicyId;
    return Row(children: [
      Text('历史策略',
          style: TextStyle(fontSize: Fsz.telemetrySm, color: t.terminalMuted)),
      DropdownButton<String>(
        key: ValueKey('history-policy-model-$dirName'),
        value: id,
        underline: const SizedBox.shrink(),
        isDense: true,
        items: [
          HistoryPolicyIds.dropOldest,
          HistoryPolicyIds.anchorRecent,
          HistoryPolicyIds.rollingSummary,
          HistoryPolicyIds.bare,
        ]
            .map((pid) => DropdownMenuItem(
                value: pid,
                child: Text(HistoryPolicySelection.label(pid),
                    style: TextStyle(
                        fontSize: Fsz.telemetrySm,
                        color:
                            pid == HistoryPolicyIds.bare ? t.danger : t.l1Info))))
            .toList(),
        onChanged: (pid) async {
          if (pid == null) return;
          try {
            await HistoryPolicySelection.writeForModel(dirName, pid);
            if (!mounted) return;
            setState(() => _policyIds[dirName] = pid);
            widget.onFlash?.call(
                '历史策略已更新：${HistoryPolicySelection.label(pid)}（即时生效）');
          } on Object catch (e) {
            if (mounted) widget.onFlash?.call('历史策略保存失败：$e');
          }
        },
      ),
    ]);
  }
}
