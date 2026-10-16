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
import 'package:shared_preferences/shared_preferences.dart';

import '../../gateway_api/gateway_control.dart';
import '../tokens/console_tokens.dart';

/// 段 widget：注入 [onFlash]（页面级 toast 口径）。
class GatewaySection extends StatefulWidget {
  const GatewaySection({
    super.key,
    required this.onFlash,
  });

  final void Function(String message) onFlash;

  @override
  State<GatewaySection> createState() => _GatewaySectionState();
}

class _GatewaySectionState extends State<GatewaySection>
    with AutomaticKeepAliveClientMixin {
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

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _gwTokenCtrl.dispose();
    super.dispose();
  }

  /// 段自持初始化（不再由页面编排）：只读当前起停态与持久化 Token。
  Future<void> _bootstrap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _gwTokenCtrl.text = prefs.getString('gateway.token') ?? '';
      await _reloadGateway();
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
}
