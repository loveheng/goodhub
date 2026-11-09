/// 设置页 · AI 能力输出段（ai-capability-export M-D · 用户主权面，设计稿 §4 #5）。
///
/// 设备主对「对外 AI 能力输出」的两项主权控制：
/// - **路由裁决（D1）**：外部 `ai/complete` 受理走端侧还是云端（BYOK 成本归
///   设备主，调用方不得强制）；写入 [setAiExportRouteLeg] 单源。
/// - **违规冻结治理**：连续内容违规 3 次被冻结的调用方列表 + 解冻——冻结集合
///   持久化（`kPrefAiFrozenCallers`，重启不清），唯一恢复出口 = 本面板
///   （[AppCapabilityRegistry.unfreeze]）。
///
/// 段自持视图：路由态 FutureBuilder 读 prefs（写入即重取）；冻结列表直接读
/// 持久化集合（**不**逐个走 registry 建档——「看一眼面板」不得把陌生 callerKey
/// 写进档案面），解冻经 registry 单源 API。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../coordinator/ai_complete_service.dart';
import '../tokens/console_tokens.dart';

/// 段 widget：AI 能力输出（路由 + 冻结治理）。
class AiCapabilitySection extends StatelessWidget {
  const AiCapabilitySection({super.key, this.onFlash});

  final void Function(String message)? onFlash;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI 能力输出',
              style: TextStyle(fontSize: Fsz.sectionTitle, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '外部应用借用本机 AI 算力时：推理走端侧（零成本）还是云端（消耗 BYOK 额度）；'
              '违规调用方的冻结与解冻也在此管理',
              style: TextStyle(fontSize: Fsz.note, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            // 路由裁决（D1：算力消耗与成本归属是设备主的决定）。
            FutureBuilder<AiRouteLeg>(
              future: readAiExportRouteLeg(),
              builder: (context, snap) => SegmentedButton<AiRouteLeg>(
                selected: {snap.data ?? AiRouteLeg.onDevice},
                onSelectionChanged: (selected) async {
                  final next = selected.first;
                  await setAiExportRouteLeg(next);
                  onFlash?.call(next == AiRouteLeg.cloud
                      ? '外部 AI 调用将路由云端（消耗 BYOK 额度）'
                      : '外部 AI 调用将路由端侧（零成本）');
                },
                segments: const [
                  ButtonSegment(
                    value: AiRouteLeg.onDevice,
                    label: Text('端侧'),
                    icon: Icon(Icons.phone_android_outlined),
                  ),
                  ButtonSegment(
                    value: AiRouteLeg.cloud,
                    label: Text('云端'),
                    icon: Icon(Icons.cloud_outlined),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _FrozenList(onFlash: onFlash),
          ],
        ),
      ),
    );
  }
}

/// 冻结调用方列表（无冻结零渲染痕迹；解冻 = 唯一恢复出口）。
class _FrozenList extends StatelessWidget {
  const _FrozenList({this.onFlash});

  final void Function(String message)? onFlash;

  Future<List<String>> _loadFrozen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(kPrefAiFrozenCallers) ?? const <String>[];
    } on Object {
      return const <String>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      // key 绑定刷新：解冻后 FutureBuilder 需重取——由 setState 驱动本段重建。
      future: _loadFrozen(),
      builder: (context, snap) {
        final frozen = snap.data ?? const <String>[];
        if (frozen.isEmpty) {
          return Text(
            '当前没有被冻结的调用方',
            style: TextStyle(
                fontSize: Fsz.note, color: Theme.of(context).colorScheme.onSurfaceVariant),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已冻结 ${frozen.length} 个调用方（连续内容违规 3 次）',
              style: const TextStyle(fontSize: Fsz.note, fontWeight: FontWeight.w600),
            ),
            for (final caller in frozen)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block_outlined, size: 18),
                title: Text(caller, style: const TextStyle(fontSize: Fsz.note)),
                trailing: TextButton(
                  onPressed: () => _unfreeze(context, caller),
                  child: const Text('解冻'),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _unfreeze(BuildContext context, String caller) async {
    // registry 单源解冻（档案内存态 + 持久化集合同收）。
    await AppCapabilityRegistry.instance.unfreeze(caller);
    // 触发 FutureBuilder 重取：整段经 Element 重建（段级轻刷新）。
    if (context.mounted) {
      (context as Element).markNeedsBuild();
      onFlash?.call('已解冻 $caller');
    }
  }
}
