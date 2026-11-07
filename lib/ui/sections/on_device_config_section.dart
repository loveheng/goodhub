/// 设置页 · 端侧模型配置段（2026-11-02 自 `OnDeviceModelSection` 拆出）：端侧
/// **配置**面——启用偏好（门禁覆盖）/ GenieX 增配运行库（NPU 档）/ 电池优化
/// 白名单提示。资产面（导入/选择/删除）留在资源中心「端侧模型」tab（用户拍板：
/// 配置归设置、资产归资源中心——端侧模型导入留资源中心，端侧配置回设置）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';
import '../../coordinator/on_device_admin.dart'
    show
        GateOverride,
        GenieXStatus,
        LiteRtLmNpuStatus,
        OnDeviceAdmin,
        OnDeviceGenPerf;
import '../../gateway_api/gateway_control.dart';

/// 电池白名单查询/申请注入位（测试替换，范式同 on_device_model_section）。
typedef BatteryStatusFn = Future<bool> Function();
typedef BatteryRequestFn = Future<bool> Function();

/// 段 widget：注入 [onFlash]（页面级 toast 口径）/ [batteryStatusOverride] /
/// [batteryRequestOverride]（测试替换）。
class OnDeviceConfigSection extends StatefulWidget {
  const OnDeviceConfigSection({
    super.key,
    this.onFlash,
    this.batteryStatusOverride,
    this.batteryRequestOverride,
  });

  final void Function(String message)? onFlash;
  final BatteryStatusFn? batteryStatusOverride;
  final BatteryRequestFn? batteryRequestOverride;

  @override
  State<OnDeviceConfigSection> createState() => _OnDeviceConfigSectionState();
}

class _OnDeviceConfigSectionState extends State<OnDeviceConfigSection>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  /// ListView 懒构建会把滚出视口的 sliver child 销毁重建——段内领域态
  /// （增配进度/错误态）随之丢失，故段一律申请 keepAlive（闸门测试在案）。
  @override
  bool get wantKeepAlive => true;

  GenieXStatus? _geniex;
  int? _geniexPct;
  LiteRtLmNpuStatus? _litertlm;
  int? _litertlmPct;
  void Function()? _geniexEvents;

  /// 门禁覆盖偏好（§16 用户授权覆盖层）快照；读取完成前为 null（UI 暂不显）。
  GateOverride? _gateOverride;

  /// 电池优化白名单状态（true = 已加入 / false = 未加入 / null = 未知未查）。
  ///
  /// S3-5 OEM 冻结防护（§6.2 ③）：厂商省电策略对后台/被冻结进程可强杀
  /// `:engine`（SIGKILL 且不下发 trim），引导用户加入白名单降低长生成
  /// 中断概率。
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshGeniex());
    unawaited(_refreshLitertlm());
    unawaited(_refreshGateOverride());
    unawaited(_refreshBatteryExemption());
    // 双族事件合并分发（单 handler——同通道 setMethodCallHandler 相互覆盖）。
    _geniexEvents ??= OnDeviceAdmin.npuListen(
      onGeniexProgress: (pct) {
        if (!mounted) return;
        setState(() => _geniexPct = pct);
      },
      onGeniexDone: (ok) {
        if (!mounted) return;
        setState(() => _geniexPct = null);
        unawaited(_refreshGeniex());
      },
      onProgress: (pct) {
        if (!mounted) return;
        setState(() => _litertlmPct = pct);
      },
      onDone: (ok) {
        if (!mounted) return;
        setState(() => _litertlmPct = null);
        unawaited(_refreshLitertlm());
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _geniexEvents?.call();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统白名单弹窗返回 → 复查状态（弹窗里点「允许」当场不会回传）。
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshBatteryExemption());
    }
  }

  /// GenieX 增配状态刷新（设计稿 §7 状态机：未提供/可下载/已装）。
  Future<void> _refreshGeniex() async {
    try {
      final st = await OnDeviceAdmin.geniexStatus();
      if (!mounted) return;
      setState(() => _geniex = st);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-config: GenieX 状态查询失败: $e');
    }
  }

  /// LiteRT-LM NPU 增配状态刷新（多机型口径：按芯片下载）。
  Future<void> _refreshLitertlm() async {
    try {
      final st = await OnDeviceAdmin.npuStatus();
      if (!mounted) return;
      setState(() => _litertlm = st);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-config: LiteRT-LM NPU 状态查询失败: $e');
    }
  }

  /// 受理 LiteRT-LM NPU 安装（镜像复用 GenieX 双源持久化——一套裁决）。
  Future<void> _installLitertlm() async {
    try {
      final mirrors = await OnDeviceAdmin.loadMirrors();
      final accepted = await OnDeviceAdmin.npuInstall(mirrors);
      if (!mounted) return;
      setState(() => _litertlmPct = accepted ? 0 : null);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-config: LiteRT-LM NPU 安装受理失败: $e');
    }
  }

  Future<void> _installGeniex() async {
    try {
      final mirrors = await OnDeviceAdmin.loadMirrors();
      final accepted = await OnDeviceAdmin.geniexInstall(mirrors);
      if (!mounted) return;
      setState(() => _geniexPct = accepted ? 0 : null);
      widget.onFlash?.call(accepted ? 'GenieX 增配安装已受理' : 'GenieX 增配安装未受理（可能已在进行）');
    } on Object catch (e) {
      if (mounted) widget.onFlash?.call('GenieX 安装发起失败：$e');
    }
  }

  Future<void> _uninstallGeniex() async {
    try {
      final ok = await OnDeviceAdmin.geniexUninstall();
      if (!mounted) return;
      widget.onFlash?.call(ok ? 'GenieX 增配已卸载（端侧 LLM 将收口云端，可随时重装）' : 'GenieX 增配本就未安装');
      await _refreshGeniex();
    } on Object catch (e) {
      if (mounted) widget.onFlash?.call('GenieX 卸载失败：$e');
    }
  }

  /// 运行库增配块（2026-11-02 体系重梳：**两族 × 按芯片**，清单单源）——
  /// 每族一行 = 一个引擎的 NPU 档运行库（通用核心 + 本机芯片件两段自动
  /// 下载）；脚注写明组合关系。合集包退役（与两族纯包含关系，冗余）。
  /// 状态查询失败（st==null）不渲染整块；安装动作仅 supported 且已注册机型。
  Widget _geniexBlock(ConsoleTokens t) {
    final st = _geniex;
    if (st == null) return const SizedBox.shrink();
    final pct = _geniexPct;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 族①：GenieX 引擎运行库（QAIRT/Genie 管线 → NPU 档）。
      Text('运行库 · GenieX 引擎（高通 NPU 档）',
          style: TextStyle(fontSize: Fsz.telemetry, color: t.l2Accent)),
      const SizedBox(height: 2),
      Row(children: [
        Expanded(
          child: Text(
            st.installing || pct != null
                ? '下载中 $pct%（通用核心 + 芯片件 v${st.arch} 两段，断点续传）'
                : st.installed
                    ? '已装 v${st.version}（NPU v${st.arch}）· 占用 ${_sizeLabel(st.sizeBytes)}'
                    : st.supported
                        ? '未安装——装后 GenieX 引擎可走 NPU 档（通用核心 + 本机芯片件两段自动下载）'
                        : '本机 SoC 不支持（非骁龙 Hexagon 代际）',
            style: TextStyle(fontSize: Fsz.telemetrySm, color: t.l1Info),
          ),
        ),
        if (st.installed)
          TextButton(
            key: const ValueKey('geniex-uninstall'),
            onPressed: () => unawaited(_uninstallGeniex()),
            child: const Text('卸载'),
          )
        else if (st.supported && !st.installing && pct == null)
          TextButton(
            key: const ValueKey('geniex-install'),
            onPressed: () => unawaited(_installGeniex()),
            child: const Text('安装'),
          ),
        TextButton(
          key: const ValueKey('geniex-mirrors'),
          onPressed: () => unawaited(_editMirrors()),
          child: const Text('镜像'),
        ),
      ]),
      const SizedBox(height: 6),
      // 族②：LiteRT-LM 引擎运行库（.litertlm 资产 → NPU 档）。
      Text('运行库 · LiteRT-LM 引擎（NPU 档）',
          style: TextStyle(fontSize: Fsz.telemetry, color: t.l2Accent)),
      const SizedBox(height: 2),
      Row(children: [
        Expanded(
          child: Text(
            _litertlmPct != null
                ? '下载中 $_litertlmPct%（通用核心 + 芯片件 v${_litertlm?.arch} 两段，断点续传）'
                : _litertlm == null
                    ? '状态未知（通道未连接）'
                    : !_litertlm!.supported
                        ? '本机无 Hexagon NPU 运行库（该引擎走 GPU/云端）'
                        : _litertlm!.installed
                            ? '已装 v${_litertlm!.arch} · 占用 ${_sizeLabel(_litertlm!.sizeBytes)}'
                            : !_litertlm!.registered
                                ? '清单未收录本机代际 v${_litertlm!.arch}（该引擎走 GPU/云端）'
                                : '未安装——装后 LiteRT-LM 引擎可走 NPU 档（通用核心 + 本机芯片件两段自动下载）',
            style: TextStyle(fontSize: Fsz.telemetrySm, color: t.l1Info),
          ),
        ),
        if (_litertlm != null &&
            _litertlm!.supported &&
            _litertlm!.registered &&
            !_litertlm!.installed &&
            _litertlmPct == null)
          TextButton(
            key: const ValueKey('litertlm-npu-install'),
            onPressed: () => unawaited(_installLitertlm()),
            child: const Text('安装'),
          ),
      ]),
      const SizedBox(height: 6),
      // 组合关系脚注（体系说明，防「谁和谁是一组」误读）。
      Text(
        '两族运行库互不依赖：装哪族，哪个引擎走 NPU 档；未装的族自动走'
        ' GPU/云端。按芯片代际取件（通用核心跨芯片复用），清单远端统一维护。',
        style: TextStyle(fontSize: Fsz.telemetrySm, color: t.terminalMuted),
      ),
    ]);
  }

  /// 镜像列表编辑（D3 镜像可配置化，P3）：多行文本每行一个 URL，空 =
  /// 回退内置双源默认。保存即持久化（下次安装生效）。
  Future<void> _editMirrors() async {
    final current = await OnDeviceAdmin.loadMirrors();
    if (!mounted) return;
    final controller = TextEditingController(text: current.join('\n'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载镜像（每行一个 URL，留空回退默认）'),
        content: TextField(
          key: const ValueKey('geniex-mirrors-input'),
          controller: controller,
          maxLines: 5,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            key: const ValueKey('geniex-mirrors-save'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final mirrors = controller.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.startsWith('http'))
        .toList();
    await OnDeviceAdmin.saveMirrors(mirrors);
    if (mounted) {
      widget.onFlash?.call(mirrors.isEmpty ? '镜像已清空——回退内置双源默认' : '镜像已保存（${mirrors.length} 个，下次安装生效）');
    }
  }

  bool? _nightlyBatchEnabled;
  Future<void> _loadNightlyBatch() async {
    final v = await OnDeviceAdmin.nightlyBatchEnabled();
    if (!mounted) return;
    setState(() => _nightlyBatchEnabled = v);
  }
  Future<void> _toggleNightlyBatch(bool v) async {
    await OnDeviceAdmin.setNightlyBatch(v);
    if (!mounted) return;
    setState(() => _nightlyBatchEnabled = v);
  }

  /// 复查电池白名单状态（查询失败按未知处理，不阻断配置段主功能）。
  Future<void> _refreshBatteryExemption() async {
    try {
      final exempt =
          await (widget.batteryStatusOverride ?? gatewayBatteryExemptionStatus)();
      if (!mounted) return;
      setState(() => _batteryExempt = exempt);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-config: 电池白名单状态查询失败: $e');
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
    _loadNightlyBatch();
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-config: 电池白名单申请失败: $e');
      if (mounted) widget.onFlash?.call('白名单申请失败：$e');
    }
  }

  /// 门禁覆盖偏好（§16 用户授权覆盖层）：读取用户对三维度门禁与偏好/强行的覆盖。
  Future<void> _refreshGateOverride() async {
    try {
      final ov = await OnDeviceAdmin.readGateOverride();
      if (!mounted) return;
      setState(() => _gateOverride = ov);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-config: 门禁覆盖偏好读取失败: $e');
    }
  }

  Future<void> _setPrefer(bool v) async {
    await OnDeviceAdmin.writePreferOnDevice(v);
    if (!mounted) return;
    setState(() => _gateOverride = _gateOverride!.copyWith(preferOnDevice: v));
    widget.onFlash?.call(v ? '已设为优先使用端侧' : '已恢复云端优先');
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

  Widget _batteryExemptRow(ConsoleTokens t) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '⚡ 长生成保活：尚未加入电池优化白名单——厂商省电机制可能'
            '冻结/强杀后台 :engine 进程，中断端侧生成',
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

  /// 运行时标识 → 白话徽标（NPU / CPU / LiteRT-LM / 自动）。
  String _sizeLabel(int bytes) =>
      bytes >= (1 << 30)
          ? '${(bytes / (1 << 30)).toStringAsFixed(1)}GB'
          : '${bytes ~/ (1 << 20)}MB';

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
            Text('端侧模型配置',
                style: TextStyle(
                    fontSize: Fsz.telemetry, color: t.l2Accent)),
            const SizedBox(height: 4),
            if (_gateOverride != null) ...[
              // 门禁已 advisory 化（2026-10-31 裁决）：判定只留痕不拦截，
              // ignore*/强行启用开关随拦截语义退役——本组只剩路由偏好。
              Text('端侧启用偏好（用户覆盖）',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.l2Accent)),
              const SizedBox(height: 4),
              _toggleRow(t, '优先使用端侧（云端可用也走端侧）',
                  _gateOverride!.preferOnDevice, _setPrefer),
              const SizedBox(height: 6),
            ],
            // GenieX 增配运行库（npu-geniex-runtime P2，设计稿 §7）
            _geniexBlock(t),
            const SizedBox(height: 6),
            // 最近一次端侧生成性能（W bench 消费面：tok/s / TTFT / 上下文占用；
            // 有过端侧产出才显，纯错误收口不写快照）。
            ValueListenableBuilder<OnDeviceGenPerf?>(
              valueListenable: OnDeviceAdmin.onDeviceLastGenPerf(),
              builder: (context, perf, _) {
                if (perf == null) return const SizedBox.shrink();
                final ctxTok = (perf.promptChars / 1.3).round();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '上次端侧生成：TTFT ${perf.ttftMs}ms · '
                    '${perf.tokPerSec.toStringAsFixed(1)} tok/s · '
                    '输入约 $ctxTok tok（估算）',
                    key: const ValueKey('on-device-last-gen-perf'),
                    style: TextStyle(
                        fontSize: Fsz.telemetrySm, color: t.terminalMuted),
                  ),
                );
              },
            ),
            // 电池优化白名单（S3-5 OEM 冻结防护）：未加入时提示并一键跳转。
            if (_batteryExempt == false) ...[
              _batteryExemptRow(t),
              // W6-c 夜间批处理开关（on-device-residency 第七节契机 B）。
              SwitchListTile(
                dense: true,
                title: Text('夜间算力批处理',
                    style: TextStyle(fontSize: Fsz.body, color: t.l2Accent)),
                subtitle: Text('充电且空闲时批量处理积压的端侧任务',
                    style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
                value: _nightlyBatchEnabled ?? false,
                onChanged: (v) => _toggleNightlyBatch(v),
                activeThumbColor: t.l1Info,
              ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }
}
