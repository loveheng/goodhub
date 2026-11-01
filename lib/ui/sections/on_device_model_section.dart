/// 设置页 · 端侧模型段（on-device 正式功能，S2-5 起替代 dart-define 资产
/// 指向 PATCH）：模型目录展示、本地导入（2026-10-30 拍板：模型改导入制，
/// 废弃在线 OTA——模型体积过大无在线存储）、选择持久化、删除。
///
/// 职责边界：本段只管「资产面」（导入/删除/选择）；引擎装载/会话创建仍由
/// 启动引导与 hybrid 装配承载（导入完成后受理 loadModel 的就绪轮询照旧）。
/// 导入进度经 [OnDeviceAssetManager.importFromPickedFiles] 的 onProgress 驱动。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../components/panel_error_row.dart';
import '../tokens/console_tokens.dart';
import '../../gateway_api/gateway_control.dart';
import '../../llm/geniex_runtime_binding.dart';
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

  String? _selectedDir;
  List<InstalledModel> _models = <InstalledModel>[];
  GenieXStatus? _geniex;
  int? _geniexPct;
  void Function()? _geniexEvents;
  bool _busy = false;
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
    // 增配块接线收口（2026-11-01 真机暴露）：状态刷新与进度反投订阅此前
    // 缺失——`_geniex` 恒 null 令增配块永不渲染（_geniexBlock 的
    // st==null 短路），`_geniexPct` 恒 null 会显示「下载中 null%」；
    // 块自 P2 落地起从未在真机呈现已实证（干净安装轮暴露）。
    unawaited(_refreshGeniex());
    _geniexEvents ??= GenieXRuntimeControl.listen(
      onProgress: (pct) {
        if (!mounted) return;
        setState(() => _geniexPct = pct);
      },
      onDone: (ok) {
        if (!mounted) return;
        setState(() => _geniexPct = null);
        unawaited(_refreshGeniex());
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
      final st = await GenieXRuntimeControl.status();
      if (!mounted) return;
      setState(() => _geniex = st);
    } on Object catch (e) {
      debugPrint('[DEGRADE] on-device-panel: GenieX 状态查询失败: $e');
    }
  }

  Future<void> _installGeniex() async {
    try {
      final mirrors = await GenieXRuntimeControl.loadMirrors();
      final accepted = await GenieXRuntimeControl.install(mirrors);
      if (!mounted) return;
      setState(() => _geniexPct = accepted ? 0 : null);
      widget.onFlash?.call(accepted ? 'GenieX 增配安装已受理' : 'GenieX 增配安装未受理（可能已在进行）');
    } on Object catch (e) {
      if (mounted) widget.onFlash?.call('GenieX 安装发起失败：$e');
    }
  }

  Future<void> _uninstallGeniex() async {
    try {
      final ok = await GenieXRuntimeControl.uninstall();
      if (!mounted) return;
      widget.onFlash?.call(ok ? 'GenieX 增配已卸载（端侧 LLM 将收口云端，可随时重装）' : 'GenieX 增配本就未安装');
      await _refreshGeniex();
    } on Object catch (e) {
      if (mounted) widget.onFlash?.call('GenieX 卸载失败：$e');
    }
  }

  /// GenieX 增配块（设计稿 §7 状态机）：不支持机型不渲染；状态胶囊
  /// （未装/下载中 pct%/已装）+ 安装/卸载动作。
  Widget _geniexBlock(ConsoleTokens t) {
    final st = _geniex;
    if (st == null || !st.supported) return const SizedBox.shrink();
    final pct = _geniexPct;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('GenieX 增配（骁龙 NPU 加速包）',
          style: TextStyle(fontSize: Fsz.telemetry, color: t.l2Accent)),
      const SizedBox(height: 2),
      Row(children: [
        Expanded(
          child: Text(
            st.installing || pct != null
                ? '下载中 $pct%（约 89MB，断点续传）'
                : st.installed
                    ? '已装 v${st.version}（NPU v${st.arch}）· 占用 ${_sizeLabel(st.sizeBytes)}'
                    : '未安装（端侧 LLM 走云端；内置基线仅承载框架/小模型）',
            style: TextStyle(fontSize: Fsz.telemetrySm, color: t.l1Info),
          ),
        ),
        if (st.installed)
          TextButton(
            key: const ValueKey('geniex-uninstall'),
            onPressed: () => unawaited(_uninstallGeniex()),
            child: const Text('卸载'),
          )
        else if (!st.installing && pct == null)
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
    ]);
  }

  /// 镜像列表编辑（D3 镜像可配置化，P3）：多行文本每行一个 URL，空 =
  /// 回退内置双源默认。保存即持久化（下次安装生效）。
  Future<void> _editMirrors() async {
    final current = await GenieXRuntimeControl.loadMirrors();
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
    await GenieXRuntimeControl.saveMirrors(mirrors);
    if (mounted) {
      widget.onFlash?.call(mirrors.isEmpty ? '镜像已清空——回退内置双源默认' : '镜像已保存（${mirrors.length} 个，下次安装生效）');
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
      // 注册表（身份唯一源，2026-10-31）：已装模型来自磁盘扫描（经注入的
      // assetManager 支持目录）；选择持久化按 dirName 解析。选择器经静态
      // read() 读真实支持目录（测试环境降级为 null，不影响主功能；生产与
      // listInstalled 同目录，一致）。
      final installed = await _assets.listInstalled();
      final selected = await OnDeviceModelSelection.read();
      if (!mounted) return;
      setState(() {
        _models = installed;
        _selectedDir = selected?.dirName;
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

  /// 自由导入新模型（纯导入制，2026-10-31 固定档位退役）：命名 → 生成唯一
  /// 落盘目录 → 自由导入（绝对体积上限 + 结构校验）。任意 GGUF/QAIRT 包。
  Future<void> _importFree() async {
    if (_busy) return;
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked.isEmpty) return; // 用户取消
    // 首发节奏关闸（decisions.md ADR 2026-11-01）：GGUF（llama.cpp 通路）
    // 先不放出，仅 QAIRT 包可导入；压缩包内 GGUF 无法在此识别，交
    // `enable()` 装载闸兜底（runtime=llama_cpp 拒装载）。
    final directGguf =
        picked.any((f) => f.name.toLowerCase().endsWith('.gguf'));
    if (!kOnDeviceLlamaCppEnabled && directGguf) {
      widget.onFlash?.call('GGUF 模型导入暂未开放（首发从 LiteRT-LM 起步）');
      return;
    }
    // 系统文件选择器全屏遮盖可停留很久，返回时段可能已被 ListView 懒构建
    // 销毁重建——未 mounted 就 showDialog 会把 dialog 挂进失效子树（真机
    // 实证 InheritedElement `_dependents.isEmpty` 断言崩溃，2026-10-31）。
    if (!mounted) return;
    final firstBase = picked.first.name.split('/').last;
    final suggested = firstBase
        .replaceFirst(RegExp(r'\.(gguf|zip|tar\.gz|tgz|tar|bin)$', caseSensitive: false), '');
    final name = await _promptModelName(suggested.isNotEmpty ? suggested : 'model');
    if (name == null || name.trim().isEmpty) return;
    final dirName = await _uniqueDirName(name.trim());
    final paths =
        picked.where((f) => f.path != null).map((f) => f.path!).toList();
    await _doImport(
      paths,
      target: ImportTarget(dirName: dirName, displayName: name.trim()),
      flashName: name.trim(),
    );
  }

  /// 导入执行（自由导入唯一入口）：散文件/压缩包路由 + 进度 + 选择 +
  /// 刷新注册表。
  Future<void> _doImport(
    List<String> paths, {
    required ImportTarget target,
    required String flashName,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
      _progressText = '准备导入…';
    });
    try {
      // 单选压缩包（zip/tar/tar.gz）→ 解压导入通道；否则按散文件多选导入。
      final lowerSingle =
          paths.length == 1 ? paths.single.toLowerCase() : null;
      final isArchive = lowerSingle != null &&
          (lowerSingle.endsWith('.zip') ||
              lowerSingle.endsWith('.tar') ||
              lowerSingle.endsWith('.tar.gz') ||
              lowerSingle.endsWith('.tgz'));
      void onProgress(AssetPullProgress p) {
        if (!mounted) return;
        setState(() {
          switch (p.phase) {
            case 'file':
              final pct = p.totalBytes > 0
                  ? (p.receivedBytes * 100 ~/ p.totalBytes)
                  : 0;
              _progressText =
                  '导入中 $pct%（${p.receivedBytes ~/ 1048576}/${p.totalBytes ~/ 1048576}MB）';
            case 'done':
              _progressText = '导入完成';
            default:
              _progressText = p.detail ?? '处理中…';
          }
        });
      }
      final dir = isArchive
          ? await _assets.importFromArchive(paths.single,
              target: target, onProgress: onProgress)
          : await _assets.importFromPickedFiles(paths,
              target: target, onProgress: onProgress);
      if (dir == null) {
        if (mounted) {
          setState(() {
            _error = '导入失败（磁盘门禁/文件读取/重名冲突/资产校验），见日志';
            _progressText = '';
          });
        }
        return;
      }
      await OnDeviceModelSelection.write(target.dirName);
      if (!mounted) return;
      await _refresh();
      if (!mounted) return;
      setState(() => _progressText = '');
      widget.onFlash?.call('$flashName 已导入，首次使用端侧时自动加载');
    } catch (e) {
      if (mounted) setState(() => _error = '导入失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  /// 模型命名对话框：返回用户输入（取消/null = 放弃）。
  Future<String?> _promptModelName(String suggested) async {
    final ctrl = TextEditingController(text: suggested);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入模型'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '模型名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    // 不在此处 dispose [ctrl]：pop 返回时退出动画仍在跑，TextField 仍引用
    // controller——立即 dispose 是同类树生命周期错位（真机 `_dependents.
    // isEmpty` 断言同族隐患）；局部短命对象交 GC 回收。
    return name;
  }

  /// 由展示名生成唯一落盘目录名（slug 化 + 撞名自增）——不与已装模型/内置档位冲突。
  Future<String> _uniqueDirName(String name) async {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'model' : slug;
    final taken = <String>{
      for (final m in _models) m.dirName,
    };
    var candidate = base;
    var i = 2;
    while (taken.contains(candidate)) {
      candidate = '$base-$i';
      i++;
    }
    return candidate;
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
            if (_batteryExempt == false && (_models.isNotEmpty || _selectedDir != null)) ...[
              _batteryExemptRow(t),
              const SizedBox(height: 6),
            ],
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
            // 已装模型（注册表，身份唯一源）
            for (final m in _models) ...[
              _modelRow(t, m),
              const SizedBox(height: 6),
            ],
            // 自由导入新模型（GGUF / QAIRT 包，任意体积档）
            TextButton(
              key: const ValueKey('on-device-model-import-free'),
              onPressed: _busy ? null : () => unawaited(_importFree()),
              child: const Text('＋ 导入模型（GGUF / QAIRT 包）'),
            ),
            const SizedBox(height: 6),
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

  /// 运行时标识 → 白话徽标（NPU / CPU / LiteRT-LM / 自动）。
  String _runtimeLabel(String r) =>
      r == OnDeviceRuntime.qairt ? 'NPU'
          : r == OnDeviceRuntime.llamaCpp ? 'CPU'
              : r == OnDeviceRuntime.litertlm ? 'LiteRT-LM'
                  : '自动';

  String _sizeLabel(int bytes) =>
      bytes >= (1 << 30)
          ? '${(bytes / (1 << 30)).toStringAsFixed(1)}GB'
          : '${bytes ~/ (1 << 20)}MB';

  /// 已装模型行（注册表条目）：展示名 + 运行时徽标 + 体积 + 使用/删除。
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
                '${selected ? '  当前使用' : ''}',
                style: TextStyle(
                    fontSize: Fsz.note,
                    color: selected ? t.l1Ok : t.terminalMuted),
              ),
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
}

