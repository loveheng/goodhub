/// 设置页（2026-10-16 合并改名词：原「服务大厅」，名词映射见
/// docs/design/page-revamp.md）。M3-T4 建页（architecture §5「服务与配置大厅」
/// 的 M3 交付面；形态 = ui-design §3.3 控制台式卡片阵列），M4-T5 增 BYOK /
/// 节点卡面板，2026-10-16 合并聊天页 ⚙ 设置弹层后定稿六段；**2026-10-16 方案 A
/// 撤销「默认私有服务」独立 radio 面板**（HCI 评估：该面板无独立数据源，候选集
/// 是 ②③ 的二次渲染，同屏双份+四层作用域过载）——默认钉选降级为 ②③ 卡片行内
/// 「图钉按钮 + 默认私有 pill」，存储键 `default.private.server` 与回退链不变。
///
/// **本页 scope（边界声明——防无边界膨胀）**：设置 = **服务与引擎配置**，仅收纳
/// 下列六段。记忆看板（`MemoryBoardPage`）、应用更新（`UpdatePage`）、会话历史
/// 均为独立页，入口在聊天页侧边栏 / AppBar，**不并入本页**——名字变宽不等于
/// 职责变宽。
///
/// ① **云端模型（BYOK）**——模型配置列表增删改（多 profile）+ 密钥走
///    SecureKeyValue（编辑留空 = 保持已存密钥）；装配语义 = 生效位 profile
///    （hybrid_assembly 取 preferred ?? 列表首个），支持置顶 / 点选切换生效；
/// ② **MCP 服务端点（节点卡）**——每个配置端点一张节点卡（ui-design §3.3：端口 /
///    延迟毫秒 / 在线点 / 已暴露工具计数，等宽遥测轨）+ 鉴权态（401/403 待授权
///    Rose，禁与离线灰阶混淆）+ 挂载/卸载开关（卸载只摘出连接池，配置与令牌
///    保留）+ 增删改表单（同一 ServerEndpointStore 文件——服务全生命周期已收敛
///    本页，聊天页 ⚙ 不再持有）+ **默认私有服务钉选**（图钉 + 「默认私有」pill，
///    候选 = enabled 且 private tier；与 ③ 共用统一默认键，聊天页可临时覆盖）；
///    数据面 = lib/mcp/server_probe.dart 探活器；
/// ③ **本地插件**——Binder 同机发现项渲染 + 信任态 pill + **信任 / 撤销信任**
///    （撤销 = 移出白名单；因信任闸门是装配期校验而非长连接状态，下一轮装配
///    本机重新弹卡确认、PC 网关侧直接跳过不再暴露，故撤销无需动连接池）+
///    **默认私有服务钉选**（同 ② 图钉语义，候选 = serverId 非空——本地插件
///    与原 radio 面板同过滤口径，含未信任项：信任闸门在装配期仍会拦）；
/// ④ **PC 远程网关**——:8766 起停 + 配对 Token + 局域网暴露风险文案（2026-10-16
///    自聊天页 ⚙ 迁入；是本次合并的唯一净新增能力）；
/// ⑤ **Skill 覆写（CoW 编辑面）**——覆写列表/编辑/保存（setOverride）/ 一键重置；
///    覆写优先级最高，major 跃迁告警弹卡（CowMajorJumpDelegate）在联调流组件化
///    复用，此处不重复建同步入口（同步需 Server 连接，属节点卡面板范围）；
/// ⑥ **跨源授权语义**——D5 恒 L2 弹卡不豁免的口径展示 + 联调入口。
/// ⑦ **关于**——版本号 + **检查更新**入口（正式功能，全构建可见，2026-10-16 自
///    聊天页 AppBar 迁入：聊天页 AppBar 已清空，不再持有设置/调试按钮）；
///    **长按「关于」标题**唤出 debug 联调菜单（仅 `kDebugMode`：网关/熔断联调 +
///    M1 任务循环），避免联调入口污染正式面。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/service_directory.dart';
import '../coordinator/cow_sync.dart';
import '../gateway_api/gateway_control.dart';
import '../llm/cloud/byok_store.dart';
import '../llm/cloud/cloud_llm.dart';
import '../mcp/server_endpoints.dart';
import '../mcp/server_probe.dart';
import '../mcp/default_private_server.dart';
import 'components/server_endpoint_forms.dart';
import 'claim_loop_page.dart';
import 'gateway_loop_debug_page.dart';
import 'update_page.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/trusted_plugins.dart';
import 'trust_plugin_dialog.dart';
import 'tokens/console_tokens.dart';

/// appScoped 覆写正文的防呆上限（无硬预算闸，防呆防手滑）。
const kCowOverrideMaxChars = 10000;

/// 节点卡探活入口（注入位：测试传假探活，生产落 [ServerProber.probe]）。
typedef NodeProbeFn = Future<NodeProbeResult> Function(
  String endpoint, {
  String? apiKey,
});

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.storeOverride,
    this.byokStoreOverride,
    this.endpointStoreOverride,
    this.probeOverride,
    this.autoProbe = true,
    this.localScanOverride,
    this.localChangesOverride,
  });

  /// 测试注入位；null = 生产路径（应用文档目录）。
  final CowOverridesStore? storeOverride;

  /// 测试注入位（M4-T5 BYOK 面板）；null = 生产路径（默认安全存储装配）。
  final ByokStore? byokStoreOverride;

  /// 测试注入位（M4-T5 节点卡）；null = 生产路径（应用支持目录
  /// /mcp_servers.json，与聊天页 ⚙ 设置同一文件）。
  final ServerEndpointStore? endpointStoreOverride;

  /// 测试注入位（M4-T5 节点卡）；null = 生产路径（[ServerProber] 真探活）。
  final NodeProbeFn? probeOverride;

  /// 进入页面自动探活一次（P2；测试注入假探活时置 false 关掉，免干扰计数断言）。
  final bool autoProbe;

  /// 测试注入位（本地插件面板）：null = 生产路径（[localPluginDiscovery] 经
  /// Binder 通道拉扫同机插件）；测试传假 scan 免去真机通道依赖。
  final Future<List<LocalPluginInfo>> Function()? localScanOverride;

  /// 测试注入位（本地插件面板）；null = 生产路径（[localPluginDiscovery.changes]）。
  final Stream<void>? localChangesOverride;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  CowOverridesStore? _store;
  Map<String, DateTime?> _entries = const {};
  String? _editingName;
  final _editCtrl = TextEditingController();
  final _newNameCtrl = TextEditingController();
  final _newContentCtrl = TextEditingController();
  var _creating = false;
  // 面板级错误态（ux-hardening P0-3）：初始化失败不再打死整页——面板内
  // Rose 文案 + 重试入口；面板间无数据依赖，其余照常可用。
  String? _cowError;

  // —— BYOK 面板状态（M4-T5）——
  ByokStore? _byokStore;
  var _byokProfiles = const <ByokProfile>[];
  String? _byokPreferredId; // 生效 profile id（用户显式选择；未选=列表首位）
  final _hasByokKey = <String>{}; // 安全存储已有密钥的 profileId（真值不入内存明文）
  String? _editingByokId;
  var _creatingByok = false;
  String? _byokError;
  var _byokProto = CloudProtocol.openaiCompatible;
  final _byokNameCtrl = TextEditingController();
  final _byokUrlCtrl = TextEditingController();
  final _byokModelCtrl = TextEditingController();
  final _byokTempCtrl = TextEditingController();
  final _byokKeyCtrl = TextEditingController();

  // —— Server 节点卡状态（M4-T5）——
  ServerEndpointStore? _epStore;
  var _endpoints = const <ServerEndpoint>[];
  final _probeStates = <String, NodeProbeResult?>{}; // id → null = 探测中
  var _probing = false;
  // —— 节点卡增删改（P1 设置拆分：服务全生命周期收敛本面板）——
  final _epKeys = <String, String?>{}; // id → 已存令牌（编辑表单预填）
  var _addingEp = false;
  String? _editingEpId;
  String? _nodesError;

  // —— 本地插件面板（Binder 发现，零配置自动挂载）——
  Future<List<LocalPluginInfo>> Function()? _localScan;
  var _localPlugins = const <LocalPluginInfo>[];
  var _trustedPackages = const <String>{}; // 已信任包名（同签名免确认仍显式标）
  StreamSubscription<void>? _localChangesSub;
  String? _localError;

  // —— 默认私有服务（统一钉选，覆盖手动端点 + 本地插件；持久于 SharedPreferences）——
  // 方案 A（2026-10-16）：独立 radio 面板撤销，钉选态降级为 ②③ 卡片行内
  // （图钉按钮 + 「默认私有」pill）——空 = 无默认（纯公共回退）。
  var _defaultPrivateId = '';

  // —— 关于面板（2026-10-16 自聊天页 AppBar 迁入）——
  String _appVersion = '—'; // PackageInfo 不可用时占位（宁空勿炸）

  // —— PC 远程网关面板（2026-10-16 自聊天页 ⚙ 迁入）——
  var _gwRunning = false;
  var _gwLanAddrs = const <String>[]; // 运行中展示 PC 可配 URL
  final _gwTokenCtrl = TextEditingController();
  var _gwBusy = false; // 起停中：禁重复触发（起服含端口绑定，非瞬时）

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _localChangesSub?.cancel();
    _editCtrl.dispose();
    _newNameCtrl.dispose();
    _newContentCtrl.dispose();
    _byokNameCtrl.dispose();
    _byokUrlCtrl.dispose();
    _byokModelCtrl.dispose();
    _byokTempCtrl.dispose();
    _byokKeyCtrl.dispose();
    _gwTokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _initCow();
    await _initByok();
    await _initNodes();
    // P2：进入页面自动探活一次——「未探测 · 已存令牌」不再让用户先找按钮。
    if (widget.autoProbe && mounted) {
      unawaited(_probeAll());
    }
    await _initLocalPlugins();
    // 网关面板独立初始化：只读当前起停态与持久化 Token——网关是全局单例，
    // 页面 dispose **不停服**（起停是用户显式动作，页面进出不该带副作用）。
    try {
      final prefs = await SharedPreferences.getInstance();
      _gwTokenCtrl.text = prefs.getString('gateway.token') ?? '';
      await _reloadGateway();
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway-panel: 状态读取失败按未运行: $e');
    }
    // 关于面板独立初始化：版本号只作展示，读不到按占位（不影响任何功能面）。
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = '${info.version}+${info.buildNumber}');
      }
    } on Object catch (e) {
      debugPrint('[DEGRADE] about-panel: 版本读取失败按占位: $e');
    }
    // 默认私有服务钉选读取（独立初始化：失败按空，不拖垮页面）。
    try {
      final def = await readDefaultPrivateServerId();
      if (mounted) setState(() => _defaultPrivateId = def ?? '');
    } on Object catch (e) {
      debugPrint('[DEGRADE] default-private: 读取失败按无默认: $e');
    }
  }

  /// 覆写面板初始化（ux-hardening P0-3）：失败置面板级错误态（Rose + 重试），
  /// 不再打死整页；成功即清错误。重试入口 = 本方法自身。
  Future<void> _initCow() async {
    try {
      final store =
          widget.storeOverride ??
          CowOverridesStore(dir: await getApplicationDocumentsDirectory());
      await _reload(store);
      if (mounted) setState(() => _cowError = null);
    } catch (e) {
      if (mounted) setState(() => _cowError = '覆写库读取失败：$e');
    }
  }

  /// BYOK 面板初始化（P0-3 同口径）：失败从「静默按空目录」升级为面板级
  /// 错误态——用户自带 key 失效时看得到原因，而非面对空列表猜疑。
  Future<void> _initByok() async {
    try {
      final byok = widget.byokStoreOverride ?? ByokStore();
      await _reloadByok(byok);
      if (mounted) setState(() => _byokError = null);
    } catch (e) {
      debugPrint('[DEGRADE] byok-panel: 配置读取失败: $e');
      if (mounted) setState(() => _byokError = '模型配置读取失败：$e');
    }
  }

  /// 节点卡面板初始化（P0-3 同口径）：失败置面板级错误态（与聊天页 ⚙ 设置
  /// 同一 ServerEndpointStore 文件——应用支持目录/mcp_servers.json + 旧单端点
  /// SharedPreferences 迁移同口径）。
  Future<void> _initNodes() async {
    try {
      final epStore = widget.endpointStoreOverride ?? await _epStoreProd();
      await _reloadEndpoints(epStore);
      if (mounted) setState(() => _nodesError = null);
    } catch (e) {
      debugPrint('[DEGRADE] nodes-panel: 端点目录读取失败: $e');
      if (mounted) setState(() => _nodesError = '节点目录读取失败：$e');
    }
  }

  /// 本地插件面板初始化（P0-3 同口径）：Binder 通道拉扫同机插件（零配置自动
  /// 挂载），订阅包变更流做热刷新；失败（通道不可用）置面板级错误态 + 重试，
  /// 不再永显「读取本地插件…」。
  Future<void> _initLocalPlugins() async {
    try {
      _localScan = widget.localScanOverride ?? localPluginDiscovery.scan;
      final changes =
          widget.localChangesOverride ?? localPluginDiscovery.changes;
      // 重试路径防重复订阅：先摘旧订阅再挂新（幂等）。
      await _localChangesSub?.cancel();
      _localChangesSub = changes.listen((_) {
        if (mounted) unawaited(_reloadLocalPlugins());
      });
      await _reloadLocalPlugins();
      if (mounted) setState(() => _localError = null);
    } catch (e) {
      debugPrint('[DEGRADE] local-plugins-panel: 初始化失败: $e');
      if (mounted) setState(() => _localError = '本地插件读取失败：$e');
    }
  }

  Future<void> _reloadGateway() async {
    final running = gatewayRunning;
    final addrs = running
        ? await gatewayLanAddresses()
        : const <String>[];
    if (!mounted) return;
    setState(() {
      _gwRunning = running;
      _gwLanAddrs = addrs;
      _gwBusy = false;
    });
  }

  /// 起停 PC 远程网关（:8766）。Token 在起服时落盘——改 Token 须关再开才生效
  /// （闸门校验发生在 start 时读入的那份）。
  Future<void> _toggleGateway(bool value) async {
    setState(() => _gwBusy = true);
    final token = _gwTokenCtrl.text.trim();
    try {
      if (value) {
        await SharedPreferences.getInstance().then(
          (sp) => sp.setString('gateway.token', token),
        );
        await startGateway(port: 8766, token: token);
      } else {
        await stopGateway();
      }
    } on Object catch (e) {
      if (mounted) _flash('⚠ 网关${value ? '起服' : '停服'}失败: $e');
    }
    await _reloadGateway();
  }

  /// 生产装配（经 ServiceDirectory 单一入口 `lib/app/service_directory.dart`，
  /// 步 0-T7 收敛；文件同址，多页面读写互见）。
  Future<ServerEndpointStore> _epStoreProd() => serverEndpointStore();

  Future<void> _reloadEndpoints(ServerEndpointStore store) async {
    final eps = await store.load();
    final keys = <String, String?>{};
    for (final e in eps) {
      try {
        keys[e.id] = await store.apiKey(e.id);
      } on Object catch (err) {
        debugPrint('[DEGRADE] nodes-panel: 令牌存况读取失败按无令牌: $err');
      }
    }
    if (!mounted) return;
    setState(() {
      _epStore = store;
      _endpoints = eps;
      _epKeys
        ..clear()
        ..addAll(keys);
      _addingEp = false;
      _editingEpId = null;
      // 探活状态按现目录裁剪（删掉的端点不留残影）。
      _probeStates.removeWhere((id, _) => eps.every((e) => e.id != id));
    });
  }

  Future<void> _probeAll() async {
    final prober = _epStore == null
        ? null
        : (widget.probeOverride ?? _prodProbe);
    if (prober == null || _probing || _endpoints.isEmpty) return;
    setState(() {
      _probing = true;
      for (final e in _endpoints) {
        _probeStates[e.id] = null; // null = 探测中
      }
    });
    await Future.wait([for (final e in _endpoints) _probeOne(e, prober)]);
    if (mounted) setState(() => _probing = false);
  }

  Future<void> _probeOne(ServerEndpoint ep, NodeProbeFn prober) async {
    String? key;
    try {
      key = await _epStore?.apiKey(ep.id);
    } on Object catch (e) {
      debugPrint('[DEGRADE] nodes-panel: 令牌读取失败按无令牌探活: $e');
    }
    final r = await prober(
      ep.endpoint,
      apiKey: (key == null || key.isEmpty) ? null : key,
    );
    if (!mounted) return;
    setState(() => _probeStates[ep.id] = r);
  }

  NodeProbeFn get _prodProbe =>
      (endpoint, {String? apiKey}) =>
          ServerProber().probe(endpoint, apiKey: apiKey);

  // —— 节点卡增删改（P1 设置拆分：与原 chat_page ⚙ 同一 store 文件同口径）——

  Future<void> _addEndpoint(
    String id,
    String name,
    String endpoint,
    String token,
  ) async {
    final store = _epStore;
    if (store == null) return;
    final newEp = ServerEndpoint(
      id: id,
      name: name.isEmpty ? id : name,
      endpoint: endpoint,
      hasKey: token.isNotEmpty,
    );
    await store.save([..._endpoints, newEp]);
    if (token.isNotEmpty) await store.setApiKey(id, token);
    await _reloadEndpoints(store);
    _flash('✓ 已添加服务 $id');
  }

  Future<void> _saveEndpointEdit(
    ServerEndpoint ep,
    String endpoint,
    String token,
  ) async {
    final store = _epStore;
    if (store == null) return;
    await store.save([
      for (final e in _endpoints)
        if (e.id == ep.id) ep.copyWith(endpoint: endpoint) else e,
    ]);
    await store.setApiKey(ep.id, token.isEmpty ? null : token);
    await _reloadEndpoints(store);
    _flash('✓ 已更新服务 ${ep.name}');
  }

  Future<void> _deleteEndpoint(ServerEndpoint ep) async {
    final store = _epStore;
    if (store == null) return;
    // 破坏性防护：删除连带清令牌，先确认（与聊天页删除会话/BYOK 同口径）。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('删除服务 ${ep.name}'),
        content: const Text('端点配置及其已存令牌将被一并清除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: consoleTokens(dialogCtx).danger,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.save([
      for (final e in _endpoints)
        if (e.id != ep.id) e,
    ]);
    await store.setApiKey(ep.id, null);
    await _reloadEndpoints(store);
    _flash('✓ 已删除服务 ${ep.name}');
  }

  /// 挂载开关（ui-design §3.3 物理开关质感语义）：卸载只摘出连接池
  /// （_send 跳过 enabled=false），配置与令牌保留，重开即恢复。
  Future<void> _toggleMounted(ServerEndpoint ep, bool value) async {
    final store = _epStore;
    if (store == null) return;
    await store.save([
      for (final e in _endpoints)
        if (e.id == ep.id) e.copyWith(enabled: value) else e,
    ]);
    await _reloadEndpoints(store);
    _flash(value ? '✓ 已挂载 ${ep.name}' : '⊘ 已卸载 ${ep.name}（配置与令牌保留）');
  }

  Future<void> _reloadByok(ByokStore store) async {
    final profiles = await store.load();
    final withKey = <String>{};
    for (final p in profiles) {
      if (await store.apiKey(p.id) != null) withKey.add(p.id);
    }
    final preferred = await store.preferredProfileId();
    if (mounted) {
      setState(() {
        _byokStore = store;
        _byokProfiles = profiles;
        _hasByokKey
          ..clear()
          ..addAll(withKey);
        _byokPreferredId =
            preferred ?? (profiles.isNotEmpty ? profiles.first.id : null);
        _creatingByok = false;
        _editingByokId = null;
      });
    }
  }

  Future<void> _reload(CowOverridesStore store) async {
    final names = await store.overrideNames();
    final entries = <String, DateTime?>{};
    for (final n in names) {
      entries[n] = await store.overriddenAt(n);
    }
    if (mounted) {
      setState(() {
        _store = store;
        _entries = entries;
        _creating = false;
        _editingName = null;
      });
    }
  }

  Future<void> _save(String name, String content) async {
    final store = _store;
    if (store == null) return;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      _flash('覆写正文不能为空');
      return;
    }
    if (trimmed.length > kCowOverrideMaxChars) {
      _flash('覆写正文超防呆上限（$kCowOverrideMaxChars 字符）');
      return;
    }
    await store.setOverride(name, trimmed);
    await _reload(store);
  }

  Future<void> _reset(String name) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置覆写'),
        content: Text('弃用「$name」的本地覆写副本？下次模板同步将回 server 版。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.reset(name);
    await _reload(store);
  }

  void _flash(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 面板级错误态（ux-hardening P0-3）：Rose 文案 + 重试按钮。替代两种历史
  /// 病：一处初始化失败打死整页（其余面板可用被替换）；store 读取失败后
  /// `store == null` 永显「读取中…」（错误不可见、无恢复入口）。
  Widget _panelError(
    ConsoleTokens t,
    String message,
    VoidCallback onRetry, {
    ValueKey<String>? key,
  }) {
    return Padding(
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
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // ux-hardening P0-3：面板初始化失败不再打死整页——各面板自持错误态
      // （Rose + 重试），此处恒渲染完整面板列表。
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // 顺序按使用频率：先选引擎，再接服务，后管放行与覆写。
          _byokPanel(context, t),
          const SizedBox(height: 12),
          _nodesPanel(context, t),
          const SizedBox(height: 12),
          _localPluginsPanel(context, t),
          const SizedBox(height: 12),
          _gatewayPanel(context, t),
          const SizedBox(height: 12),
          _cowPanel(context, t),
          const SizedBox(height: 12),
          _crossSourcePanel(context, t),
          const SizedBox(height: 12),
          _aboutPanel(context, t),
        ],
      ),
    );
  }

  // —— 面板一：Skill 覆写管理（CoW） ——

  Widget _cowPanel(BuildContext context, ConsoleTokens t) {
    final store = _store;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Skill 覆写管理',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '覆写 ${_entries.length} 项',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '官方模板（goodshare prompts）的本地覆写副本，优先级最高；'
              '官方模板大版本更新时，同步流会弹卡让你选重置或保留本地改法。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            // P2-1：覆写文件损坏备份警示——旧行为是用户手改变的配置被无声
            // 清空（按空库重写），现在备份保留 + 面板明示。
            if (store != null && store.corruptBackupPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '⚠ 覆写文件损坏，已备份为 ${store.corruptBackupPath}；'
                  '当前按空库显示，可手动找回备份。',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
                ),
              ),
            if (_cowError != null)
              _panelError(
                t,
                _cowError!,
                _initCow,
                key: const ValueKey('cow-error'),
              )
            else if (store == null)
              const Padding(
                padding: EdgeInsets.all(8),
                // 静态文案不用 spinner：无限动画会让 pumpAndSettle 永不收口，
                // 且加载是瞬时路径（本地文件读），控制台风格无 spin 语义。
                child: Center(
                  child: Text(
                    '读取覆写库…',
                    style: TextStyle(fontSize: Fsz.telemetry),
                  ),
                ),
              )
            else ...[
              for (final name in _entries.keys) _cowItem(context, t, name),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '（暂无覆写——模板按 server 版生效）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              if (_creating) _newEditor(context, t),
              if (!_creating)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('cow-new'),
                    onPressed: () => setState(() => _creating = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建覆写'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cowItem(BuildContext context, ConsoleTokens t, String name) {
    final editing = _editingName == name;
    final at = _entries[name];
    return Container(
      key: Key('cow-item-$name'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: editing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  key: const Key('cow-edit-field'),
                  controller: _editCtrl,
                  maxLines: 6,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '覆写正文（markdown，与模板同构）',
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _editingName = null),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('cow-save'),
                      onPressed: () => _save(name, _editCtrl.text),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.telemetry,
                        ),
                      ),
                      if (at != null)
                        Text(
                          '覆写于 ${at.toIso8601String()}',
                          style: TextStyle(
                            fontSize: Fsz.micro,
                            color: t.terminalMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('cow-edit-$name'),
                  tooltip: '编辑',
                  iconSize: 18,
                  onPressed: () {
                    _editingName = name;
                    _editCtrl.text = '';
                    _loadForEdit(name);
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('cow-reset-$name'),
                  tooltip: '一键重置',
                  iconSize: 18,
                  onPressed: () => _reset(name),
                  icon: const Icon(Icons.restart_alt_outlined),
                ),
              ],
            ),
    );
  }

  Future<void> _loadForEdit(String name) async {
    final content = await _store?.overrideOf(name);
    if (mounted) {
      setState(() {
        _editCtrl.text = content ?? '';
      });
    }
  }

  Widget _newEditor(BuildContext context, ConsoleTokens t) => Container(
    key: const Key('cow-new-editor'),
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(t.cardRadius),
      border: Border.all(color: t.hairline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('cow-new-name'),
          controller: _newNameCtrl,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          decoration: const InputDecoration(
            labelText: '模板名（prompts/list 的 name）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('cow-new-content'),
          controller: _newContentCtrl,
          maxLines: 6,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            hintText: '覆写正文（markdown，与模板同构）',
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() => _creating = false),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('cow-create'),
              onPressed: () {
                final name = _newNameCtrl.text.trim();
                if (name.isEmpty) {
                  _flash('模板名不能为空');
                  return;
                }
                _save(name, _newContentCtrl.text);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ],
    ),
  );

  // —— 面板二：BYOK 云端引擎（M4-T5） ——

  /// 装配语义：hybrid_assembly 取列表首个 profile 为生效云端引擎——首位即
  /// 「生效中」，置顶动作即切换生效配置（不改装配线，零回归面）。
  Widget _byokPanel(BuildContext context, ConsoleTokens t) {
    final store = _byokStore;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  // P1-7：标题去首字母缩略语——BYOK 对普通用户是黑话。
                  '云端引擎（自带 API Key）',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '配置 ${_byokProfiles.length} 项',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '用你自己的 API Key 接入云端模型（OpenAI 兼容 / Anthropic）。'
              '标注「生效中」的是当前实际使用的模型，可点「设为生效引擎」切换。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_byokError != null)
              _panelError(
                t,
                _byokError!,
                _initByok,
                key: const ValueKey('byok-error'),
              )
            else if (store == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: Text(
                    '读取模型配置…',
                    style: TextStyle(fontSize: Fsz.telemetry),
                  ),
                ),
              )
            else ...[
              for (final p in _byokProfiles) _byokItem(context, t, p),
              if (_byokProfiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    // P1-7：空态文案去「装配」黑话。
                    '（暂无模型配置——未接入云端模型，仅端侧路径）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              if (_creatingByok) _byokEditor(context, t, null),
              if (!_creatingByok)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('byok-new'),
                    onPressed: () => setState(() => _creatingByok = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加模型'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _byokItem(BuildContext context, ConsoleTokens t, ByokProfile p) {
    final editing = _editingByokId == p.id;
    final hasKey = _hasByokKey.contains(p.id);
    final active = _byokPreferredId == p.id;
    return Container(
      key: Key('byok-item-${p.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        // 生效中 = L1 就绪语义（Amber 是写操作警示，不挪用）。
        border: Border.all(
          color: active ? t.l1Ok : t.hairline,
          width: active ? 1.2 : 1,
        ),
      ),
      child: editing
          ? _byokEditor(context, t, p)
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              p.name,
                              style: TextStyle(
                                fontFamily: t.monoFamily,
                                fontSize: Fsz.telemetry,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 6),
                            Text(
                              '生效中',
                              style: TextStyle(
                                fontSize: Fsz.microSm,
                                color: t.l1Ok,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '${_protoLabel(p.protocol)} · ${p.model}\n'
                        '${p.baseUrl}${hasKey ? ' · 已存密钥' : ' · ⚠ 未存密钥'}',
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.micro,
                          color: t.terminalMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!active)
                  IconButton(
                    key: Key('byok-top-${p.id}'),
                    tooltip: '设为生效引擎',
                    iconSize: 18,
                    onPressed: () => _byokMoveTop(p),
                    icon: const Icon(Icons.vertical_align_top_outlined),
                  ),
                IconButton(
                  key: Key('byok-edit-${p.id}'),
                  tooltip: '编辑',
                  iconSize: 18,
                  onPressed: () => setState(() {
                    _editingByokId = p.id;
                    _byokNameCtrl.text = p.name;
                    _byokProto = p.protocol;
                    _byokUrlCtrl.text = p.baseUrl;
                    _byokModelCtrl.text = p.model;
                    _byokTempCtrl.text = p.temperature?.toString() ?? '';
                    _byokKeyCtrl.clear();
                  }),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('byok-del-${p.id}'),
                  tooltip: '删除',
                  iconSize: 18,
                  onPressed: () => _deleteByok(p),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
    );
  }

  /// 新增（profile == null）与编辑共用表单；编辑模式密钥留空 = 保持已存密钥。
  Widget _byokEditor(
    BuildContext context,
    ConsoleTokens t,
    ByokProfile? profile,
  ) {
    final isEdit = profile != null;
    return Container(
      key: Key(isEdit ? 'byok-edit-form' : 'byok-new-form'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('byok-field-name'),
            controller: _byokNameCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: '显示名',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          SegmentedButton<CloudProtocol>(
            segments: const [
              ButtonSegment(
                value: CloudProtocol.openaiCompatible,
                label: Text('OpenAI 兼容'),
              ),
              ButtonSegment(
                value: CloudProtocol.anthropic,
                label: Text('Anthropic'),
              ),
            ],
            selected: {_byokProto},
            onSelectionChanged: (s) => setState(() => _byokProto = s.first),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-url'),
            controller: _byokUrlCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: 'Base URL',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-model'),
            controller: _byokModelCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: '模型 ID（如 deepseek-chat / claude-sonnet-4-5）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-temp'),
            controller: _byokTempCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Temperature（可空）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-key'),
            controller: _byokKeyCtrl,
            obscureText: true,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: InputDecoration(
              labelText: isEdit ? 'API Key（留空 = 保持已存密钥）' : 'API Key',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  if (isEdit) {
                    _editingByokId = null;
                  } else {
                    _creatingByok = false;
                  }
                }),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: Key(isEdit ? 'byok-save' : 'byok-create'),
                onPressed: () =>
                    isEdit ? _saveByokEdit(profile) : _createByok(),
                child: Text(isEdit ? '保存' : '创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _protoLabel(CloudProtocol p) => switch (p) {
    CloudProtocol.openaiCompatible => 'OpenAI 兼容',
    CloudProtocol.anthropic => 'Anthropic',
  };

  /// 表单 → profile 校验（name/baseUrl/model 必填；temperature 容错解析）。
  /// 返回 null = 校验失败（已 flash 提示）。
  ByokProfile? _collectForm(String id) {
    final name = _byokNameCtrl.text.trim();
    final url = _byokUrlCtrl.text.trim();
    final model = _byokModelCtrl.text.trim();
    final tempText = _byokTempCtrl.text.trim();
    if (name.isEmpty || url.isEmpty || model.isEmpty) {
      _flash('显示名 / Base URL / 模型 ID 均必填');
      return null;
    }
    double? temp;
    if (tempText.isNotEmpty) {
      temp = double.tryParse(tempText);
      if (temp == null) {
        _flash('Temperature 须为数字（如 0.2）');
        return null;
      }
    }
    return ByokProfile(
      id: id,
      name: name,
      protocol: _byokProto,
      baseUrl: url,
      model: model,
      temperature: temp,
    );
  }

  Future<void> _createByok() async {
    final store = _byokStore;
    if (store == null) return;
    final key = _byokKeyCtrl.text.trim();
    if (key.isEmpty) {
      _flash('API Key 必填（走安全存储，不落明文）');
      return;
    }
    var id = 'byok_${DateTime.now().millisecondsSinceEpoch}';
    while (_byokProfiles.any((p) => p.id == id)) {
      id = 'byok_${DateTime.now().microsecondsSinceEpoch}';
    }
    final profile = _collectForm(id);
    if (profile == null) return;
    await store.save([..._byokProfiles, profile]);
    await store.setApiKey(id, key);
    await _reloadByok(store);
    _flash('✓ 已添加 ${profile.name}');
  }

  Future<void> _saveByokEdit(ByokProfile old) async {
    final store = _byokStore;
    if (store == null) return;
    final profile = _collectForm(old.id);
    if (profile == null) return;
    final key = _byokKeyCtrl.text.trim();
    await store.save([
      for (final p in _byokProfiles)
        if (p.id == old.id) profile else p,
    ]);
    if (key.isNotEmpty) await store.setApiKey(old.id, key);
    await _reloadByok(store);
    _flash('✓ 已更新 ${profile.name}');
  }

  Future<void> _byokMoveTop(ByokProfile p) async {
    final store = _byokStore;
    if (store == null) return;
    // 重排（首位展示惯例）+ 写生效位：装配以 preferred 为准（未选才回退首位）。
    await store.save([p, ..._byokProfiles.where((e) => e.id != p.id)]);
    await store.setPreferredProfileId(p.id);
    await _reloadByok(store);
    _flash('✓ 已切换生效引擎：${p.name}');
  }

  Future<void> _deleteByok(ByokProfile p) async {
    final store = _byokStore;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型配置'),
        content: Text('删除「${p.name}」（${p.model}）？其已存密钥将一并清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: consoleTokens(ctx).danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // save 自带孤儿密钥连带清理（被移除 profile 的密钥删除）。
    await store.save(_byokProfiles.where((e) => e.id != p.id).toList());
    await _reloadByok(store);
    _flash('✓ 已删除 ${p.name}');
  }

  // —— 面板三：跨源授权语义（D5） ——

  Widget _crossSourcePanel(BuildContext context, ConsoleTokens t) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '跨源授权（\$ref 联合授权）',
            style: const TextStyle(
              fontSize: Fsz.sectionTitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A 应用的工具输出经 \$ref 句柄传给 B 应用工具时，宿主弹卡确认后'
            '才注水放行——句柄是模型侧行话，真实数据永不出网关。',
            style: TextStyle(
              fontSize: Fsz.telemetrySm,
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 8),
          _policyRow(
            context,
            Icons.gavel_outlined,
            '恒 L2 弹卡确认',
            '每次跨源都需确认——会话豁免不适用（豁免按工具粒度防不住数据面风险）',
          ),
          _policyRow(
            context,
            Icons.visibility_off_outlined,
            // P1-7：策略行标题去黑话（禁盲签 → 看得懂的动作口径）。
            '看不清不放行',
            '数据摘要不可读即拒；摘要封顶 300 字符（标题+前 5 行）',
          ),
          _policyRow(
            context,
            Icons.lock_outline,
            '不记忆不豁免',
            '与隐私围栏同口径：显式确认不落盘、不旁路 N7 出站围栏',
          ),
          const SizedBox(height: 8),
          // 联调入口仅 debug 构建（正式面不暴露调试工具）。
          if (kDebugMode)
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const GatewayLoopDebugPage(),
                  ),
                ),
                icon: const Icon(Icons.science_outlined, size: 16),
                label: const Text('去联调页实测'),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _policyRow(
    BuildContext context,
    IconData icon,
    String title,
    String desc,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: consoleTokens(context).l2Warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$title：',
                  style: const TextStyle(fontSize: Fsz.telemetry),
                ),
                TextSpan(
                  text: desc,
                  style: TextStyle(
                    fontSize: Fsz.telemetry,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  // —— 面板四：Server 节点卡（M4-T5，ui-design §3.3） ——

  Widget _nodesPanel(BuildContext context, ConsoleTokens t) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Server 节点',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_endpoints.isNotEmpty)
                  OutlinedButton.icon(
                    key: const Key('nodes-probe-all'),
                    onPressed: _probing ? null : _probeAll,
                    icon: const Icon(Icons.radar_outlined, size: 16),
                    label: Text(_probing ? '探测中…' : '探测全部'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '已配置的 MCP 服务节点。卸载开关只把节点摘出会话装配，配置与'
              '令牌保留；鉴权被拒（403）用红色标注，与离线区分。'
              '图钉 = 钉选为默认私有服务（新会话默认锁定，聊天页可临时改本次会话）。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_nodesError != null)
              _panelError(
                t,
                _nodesError!,
                _initNodes,
                key: const ValueKey('nodes-error'),
              )
            else if (_epStore == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: Text(
                    '读取节点目录…',
                    style: TextStyle(fontSize: Fsz.telemetry),
                  ),
                ),
              )
            else ...[
              for (final ep in _endpoints)
                _nodeItem(context, t, ep, _probeStates[ep.id]),
              if (_endpoints.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '（暂无节点——点下方「添加服务」接入远程 MCP；本地插件见下方「本地插件」面板）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              if (_addingEp)
                ServerEndpointAddForm(
                  onAdd: _addEndpoint,
                  onCancel: () => setState(() => _addingEp = false),
                ),
              if (!_addingEp)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('nodes-add'),
                    onPressed: () => setState(() => _addingEp = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加服务'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _nodeItem(
    BuildContext context,
    ConsoleTokens t,
    ServerEndpoint ep,
    NodeProbeResult? probe,
  ) {
    final probing = _probeStates.containsKey(ep.id) && probe == null;
    return Container(
      key: Key('node-item-${ep.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusDot(t, probing, probe),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            ep.name,
                            style: TextStyle(
                              fontFamily: t.monoFamily,
                              fontSize: Fsz.telemetry,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!ep.enabled) ...[
                          const SizedBox(width: 6),
                          Text(
                            '已卸载',
                            style: TextStyle(
                              fontSize: Fsz.microSm,
                              color: t.terminalMuted,
                            ),
                          ),
                        ],
                        // 默认私有 pill（与「已卸载」同款行内态；仅 eligible 时出现）。
                        if (_isDefaultPrivate(ep.id) &&
                            ep.enabled &&
                            ep.tier == ServerPrivacyTier.private) ...[
                          const SizedBox(width: 6),
                          _defaultPill(t),
                        ],
                      ],
                    ),
                    Text(
                      '${ep.endpoint}\n'
                      '端口 ${_portLabel(ep.endpoint)} · ${_metricsLabel(probe)} · '
                      '${_authLabel(ep, probe)}',
                      style: TextStyle(
                        fontFamily: t.monoFamily,
                        fontSize: Fsz.micro,
                        color: t.terminalMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // 内联编辑/删除（P1 设置拆分：全生命周期收敛本面板）。
              IconButton(
                key: Key('node-edit-${ep.id}'),
                tooltip: _editingEpId == ep.id ? '收起' : '编辑',
                iconSize: 18,
                icon: Icon(
                  _editingEpId == ep.id ? Icons.close : Icons.edit_outlined,
                ),
                onPressed: () => setState(() {
                  _editingEpId = _editingEpId == ep.id ? null : ep.id;
                }),
              ),
              IconButton(
                key: Key('node-del-${ep.id}'),
                tooltip: '删除',
                iconSize: 18,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(_deleteEndpoint(ep)),
              ),
              // 默认私有服务钉选（方案 A：原独立面板撤销，降级为行内图钉；
              // 非破坏性即时写，无确认卡——与原 radio 单选同口径）。
              _defaultPinButton(
                pinKey: Key('node-default-${ep.id}'),
                id: ep.id,
                label: ep.name,
                eligible: ep.enabled && ep.tier == ServerPrivacyTier.private,
              ),
              // 破坏性操作与高频挂载开关之间留间距，防误触卸载成删除。
              const SizedBox(width: 6),
              // 挂载/卸载开关（微型物理开关语义，Dual-Role 本地总线心智）。
              Switch(
                key: Key('node-switch-${ep.id}'),
                value: ep.enabled,
                onChanged: (v) => _toggleMounted(ep, v),
              ),
            ],
          ),
          if (_editingEpId == ep.id)
            ServerEndpointEditForm(
              ep: ep,
              storedKey: _epKeys[ep.id],
              onSave: (updated, token) =>
                  _saveEndpointEdit(ep, updated.endpoint, token),
              onCancel: () => setState(() => _editingEpId = null),
            ),
        ],
      ),
    );
  }

  /// 在线状态点（在线绿 / 待授权与离线 Rose / 探测中 Cyan / 未探测灰）。
  Widget _statusDot(ConsoleTokens t, bool probing, NodeProbeResult? probe) {
    final color = probing
        ? t.l1Info
        : probe == null
        ? t.terminalMuted
        : probe.online && !probe.authDenied
        ? t.l1Ok
        : t.danger;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  /// 端口号：显式端口优先；缺省按 scheme 补 80/443，解析不出显示「?」。
  String _portLabel(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null) return '?';
    if (uri.port != 0) return '${uri.port}';
    return switch (uri.scheme) {
      'https' => '443（默认）',
      'http' => '80（默认）',
      _ => '?',
    };
  }

  String _metricsLabel(NodeProbeResult? probe) {
    if (probe == null) return '延迟 — · 工具 —';
    if (!probe.online) return '延迟 — · 工具 —';
    final tool = probe.toolCount != null ? '${probe.toolCount}' : '?';
    return '延迟 ${probe.latencyMs}ms · 工具 $tool';
  }

  /// 鉴权态（F1.17）：已授权 / 待授权 403（Rose）/ 离线；配合 hasKey 展示
  /// 令牌存况（密钥纪律：永不回显真值）。
  String _authLabel(ServerEndpoint ep, NodeProbeResult? probe) {
    if (probe != null && probe.authDenied) return '⚠ 待授权(403)';
    if (probe != null && probe.online) return '已授权';
    if (probe != null) return '离线';
    return ep.hasKey ? '未探测 · 已存令牌' : '未探测 · 无令牌';
  }

  // —— 面板七：关于（版本 + 检查更新；长按标题进 debug 联调入口） ——

  /// debug 联调入口（2026-10-16 自聊天页 AppBar 迁入）：仅 debug 构建经长按
  /// 「关于」唤出，避免联调入口占据正式面。检查更新是正式功能，常驻可见不藏。
  Future<void> _openDebugMenu() async {
    if (!kDebugMode) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('网关/熔断联调'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const GatewayLoopDebugPage(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.repeat_outlined),
              title: const Text('M1 任务循环（claim/apply）'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ClaimLoopPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _aboutPanel(BuildContext context, ConsoleTokens t) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 长按标题 = debug 联调入口（kDebugMode 内自闸；release 长按无响应）。
            GestureDetector(
              key: const Key('about-title'),
              onLongPress: _openDebugMenu,
              child: Text(
                '关于',
                style: const TextStyle(
                  fontSize: Fsz.sectionTitle,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'GoodHub $_appVersion',
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetrySm,
                color: t.terminalMuted,
              ),
            ),
            if (kDebugMode)
              Text(
                '（debug 构建：长按「关于」进入联调入口）',
                style: TextStyle(fontSize: Fsz.microSm, color: t.terminalMuted),
              ),
            ListTile(
              key: const Key('about-check-update'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const UpdatePage()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // —— 面板四·a：PC 远程网关（:8766；2026-10-16 自聊天页 ⚙ 迁入） ——

  Widget _gatewayPanel(BuildContext context, ConsoleTokens t) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PC 远程网关',
              style: const TextStyle(
                fontSize: Fsz.sectionTitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const Key('gateway-toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text('暴露 :8766（Streamable HTTP）'),
              subtitle: Text(
                _gwRunning
                    ? '运行中——PC 配置：'
                          '${_gwLanAddrs.isEmpty ? 'http://<手机IP>' : _gwLanAddrs.map((a) => 'http://$a').join(' 或 ')}'
                          ':8766/mcp（ADB 场景 127.0.0.1:8766）'
                    : '关闭——开启后 PC 经 Streamable HTTP 调用手机内全部服务',
                style: const TextStyle(fontSize: Fsz.telemetrySm),
              ),
              value: _gwRunning,
              // 起服含端口绑定（非瞬时），期间禁重复触发。
              onChanged: _gwBusy ? null : _toggleGateway,
            ),
            TextField(
              key: const Key('gateway-token'),
              controller: _gwTokenCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '配对 Token（可空；留空 = 不鉴权，仅建议 ADB 调试）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '⚠ 开启后同一局域网的 PC 可经 :8766 调用本机全部服务；Token 留空即'
              '不鉴权，仅建议 ADB 调试场景。改 Token 需关闭后再开启才生效。',
              style: TextStyle(fontSize: Fsz.telemetrySm, color: t.danger),
            ),
          ],
        ),
      ),
    );
  }

  // —— 面板四·b：本地插件（同机 Binder 发现，零配置自动挂载） ——

  Future<void> _reloadLocalPlugins() async {
    final scan = _localScan;
    if (scan == null) return;
    final found = await scan();
    var trusted = const <String>{};
    try {
      final tp = await TrustedPlugins.instance;
      trusted = tp.all().keys.toSet();
    } on Object catch (e) {
      debugPrint('[DEGRADE] local-plugins-panel: 信任白名单读取失败按空: $e');
    }
    if (!mounted) return;
    setState(() {
      _localPlugins = found;
      _trustedPackages = trusted;
    });
  }

  Future<void> _trustPlugin(LocalPluginInfo info) async {
    final ok = await showTrustCard(context, info);
    if (ok && mounted) {
      await _reloadLocalPlugins();
      _flash('✓ 已信任 ${info.serverTitle}');
    }
  }

  /// 撤销信任（2026-10-16 自聊天页 ⚙ 迁入——原设置弹层的真缺口，大厅只有信任）。
  ///
  /// 语义 = **仅移出白名单，不动连接池**：信任闸门是装配期校验而非长连接状态
  /// ——本机下一轮装配重新弹信任卡（`chat_page` 装配循环），PC 网关侧下一轮
  /// `_assemble` 直接跳过不再暴露（`gateway_controller`）。故撤销无需断开现有
  /// 连接，也不必触碰 ConnectionManager。
  Future<void> _untrustPlugin(LocalPluginInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销信任'),
        content: Text(
          '撤销后「${info.serverTitle}」：本机下次使用需重新确认信任；'
          'PC 远程网关将不再暴露它。当前会话已建立的连接不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤销信任'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final tp = await TrustedPlugins.instance;
      await tp.remove(info.packageName);
      await _reloadLocalPlugins();
      _flash('✓ 已撤销对 ${info.serverTitle} 的信任');
    } on Object catch (e) {
      _flash('⚠ 撤销信任失败: $e');
    }
  }

  Widget _localPluginsPanel(BuildContext context, ConsoleTokens t) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '本地插件（同机发现）',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '发现 ${_localPlugins.length} 项',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '已安装且声明 MCP_SERVER 的同机插件，零配置自动挂载；同签名私有生态免确认，'
              '第三方首次需信任确认。不进手填配置（与远端节点不同源）。'
              '图钉 = 钉选为默认私有服务（与「Server 节点」同一默认键）。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_localError != null)
              _panelError(
                t,
                _localError!,
                _initLocalPlugins,
                key: const ValueKey('local-error'),
              )
            else if (_localScan == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: Text(
                    '读取本地插件…',
                    style: TextStyle(fontSize: Fsz.telemetry),
                  ),
                ),
              )
            else ...[
              for (final p in _localPlugins) _localPluginItem(context, t, p),
              if (_localPlugins.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '（暂无本地插件——安装声明 MCP_SERVER 的同机应用后自动出现）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _localPluginItem(
    BuildContext context,
    ConsoleTokens t,
    LocalPluginInfo p,
  ) {
    final trusted = p.sameSignature || _trustedPackages.contains(p.packageName);
    return Container(
      key: Key('local-plugin-${p.transportId}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Row(
        children: [
          // 已发现即接入（Binder 通道存在 = 自动挂载）；会话内是否可调用须由
          // 上下文菜单锁定私有槽位决定（私有≠免隔离）。绿色点表「已发现」。
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: t.l1Ok, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.serverTitle.isNotEmpty ? p.serverTitle : p.serverId,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${p.packageName}\n${p.transportId}',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.micro,
                    color: t.terminalMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '已挂载（自动）',
                      style: TextStyle(
                        fontSize: Fsz.microSm,
                        color: t.terminalMuted,
                      ),
                    ),
                    // 默认私有 pill（方案 A：与节点卡同款行内态）。
                    if (_isDefaultPrivate(p.serverId)) ...[
                      const SizedBox(width: 8),
                      _defaultPill(t),
                    ],
                    const SizedBox(width: 8),
                    if (p.sameSignature)
                      Text(
                        '私有生态 · 自动信任',
                        style: TextStyle(
                          fontSize: Fsz.microSm,
                          color: t.l1Ok,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else if (trusted) ...[
                      Text(
                        '已信任',
                        style: TextStyle(
                          fontSize: Fsz.microSm,
                          color: t.l1Ok,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // 同签名私有生态免确认（不入白名单，无撤销对象）。
                      if (!p.sameSignature) ...[
                        const SizedBox(width: 6),
                        // P1-8：撤销入口补后果 tooltip（可发现性 = 看得见
                        // + 看得懂点了会怎样）。TextButton 无 tooltip 形参，
                        // 外包 Tooltip 承载。
                        Tooltip(
                          message: '撤销后下次使用需重新确认信任，PC 网关也不再暴露它',
                          child: TextButton(
                            key: Key('local-untrust-${p.transportId}'),
                            onPressed: () => _untrustPlugin(p),
                            child: const Text('撤销'),
                          ),
                        ),
                      ],
                    ] else ...[
                      Text(
                        '待信任',
                        style: TextStyle(
                          fontSize: Fsz.microSm,
                          color: t.l2Warn,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        key: Key('local-trust-${p.transportId}'),
                        onPressed: () => _trustPlugin(p),
                        child: const Text('信任'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // 默认私有服务钉选（方案 A：与节点卡同款图钉；候选 = serverId 非空）。
          _defaultPinButton(
            pinKey: Key('local-default-${p.transportId}'),
            id: p.serverId,
            label: p.serverTitle.isNotEmpty ? p.serverTitle : p.serverId,
            eligible: p.serverId.isNotEmpty,
          ),
        ],
      ),
    );
  }

  // —— 默认私有服务（方案 A：统一钉选降级为 ②③ 卡片行内态，2026-10-16）——

  /// 当前卡片是否为持久默认（空 id 永假——防空串与「无默认」初始态误判）。
  bool _isDefaultPrivate(String id) => id.isNotEmpty && _defaultPrivateId == id;

  /// 「默认私有」pill（L1 就绪语义，与「生效中 / 已信任」同款字形）。
  Widget _defaultPill(ConsoleTokens t) => Text(
    '默认私有',
    style: TextStyle(
      fontSize: Fsz.microSm,
      color: t.l1Ok,
      fontWeight: FontWeight.w600,
    ),
  );

  /// 默认私有服务钉选按钮：filled pin + L1 = 当前默认（再点取消）；outline =
  /// 可设默认。非破坏性即时写（无确认卡，与原 radio 单选同口径）。
  ///
  /// [eligible] = 候选资格，与撤销前 `_defaultPrivateCandidates` 同过滤口径：
  /// 远端节点须 `enabled && tier == private`；本地插件须 `serverId` 非空
  /// （含未信任项——信任闸门在装配期仍会拦，不在此预过滤）。
  Widget _defaultPinButton({
    required Key pinKey,
    required String id,
    required String label,
    required bool eligible,
  }) {
    if (!eligible) return const SizedBox.shrink();
    final t = consoleTokens(context);
    final isDefault = _isDefaultPrivate(id);
    return IconButton(
      key: pinKey,
      tooltip: isDefault ? '取消默认私有服务' : '设为默认私有服务',
      iconSize: 18,
      onPressed: () =>
          isDefault ? _clearDefaultPrivate() : _setDefaultPrivate(id, label),
      icon: Icon(
        isDefault ? Icons.push_pin : Icons.push_pin_outlined,
        color: isDefault ? t.l1Ok : null,
      ),
    );
  }

  Future<void> _setDefaultPrivate(String id, String label) async {
    try {
      await writeDefaultPrivateServerId(id);
      if (mounted) setState(() => _defaultPrivateId = id);
      _flash('✓ 已设默认私有服务：$label');
    } on Object catch (e) {
      _flash('⚠ 默认私有服务保存失败: $e');
    }
  }

  Future<void> _clearDefaultPrivate() async {
    try {
      await writeDefaultPrivateServerId(null);
      if (mounted) setState(() => _defaultPrivateId = '');
      _flash('✓ 已取消默认私有服务（新会话按纯公共/首私有回退）');
    } on Object catch (e) {
      _flash('⚠ 默认私有服务保存失败: $e');
    }
  }
}
