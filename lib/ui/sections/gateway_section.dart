/// 设置页 · PC 远程网关段（window-slim P1-A 分段拆解，2026-10-17 自
/// settings_page 迁出）：:8766 起停编排 + 配对 Token 读写 + 局域网暴露风险
/// 文案全部自持——settings_page 只透传 flash 回调。
///
/// 迁移语义原样保留（含测试锚点 Key）：
/// - 网关是全局单例，段 dispose **不停服**（起停是用户显式动作，页面进出不带
///   副作用）；
/// - Token 在起服时落盘——改 Token 须关再开才生效（闸门校验发生在 start 时读
///   入的那份）；
/// - 起服含端口绑定（非瞬时），期间禁重复触发。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/security/flutter_secure_key_value.dart';
import '../../core/security/secure_key_value.dart';
import '../../gateway_api/gateway_control.dart';
import '../tokens/console_tokens.dart';

/// 网关起服注入位（测试替换 → 不真绑端口）。
typedef GatewayStartFn = Future<void> Function({required int port, String? token});

/// 网关停服注入位（测试替换）。
typedef GatewayStopFn = Future<void> Function();

/// 电池优化白名单查询注入位（测试替换）。
typedef BatteryStatusFn = Future<bool> Function();

/// 电池优化白名单申请注入位（测试替换）。
typedef BatteryRequestFn = Future<bool> Function();

/// 配对 Token 存储键。F11（review-fix-2026-10）：值迁移至 **SecureKeyValue**
/// （Bearer Token 属凭证，明文落 SharedPreferences 违反 §6.3 零明文留痕——
/// 本地取证/备份提取即得，可从局域网任一主机冒充已配对 PC）；键名沿用，
/// 首启自动从旧 prefs 键迁移并删除明文残留。
const String _kTokenKey = 'gateway.token';

/// prefs 键：Token 鉴权模式（'auto' = 留空则自动生成 / 'open' = 用户显式免鉴权）。
const String _kTokenAuthModeKey = 'gateway.token.authMode';
const String _kTokenAuthModeAuto = 'auto';
const String _kTokenAuthModeOpen = 'open';

/// 段 widget：注入 [onFlash]（页面级 toast 口径）。
class GatewaySection extends StatefulWidget {
  const GatewaySection({
    super.key,
    required this.onFlash,
    this.startOverride,
    this.stopOverride,
    this.batteryStatusOverride,
    this.batteryRequestOverride,
    this.secureOverride,
  });

  final void Function(String message) onFlash;

  /// 起服注入位（测试可替换——避免 widget 测试真绑 :8766 端口）。
  final GatewayStartFn? startOverride;

  /// 停服注入位（测试可替换）。
  final GatewayStopFn? stopOverride;

  /// 电池优化白名单状态查询注入位（测试可替换）。
  final BatteryStatusFn? batteryStatusOverride;

  /// 电池优化白名单申请注入位（测试可替换）。
  final BatteryRequestFn? batteryRequestOverride;

  /// 测试注入位（F11）；null = 生产路径（[FlutterSecureKeyValue]）。
  final SecureKeyValue? secureOverride;

  @override
  State<GatewaySection> createState() => _GatewaySectionState();
}

class _GatewaySectionState extends State<GatewaySection>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  /// ListView 懒构建会把滚出视口的 sliver child **销毁重建**——段内领域态
  /// （表单输入/错误态/探活结果）随之丢失（拆分前这些态在页面层，天然跨滚动
  /// 存活）。故段一律申请 keepAlive：拆段不得改变「滚动后回到面板仍是原样」
  /// 的用户可见语义。
  @override
  bool get wantKeepAlive => true;


  var _gwRunning = false;
  var _gwLanAddrs = const <String>[]; // 运行中展示 PC 可配 URL
  final _gwTokenCtrl = TextEditingController();
  var _gwBusy = false; // 起停中：禁重复触发（起服含端口绑定，非瞬时）

  /// 自动生成配对 Token（默认开）——消除「默认无鉴权」危险默认值：原实现
  /// 「Token 留空 = 不鉴权」且默认监听 0.0.0.0:8766 → 同局域网任意主机可
  /// 无鉴权访问只读工具面。关闭本开关且输入框留空 = 用户**显式**选择免鉴权
  ///（逃生口保留给「仅 ADB 转发」场景）。
  bool _autoToken = true;

  /// Token 明文可见（用户需核对 PC 端填入的串 + 复制给 PC）。
  bool _tokenVisible = false;

  /// 电池优化白名单状态（true = 已加入 / false = 未加入 / null = 未知未查）。
  ///
  /// 未加白名单时息屏进 Doze 会限网 → PC 侧表现为「过段时间连接掉了」
  /// （G4 遗留项，2026-10-23 收口）。
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gwTokenCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统白名单弹窗返回 → 复查状态（弹窗里点「允许」当场不会回传）。
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshBatteryExemption());
    }
  }

  /// 段自持初始化（不再由页面编排）：只读当前起停态与持久化 Token。
  Future<void> _bootstrap() async {
    try {
      final secure = widget.secureOverride ?? FlutterSecureKeyValue();
      // F11：Token 读安全存储；首启从旧明文 prefs 键迁移（读→写安全位→删明文）。
      var token = await secure.read(_kTokenKey);
      final prefs = await SharedPreferences.getInstance();
      if (token == null || token.isEmpty) {
        final legacy = prefs.getString(_kTokenKey);
        if (legacy != null && legacy.isNotEmpty) {
          await secure.write(_kTokenKey, legacy);
          await prefs.remove(_kTokenKey);
          token = legacy;
        }
      }
      if (!mounted) return;
      _gwTokenCtrl.text = token ?? '';
      // 「自动生成」模式随 Token 一起落盘：用户显式关过 → 免鉴权意图保留
      // （否则每次开启都被自动补 Token，用户的显式选择被静默推翻）。模式标记
      // 非机密，仍在 prefs。
      _autoToken = prefs.getString(_kTokenAuthModeKey) != _kTokenAuthModeOpen;
      await _reloadGateway();
      await _refreshBatteryExemption();
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway-panel: 状态读取失败按未运行: $e');
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

  /// 重新生成配对 Token（落盘 + 回填 + 立即可见）。
  ///
  /// **需重启网关生效**——闸门在 start 时读入那份 token，与既有「改 Token
  /// 须关再开」口径一致（故提示文案明确告知）。
  Future<void> _regenerateToken() async {
    final token = generateGatewayToken();
    if (mounted) {
      setState(() {
        _gwTokenCtrl.text = token;
        _tokenVisible = true;
      });
    }
    try {
      // F11：Token 值走安全存储；authMode 标记留 prefs。
      await (widget.secureOverride ?? FlutterSecureKeyValue())
          .write(_kTokenKey, token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTokenAuthModeKey, _kTokenAuthModeAuto);
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway-panel: token 落盘失败: $e');
    }
    widget.onFlash('已生成新配对 Token——复制给 PC 端；重启网关（关→开）后生效');
  }

  /// 复查电池优化白名单状态（进入页 + 从系统弹窗返回时）。
  Future<void> _refreshBatteryExemption() async {
    try {
      final exempt =
          await (widget.batteryStatusOverride ?? gatewayBatteryExemptionStatus)();
      if (!mounted) return;
      setState(() => _batteryExempt = exempt);
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway-panel: 电池白名单状态查询失败: $e');
    }
  }

  /// 跳系统申请电池优化白名单（息屏保活的关键一步——Doze 限网会让 PC 侧
  /// 表现为「过段时间连接掉了」）。
  Future<void> _requestBatteryExemption() async {
    final ok = await (widget.batteryRequestOverride ??
        requestGatewayBatteryExemption)();
    if (!mounted) return;
    if (ok) {
      setState(() => _batteryExempt = true);
      widget.onFlash('✓ 已加入电池优化白名单（息屏不再被限网）');
    } else {
      widget.onFlash('已跳系统设置——请在弹窗中点「允许」后返回');
    }
  }

  /// 复制当前 Token（PC 端配对要用 `Authorization: Bearer <token>` 的值）。
  void _copyToken() {
    final token = _gwTokenCtrl.text.trim();
    if (token.isEmpty) {
      widget.onFlash('当前无 Token——先「重新生成」或手动填写');
      return;
    }
    Clipboard.setData(ClipboardData(text: token));
    widget.onFlash('✓ 已复制配对 Token（PC 端填入 Authorization: Bearer）');
  }

  /// 起停 PC 远程网关（:8766）。Token 在起服时落盘——改 Token 须关再开才生效
  /// （闸门校验发生在 start 时读入的那份）。
  Future<void> _toggleGateway(bool value) async {
    setState(() => _gwBusy = true);
    try {
      if (value) {
        // Token 决策（纯函数，见 gateway_api/gateway_token.dart）：输入框有值
        // → 用用户值；为空且「自动生成」开 → 生成新 Token（默认安全：起服
        // 必带 Bearer）；为空且「自动生成」关 → 免鉴权（用户显式选择）。
        final token = resolveGatewayToken(
          input: _gwTokenCtrl.text,
          autoGenerate: _autoToken,
        );
        if (token != _gwTokenCtrl.text.trim() && mounted) {
          setState(() {
            _gwTokenCtrl.text = token;
            // 自动生成的 Token 立即可见——用户要复制到 PC 端。
            _tokenVisible = true;
          });
        }
        // F11：Token 值走安全存储；authMode 标记留 prefs。
        await (widget.secureOverride ?? FlutterSecureKeyValue())
            .write(_kTokenKey, token);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _kTokenAuthModeKey,
          _autoToken ? _kTokenAuthModeAuto : _kTokenAuthModeOpen,
        );
        await (widget.startOverride ?? startGateway)(
            port: kGatewayDefaultPort, token: token.isEmpty ? null : token);
      } else {
        await (widget.stopOverride ?? stopGateway)();
      }
    } on Object catch (e) {
      if (mounted) widget.onFlash('⚠ 网关${value ? '起服' : '停服'}失败: $e');
    }
    await _reloadGateway();
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
              title: Text('暴露 :$kGatewayDefaultPort（Streamable HTTP）'),
              subtitle: Text(
                _gwRunning
                    ? '运行中——PC 配置：'
                          '${_gwLanAddrs.isEmpty ? 'http://<手机IP>' : _gwLanAddrs.map((a) => 'http://$a').join(' 或 ')}'
                          ':$kGatewayDefaultPort/mcp（ADB 场景 127.0.0.1:$kGatewayDefaultPort）'
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
              obscureText: !_tokenVisible,
              decoration: InputDecoration(
                labelText: '配对 Token（PC 端填入，请求头 Authorization: Bearer）',
                isDense: true,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const Key('gateway-token-visibility'),
                      icon: Icon(_tokenVisible
                          ? Icons.visibility_off
                          : Icons.visibility),
                      tooltip: _tokenVisible ? '隐藏' : '显示',
                      onPressed: () =>
                          setState(() => _tokenVisible = !_tokenVisible),
                    ),
                    IconButton(
                      key: const Key('gateway-token-copy'),
                      icon: const Icon(Icons.copy),
                      tooltip: '复制',
                      onPressed: _copyToken,
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('gateway-token-auto'),
                  value: _autoToken,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => setState(() => _autoToken = v ?? true),
                ),
                Expanded(
                  child: Text(
                    '自动生成配对 Token（默认开；关闭且留空 = 免鉴权，仅建议 ADB 转发）',
                    style: TextStyle(fontSize: Fsz.telemetrySm),
                  ),
                ),
                TextButton(
                  key: const Key('gateway-token-regen'),
                  onPressed: _regenerateToken,
                  child: const Text('重新生成'),
                ),
              ],
            ),
            if (_batteryExempt != true) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '⚡ 息屏保活：尚未加入电池优化白名单——息屏后系统可能限网，'
                      'PC 侧会表现为「过段时间连接掉了」',
                      style:
                          TextStyle(fontSize: Fsz.telemetrySm, color: t.danger),
                    ),
                  ),
                  TextButton(
                    key: const Key('gateway-battery-exempt'),
                    onPressed: _requestBatteryExemption,
                    child: const Text('去设置'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '⚠ 开启后同一局域网的 PC 可经 :$kGatewayDefaultPort 调用本机全部服务。默认自动生成'
              '配对 Token（PC 端须填入）；仅用 ADB 转发时可关闭「自动生成」免鉴权。'
              '改 Token 需关闭后再开启才生效。',
              style: TextStyle(fontSize: Fsz.telemetrySm, color: t.danger),
            ),
          ],
        ),
      ),
    );
  }
}
