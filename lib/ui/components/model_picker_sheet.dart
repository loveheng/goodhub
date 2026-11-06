/// 对话内模型选择 sheet（纯视图件，2026-11-06 用户需求：端侧/云端模型在对话
/// 界面需要选择入口）：路由来源（自动 / 优先端侧）+ 云端引擎单选 + 端侧模型
/// 单选。数据与写入回调全部由 chat_page 传入——本件零 store 依赖（composer
/// 头部口径：传数据与回调，不依赖页面私有态）。
///
/// 形态归 ui-design §3 既有「底部选择 sheet」模式（showResourcePickerSheet
/// 同款：barrier 底板 + 分组单选行）；切换即生效——路由每次 send 实时读
/// 持久化值（hybrid_cloud_engine），无需额外「保存」步。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/console_tokens.dart';

/// 选择数据快照（chat_page 装配期拉取；null 字段 = 该面暂不可用/加载中）。
class ModelPickerData {
  const ModelPickerData({
    required this.preferOnDevice,
    required this.deviceModels,
    required this.selectedDeviceDir,
    required this.cloudEngines,
    required this.preferredCloudId,
  });

  /// 路由来源：true = 优先端侧（云端可用也走端侧）；false = 自动（云端优先）。
  final bool preferOnDevice;

  /// 已装端侧模型（dirName 唯一键）。空 = 未导入任何端侧模型。
  final List<({String dirName, String displayName})> deviceModels;
  final String? selectedDeviceDir;

  /// 云端引擎（BYOK profile，id 唯一键）。空 = 未配置任何云端引擎。
  final List<({String id, String name, String model})> cloudEngines;
  final String? preferredCloudId;
}

/// 弹出模型选择 sheet。选中即回调（不等待「完成」按钮）；返回前 sheet 自关。
Future<void> showModelPickerSheet(
  BuildContext context, {
  required ModelPickerData data,
  required ValueChanged<bool> onSourceChanged,
  required ValueChanged<String> onDeviceModelSelected,
  required ValueChanged<String> onCloudEngineSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => _ModelPickerBody(
      data: data,
      onSourceChanged: onSourceChanged,
      onDeviceModelSelected: onDeviceModelSelected,
      onCloudEngineSelected: onCloudEngineSelected,
    ),
  );
}

class _ModelPickerBody extends StatelessWidget {
  const _ModelPickerBody({
    required this.data,
    required this.onSourceChanged,
    required this.onDeviceModelSelected,
    required this.onCloudEngineSelected,
  });

  final ModelPickerData data;
  final ValueChanged<bool> onSourceChanged;
  final ValueChanged<String> onDeviceModelSelected;
  final ValueChanged<String> onCloudEngineSelected;

  void _pop(BuildContext ctx) => Navigator.of(ctx).pop();

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('模型与推理来源',
                style: TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                    color: t.l2Accent)),
            const SizedBox(height: 12),

            // —— 路由来源（自动 / 优先端侧）——
            _GroupHeader(t: t, label: '推理来源'),
            _OptionRow(
              t: t,
              title: '自动（云端优先）',
              subtitle: '按路由规则分配；云端不可用/冷却时自动转端侧',
              selected: !data.preferOnDevice,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                // 先关面板再回调（顺序铁律）：回调可能同步 showDialog——
                // 若后 pop，Navigator.pop 会把刚入栈的确认卡顶掉
                //（真机实测：确认卡闪现即消失，表现为「点了没反应」）。
                _pop(context);
                onSourceChanged(false);
              },
            ),
            _OptionRow(
              t: t,
              title: '优先端侧',
              subtitle: '云端可用也走端侧（本机推理，出不了网也能用）',
              selected: data.preferOnDevice,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                _pop(context);
                onSourceChanged(true);
              },
            ),

            // —— 云端引擎（BYOK 生效位）——
            _GroupHeader(t: t, label: '云端引擎'),
            if (data.cloudEngines.isEmpty)
              _EmptyHint(t: t, text: '尚未配置云端引擎——可在资源中心 → 云端引擎添加')
            else
              for (final e in data.cloudEngines)
                _OptionRow(
                  t: t,
                  title: e.name,
                  subtitle: e.model,
                  selected: e.id == data.preferredCloudId,
                  onTap: () {
                    unawaited(HapticFeedback.selectionClick());
                    _pop(context); // 先关面板（顺序铁律，见上）
                    onCloudEngineSelected(e.id);
                  },
                ),

            // —— 端侧模型（已装列表单选）——
            _GroupHeader(t: t, label: '端侧模型'),
            if (data.deviceModels.isEmpty)
              _EmptyHint(t: t, text: '尚未导入端侧模型——可在资源中心 → 端侧模型导入')
            else
              for (final m in data.deviceModels)
                _OptionRow(
                  t: t,
                  title: m.displayName,
                  selected: m.dirName == data.selectedDeviceDir,
                  onTap: () {
                    unawaited(HapticFeedback.selectionClick());
                    _pop(context); // 先关面板（顺序铁律）：确认卡随后弹出
                    onDeviceModelSelected(m.dirName);
                  },
                ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.t, required this.label});

  final ConsoleTokens t;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: Fsz.telemetry,
            color: t.terminalMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.t, required this.text});

  final ConsoleTokens t;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          style: TextStyle(fontSize: Fsz.telemetrySm, color: t.terminalMuted),
        ),
      );
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.t,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final ConsoleTokens t;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? t.l1Info : t.terminalMuted;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: Fsz.body,
                      color: selected ? t.l1Info : null,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: Fsz.telemetrySm,
                        color: t.terminalMuted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
