/// 钉选状态机测试壳（节点卡 / 本地插件卡共用）：镜像资源中心页面 pin 回调
/// （读写 SharedPreferences 的 `default.private.server`，状态回填驱动 pill 渲染）——
/// 「默认私有钉选」用例与真实页面同语义。
///
/// 2026-11-02 能力中心拍板：节点/插件管理面自设置页迁入资源中心「节点与插件」tab，
/// 两段回归网直泵 section；pin 回调签名 = [isDefaultPrivate] 为
/// `bool Function(String id)`（非 bool），本壳据此提供函数而非布尔。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:goodhub/coordinator/tool_catalog.dart';
import 'package:goodhub/mcp/default_private_server.dart';

/// 假目录（测试桩）：不触真实挂载原语，工具列表恒返回空。节点/插件卡内嵌的
/// `ServerToolsList` 仅展示工具，返回空不影响面板既有断言（loading 立即转空态）。
class FakeCatalog extends McpCatalog {
  FakeCatalog()
      : super(endpointStore: ({String? supportPath}) async {
          throw UnsupportedError('fake catalog: 不走端点装配');
        });

  @override
  Future<List<McpCatalogTool>> loadServerTools(McpCatalogService s) async =>
      const [];
}

/// 提供 [isDefaultPrivate]（函数）与 [onPinToggle] 的测试壳，状态落真实持久层。
class PinHarness extends StatefulWidget {
  const PinHarness({super.key, required this.builder});

  final Widget Function(
    bool Function(String) isDefaultPrivate,
    Future<void> Function(String id, String label, bool isDefault) onPinToggle,
  ) builder;

  @override
  State<PinHarness> createState() => _PinHarnessState();
}

class _PinHarnessState extends State<PinHarness> {
  var _defaultPrivateId = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final def = await readDefaultPrivateServerId();
      if (mounted) setState(() => _defaultPrivateId = def ?? '');
    } on Object catch (_) {
      // 测试环境读键失败按无默认（与资源中心页面 _loadDefaultPrivate 同口径）。
    }
  }

  bool _isDefaultPrivate(String id) => id.isNotEmpty && _defaultPrivateId == id;

  Future<void> _onPinToggle(String id, String label, bool isDefault) async {
    await writeDefaultPrivateServerId(isDefault ? null : id);
    final def = await readDefaultPrivateServerId();
    if (mounted) setState(() => _defaultPrivateId = def ?? '');
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_isDefaultPrivate, _onPinToggle);
}
