/// 设置页 · 端侧模型段（on-device 正式功能，S2-5 起替代 dart-define 资产
/// 指向 PATCH）：模型目录展示、下载/重下（OTA 通道 + sha256 校验 + 原子
/// 替换）、选择持久化、删除。
///
/// 职责边界：本段只管「资产面」（下载/删除/选择）；引擎装载/会话创建仍由
/// 启动引导与 hybrid 装配承载（下载完成后受理 loadModel 的就绪轮询照旧）。
/// 下载进度经 [OnDeviceAssetManager.ensureAssets] 的 onProgress 回调驱动。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../components/panel_error_row.dart';
import '../tokens/console_tokens.dart';
import '../../gateway_api/gateway_control.dart';
import '../../llm/on_device_asset_manager.dart';
import '../../llm/on_device_gate_override.dart';
import '../../llm/on_device_model_catalog.dart';

/// 电池白名单查询/申请注入位（测试替换，范式同 gateway_section）。
typedef BatteryStatusFn = Future<bool> Function();
typedef BatteryRequestFn = Future<bool> Function();

/// 段 widget：注入 [assetManager]（生产 = 单例，测试传假件）、[onFlash]
/// （页面级 toast 口径）、[errorRowBuilder]（面板级错误态统一件）。
class OnDeviceModelSection extends StatefulWidget {
  const OnDeviceModelSection({
    super.key,
    OnDeviceAssetManager? assetManager,
    this.onFlash,
    this.errorRowBuilder,
    this.batteryStatusOverride,
    this.batteryRequestOverride,
  }) : _assetManagerOverride = assetManager;

  final OnDeviceAssetManager? _assetManagerOverride;
  final void Function(String message)? onFlash;
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key})? errorRowBuilder;
  final BatteryStatusFn? batteryStatusOverride;
  final BatteryRequestFn? batteryRequestOverride;

  @override
  State<OnDeviceModelSection> createState() => _OnDeviceModelSectionState();
}

class _OnDeviceModelSectionState extends State<OnDeviceModelSection>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  /// ListView 懒构建会把滚出视口的 sliver child 销毁重建——段内领域态
  /// （选择/进度/错误态）随之丢失，故段一律申请 keepAlive（闸门测试在案）。
  @override
  bool get wantKeepAlive => true;

  OnDeviceAssetManager get _assets =>
      widget._assetManagerOverride ?? OnDeviceAssetManager.instance;

  String? _selectedId;
  final Set<String> _installed = <String>{};
  bool _busy = false;
  String? _downloadingId;
  String _progressText = '';
  String? _error;

  /// 门禁覆盖偏好（§16 用户授权覆盖层）快照；读取完成前为 null（UI 暂不显）。
  GateOverride? _gateOverride;

  /// 电池优化白名单状态（true = 已加入 / false = 未加入 / null = 未知未查）。
  ///
  /// S3-5 OEM 冻结防护（§6.2 ③）：厂商省电策略对后台/被冻结进程可强杀
  /// `:engine`（SIGKILL 且不下发 trim），引导用户加入白名单降低长生成
  /// 中断概率——端侧场景与网关场景共用同一白名单（应用级）。
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    unawaited(_refreshBatteryExemption());
    unawaited(_refreshGateOverride());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统白名单弹窗返回 → 复查状态（弹窗里点「允许」当场不会回传）。
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshBatteryExemption());
    }
  }

  /// 复查电池白名单状态（查询失败按未知处理，不阻断模型段主功能）。
  Future<void> _refreshBatteryExemption() async {
    try {
      final exempt =
          await (widget.batteryStatusOverride ?? gatewayBatteryExemptionStatus)();
      if (!mounted) return;
      setState(() => _batteryExempt = exempt);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-panel: 电池白名单状态查询失败: $e');
    }
  }

  /// 跳系统申请电池优化白名单（OEM 省电机制防冻结/防杀的关键一步）。
  Future<void> _requestBatteryExemption() async {
    try {
      final ok =
          await (widget.batteryRequestOverride ?? requestGatewayBatteryExemption)();
      if (!mounted) return;
      // 系统弹窗返回后当场复查（弹窗里点「允许」不会回传结果）。
      widget.onFlash?.call(ok ? '已加入电池优化白名单' : '申请弹窗已发起——请在系统弹窗确认「允许」');
      await _refreshBatteryExemption();
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-panel: 电池白名单申请失败: $e');
      if (mounted) widget.onFlash?.call('白名单申请失败：$e');
    }
  }

  Future<void> _refresh() async {
    try {
      final selected = await OnDeviceModelSelection.read();
      final installed = <String>{};
      for (final option in kOnDeviceModelCatalog) {
        if (await _assets.isInstalled(option)) installed.add(option.id);
      }
      if (!mounted) return;
      setState(() {
        _selectedId = selected?.id;
        _installed
          ..clear()
          ..addAll(installed);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '端侧模型目录读取失败：$e');
    }
  }

  /// 门禁覆盖偏好（§16 用户授权覆盖层）：读取用户对三维度门禁与偏好/强行的覆盖。
  Future<void> _refreshGateOverride() async {
    try {
      final ov = await OnDeviceGateOverride.read();
      if (!mounted) return;
      setState(() => _gateOverride = ov);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-panel: 门禁覆盖偏好读取失败: $e');
    }
  }

  Future<void> _setPrefer(bool v) async {
    await OnDeviceGateOverride.writePreferOnDevice(v);
    if (!mounted) return;
    setState(() => _gateOverride = _gateOverride!.copyWith(preferOnDevice: v));
    widget.onFlash?.call(v ? '已设为优先使用端侧' : '已恢复云端优先');
  }

  Future<void> _setIgnoreAvailRam(bool v) async {
    await OnDeviceGateOverride.writeIgnoreAvailRam(v);
    if (!mounted) return;
    setState(() => _gateOverride = _gateOverride!.copyWith(ignoreAvailRam: v));
  }

  Future<void> _setIgnoreBattery(bool v) async {
    await OnDeviceGateOverride.writeIgnoreBattery(v);
    if (!mounted) return;
    setState(() => _gateOverride = _gateOverride!.copyWith(ignoreBattery: v));
  }

  Future<void> _setIgnoreThermal(bool v) async {
    await OnDeviceGateOverride.writeIgnoreThermal(v);
    if (!mounted) return;
    setState(() => _gateOverride = _gateOverride!.copyWith(ignoreThermal: v));
  }

  /// 紧急强行启用：危险操作，开启前显式确认风险提示。
  Future<void> _setForce(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠ 紧急强行启用端侧'),
          content: const Text(
            '将绕过全部设备门禁（含内存 / 电量 / 温控）。弱设备上可能 OOM、'
            '过热降频或快速掉电；端侧失败时若无云端将直接报错。'
            '仅紧急场合开启，用后建议关闭。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('仍要开启'),
            ),
          ],
        ),
      );
      if (ok != true) {
        if (mounted) {
          setState(
            () => _gateOverride = _gateOverride!.copyWith(forceOnDevice: false),
          );
        }
        return;
      }
    }
    await OnDeviceGateOverride.writeForceOnDevice(v);
    if (!mounted) return;
    setState(() => _gateOverride = _gateOverride!.copyWith(forceOnDevice: v));
    widget.onFlash?.call(v ? '已强行启用端侧（绕过门禁）' : '已关闭强行启用');
  }

  Widget _toggleRow(
    ConsoleTokens t,
    String label,
    bool value,
    Future<void> Function(bool) onChanged, {
    bool danger = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: Fsz.note,
              color: danger ? t.danger : t.l1Info,
            ),
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: danger ? t.danger : null,
          onChanged: (v) => unawaited(onChanged(v)),
        ),
      ],
    );
  }

  Future<void> _download(OnDeviceModelOption option) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _downloadingId = option.id;
      _error = null;
      _progressText = '准备下载…';
    });
    try {
      final dir = await _assets.ensureAssets(
        model: option,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            switch (p.phase) {
              case 'manifest':
                _progressText = '读取分发清单…';
              case 'file':
                final pct = p.totalBytes > 0
                    ? (p.receivedBytes * 100 ~/ p.totalBytes)
                    : 0;
                _progressText =
                    '下载中 $pct%（${p.receivedBytes ~/ 1048576}/${p.totalBytes ~/ 1048576}MB）';
              case 'done':
                _progressText = p.detail ?? '完成';
            }
          });
        },
      );
      if (dir == null) {
        if (mounted) {
          setState(() {
            _error = '下载或校验失败（磁盘门禁/网络/sha256），见日志';
            _progressText = '';
          });
        }
        return;
      }
      await OnDeviceModelSelection.write(option.id);
      if (!mounted) return;
      setState(() {
        _installed.add(option.id);
        _selectedId = option.id;
        _progressText = '';
      });
      widget.onFlash?.call('${option.displayName} 已就绪，首次使用端侧时自动加载');
    } catch (e) {
      if (mounted) setState(() => _error = '下载失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadingId = null;
        });
      }
    }
  }

  Future<void> _delete(OnDeviceModelOption option) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除端侧模型'),
        content: Text('移除已下载的 ${option.displayName} 资产？（下次使用需重新下载）'),
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
      await _assets.markDirty(model: option);
      if (!mounted) return;
      setState(() {
        _installed.remove(option.id);
        if (_selectedId == option.id) _selectedId = null;
      });
      widget.onFlash?.call('${option.displayName} 已删除');
    } catch (e) {
      if (mounted) setState(() => _error = '删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(OnDeviceModelOption option) async {
    await OnDeviceModelSelection.write(option.id);
    if (!mounted) return;
    setState(() => _selectedId = option.id);
    widget.onFlash?.call('端侧模型已切换为 ${option.displayName}，首次使用端侧时自动加载');
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
            Text('端侧模型（NPU）',
                style: TextStyle(
                    fontSize: Fsz.telemetry, color: t.l2Accent)),
            const SizedBox(height: 4),
            if (_batteryExempt == false && (_installed.isNotEmpty || _selectedId != null)) ...[
              _batteryExemptRow(t),
              const SizedBox(height: 6),
            ],
            if (_gateOverride != null) ...[
              Text('端侧启用与门禁（用户覆盖）',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.l2Accent)),
              const SizedBox(height: 4),
              _toggleRow(t, '优先使用端侧（云端可用也走端侧）',
                  _gateOverride!.preferOnDevice, _setPrefer),
              _toggleRow(t, '忽略可用内存门槛（2.5GB，针对大内存机后台占用）',
                  _gateOverride!.ignoreAvailRam, _setIgnoreAvailRam),
              _toggleRow(t, '忽略电量 / 省电模式门禁',
                  _gateOverride!.ignoreBattery, _setIgnoreBattery),
              _toggleRow(t, '忽略温控门禁',
                  _gateOverride!.ignoreThermal, _setIgnoreThermal),
              _toggleRow(t, '⚠ 紧急强行启用（绕过全部门禁，可能 OOM / 过热）',
                  _gateOverride!.forceOnDevice, _setForce, danger: true),
              const SizedBox(height: 6),
            ],
            for (final option in kOnDeviceModelCatalog) ...[
              _modelRow(t, option),
              const SizedBox(height: 6),
            ],
            if (_progressText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(_progressText,
                    style: TextStyle(
                        fontSize: Fsz.telemetry, color: t.l1Info)),
              ),
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

  Widget _batteryExemptRow(ConsoleTokens t) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '⚡ 长生成保活：尚未加入电池优化白名单——厂商省电机制可能'
            '冻结/强杀后台 :engine 进程，中断本地生成',
            style: TextStyle(fontSize: Fsz.telemetrySm, color: t.danger),
          ),
        ),
        TextButton(
          key: const ValueKey('on-device-battery-exempt-request'),
          onPressed: () => unawaited(_requestBatteryExemption()),
          child: const Text('去设置'),
        ),
      ],
    );
  }

  Widget _modelRow(ConsoleTokens t, OnDeviceModelOption option) {
    final installed = _installed.contains(option.id);
    final selected = _selectedId == option.id;
    final downloading = _downloadingId == option.id;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(option.displayName,
                  style: TextStyle(
                      fontSize: Fsz.body,
                      color: selected ? t.l1Ok : t.l1Info)),
              Text(
                installed
                    ? (selected ? '已下载 · 当前使用' : '已下载')
                    : (downloading ? '下载中…' : '未下载'),
                style: TextStyle(
                    fontSize: Fsz.note,
                    color: selected ? t.l1Ok : t.terminalMuted),
              ),
            ],
          ),
        ),
        if (!installed)
          TextButton(
            key: ValueKey('on-device-model-download-${option.id}'),
            onPressed: _busy ? null : () => unawaited(_download(option)),
            child: const Text('下载'),
          )
        else ...[
          if (!selected)
            TextButton(
              key: ValueKey('on-device-model-select-${option.id}'),
              onPressed: _busy ? null : () => unawaited(_select(option)),
              child: const Text('使用'),
            ),
          TextButton(
            key: ValueKey('on-device-model-delete-${option.id}'),
            onPressed: _busy ? null : () => unawaited(_delete(option)),
            child: Text('删除', style: TextStyle(color: t.danger)),
          ),
        ],
      ],
    );
  }
}
