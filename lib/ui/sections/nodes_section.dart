/// 设置页 · Server 节点卡段（M4-T5，ui-design §3.3；window-slim P1-A 分段拆解
/// 2026-10-17 自 settings_page 迁出）：端点目录读写、令牌存况、探活编排、
/// 增删改表单、挂载开关、**默认私有服务钉选**渲染全部自持。
///
/// 迁移语义原样保留（含测试锚点 Key）：
/// - 服务全生命周期收敛本段（同一 ServerEndpointStore 文件——应用支持目录
///   /mcp_servers.json，聊天页 ⚙ 不再持有）；
/// - 挂载/卸载只摘出连接池，配置与令牌保留；删除连带清令牌且先确认；
/// - 探活状态按现目录裁剪（删掉的端点不留残影）；读取失败置面板级错误态
///   （ux-hardening P0-3：Rose + 重试）；
/// - **默认私有钉选 owner 仍在页面**（与本地插件段共用统一默认键
///   `default.private.server`，跨段一致），本段只经 [isDefaultPrivate] /
///   [onPinToggle] 透传渲染与回调。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/service_directory.dart';
import '../../mcp/server_endpoints.dart';
import '../../mcp/server_probe.dart';
import '../components/server_endpoint_forms.dart';
import '../tokens/console_tokens.dart';

/// 节点卡探活入口（注入位：测试传假探活，生产落 [ServerProber.probe]）。
typedef NodeProbeFn = Future<NodeProbeResult> Function(
  String endpoint, {
  String? apiKey,
});

/// 段 widget：注入 [endpointStoreOverride]（生产 = ServiceDirectory 单入口，
/// 测试传假件）、[probeOverride]（生产 = [ServerProber.probe]）、[autoProbe]
/// （进入段自动探活一次；测试注入假探活时置 false，免干扰计数断言）、钉选回调
/// （owner 在页面）、[onFlash]（页面级 toast 口径）、[errorRowBuilder]（面板级
/// 错误态统一件）。
class NodesSection extends StatefulWidget {
  const NodesSection({
    super.key,
    this.endpointStoreOverride,
    this.probeOverride,
    this.autoProbe = true,
    required this.isDefaultPrivate,
    required this.onPinToggle,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  /// 测试注入位（M4-T5 节点卡）；null = 生产路径（应用支持目录
  /// /mcp_servers.json，与聊天页 ⚙ 设置同一文件）。
  final ServerEndpointStore? endpointStoreOverride;

  /// 测试注入位（M4-T5 节点卡）；null = 生产路径（[ServerProber] 真探活）。
  final NodeProbeFn? probeOverride;

  /// 进入页面自动探活一次（P2；测试注入假探活时置 false 关掉，免干扰计数断言）。
  final bool autoProbe;

  /// 该卡片是否为当前持久默认私有服务（空 id 恒假）。
  final bool Function(String id) isDefaultPrivate;

  /// 图钉点击：isDefault=true 请求取消默认，否则请求设为默认（写持久在页面）。
  final Future<void> Function(String id, String label, bool isDefault)
      onPinToggle;

  final void Function(String message) onFlash;

  /// 面板级错误态（ux-hardening P0-3 口径：Rose 文案 + 重试入口）。
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<NodesSection> createState() => _NodesSectionState();
}

class _NodesSectionState extends State<NodesSection>
    with AutomaticKeepAliveClientMixin {
  /// ListView 懒构建会把滚出视口的 sliver child **销毁重建**——段内领域态
  /// （表单输入/错误态/探活结果）随之丢失（拆分前这些态在页面层，天然跨滚动
  /// 存活）。故段一律申请 keepAlive：拆段不得改变「滚动后回到面板仍是原样」
  /// 的用户可见语义。
  @override
  bool get wantKeepAlive => true;


  ServerEndpointStore? _epStore;
  var _endpoints = const <ServerEndpoint>[];
  final _probeStates = <String, NodeProbeResult?>{}; // id → null = 探测中
  var _probing = false;
  // —— 节点卡增删改（P1 设置拆分：服务全生命周期收敛本面板）——
  final _epKeys = <String, String?>{}; // id → 已存令牌（编辑表单预填）
  var _addingEp = false;
  String? _editingEpId;
  String? _nodesError;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  /// 段自持初始化：先读端点目录（[_initNodes]），再按 [NodesSection.autoProbe]
  /// 自动探活一次（P2：「未探测 · 已存令牌」不再让用户先找按钮）。
  Future<void> _bootstrap() async {
    await _initNodes();
    if (widget.autoProbe && mounted) {
      await _probeAll();
    }
  }

  /// 节点卡面板初始化（P0-3 同口径）：失败置面板级错误态（与聊天页 ⚙ 设置
  /// 同一 ServerEndpointStore 文件——应用支持目录/mcp_servers.json + 旧单端点
  /// SharedPreferences 迁移同口径）。重试入口 = 本方法（不含自动探活）。
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
    widget.onFlash('✓ 已添加服务 $id');
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
    widget.onFlash('✓ 已更新服务 ${ep.name}');
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
    widget.onFlash('✓ 已删除服务 ${ep.name}');
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
    widget.onFlash(
      value ? '✓ 已挂载 ${ep.name}' : '⊘ 已卸载 ${ep.name}（配置与令牌保留）',
    );
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
              '图钉 = 钉选为默认私有服务（新会话跟随默认绑定，无钉选则公共'
              '起步；聊天页弹层可即时改本次会话）。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_nodesError != null)
              widget.errorRowBuilder(
                t,
                _nodesError!,
                () => unawaited(_initNodes()),
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
    final eligible = ep.enabled && ep.tier == ServerPrivacyTier.private;
    // 令牌存况以安全存储实际读出为准（JSON hasKey 只是落盘标记）：升级后旧
    // 密文不可解时读出空，此处即「需重新录入」的判定源（2026-10-24 事故口径）。
    final tokenStored = _epKeys[ep.id]?.isNotEmpty ?? false;
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
                        if (eligible && widget.isDefaultPrivate(ep.id)) ...[
                          const SizedBox(width: 6),
                          _defaultPill(t),
                        ],
                      ],
                    ),
                    Text(
                      '${ep.endpoint}\n'
                      '端口 ${_portLabel(ep.endpoint)} · ${_metricsLabel(probe)} · '
                      '${_authLabel(ep, probe, tokenStored)}',
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
                eligible: eligible,
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

  /// 鉴权态（F1.17）：已授权 / 令牌需重新录入 / 待授权 403（Rose）/ 离线；
  /// 配合 hasKey 展示令牌存况（密钥纪律：永不回显真值）。
  ///
  /// [tokenStored] = 安全存储实际读出非空令牌。JSON `hasKey` 只证明「落盘过」，
  /// 读出为空即令牌已不可用（flutter_secure_storage 9→11 直升丢密钥事故口径，
  /// 2026-10-24）——此时「⚠ 令牌需重新录入」优先于探活结论（403 大概率即其
  /// 果，修因优先报因）。
  String _authLabel(ServerEndpoint ep, NodeProbeResult? probe, bool tokenStored) {
    if (probe != null && probe.online) return '已授权';
    if (ep.hasKey && !tokenStored) return '⚠ 令牌需重新录入';
    if (probe != null && probe.authDenied) return '⚠ 待授权(403)';
    if (probe != null) return '离线';
    return ep.hasKey ? '未探测 · 已存令牌' : '未探测 · 无令牌';
  }

  // —— 默认私有服务钉选（方案 A：统一钉选降级为卡片行内态，2026-10-16）——
  // owner 在页面（与本地插件段共用同一默认键），本段只做行内渲染 + 回调透传。

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
  /// 远端节点须 `enabled && tier == private`（本地插件段 = `serverId` 非空）。
  Widget _defaultPinButton({
    required Key pinKey,
    required String id,
    required String label,
    required bool eligible,
  }) {
    if (!eligible) return const SizedBox.shrink();
    final t = consoleTokens(context);
    final isDefault = widget.isDefaultPrivate(id);
    return IconButton(
      key: pinKey,
      tooltip: isDefault ? '取消默认私有服务' : '设为默认私有服务',
      iconSize: 18,
      onPressed: () => widget.onPinToggle(id, label, isDefault),
      icon: Icon(
        isDefault ? Icons.push_pin : Icons.push_pin_outlined,
        color: isDefault ? t.l1Ok : null,
      ),
    );
  }
}
