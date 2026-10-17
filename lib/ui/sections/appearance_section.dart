/// 设置页 · 外观段（2026-10-17 新增）：暗色 / 亮色 / 暖色 三态主题选择。
///
/// 段自持视图，经 [AppThemeController] 单例读写并持久化；写入即时经 App 根
/// [AnimatedBuilder] 重建整树主题（无独立领域态，无需 keepAlive）。
library;

import 'package:flutter/material.dart';

import '../tokens/app_theme.dart';
import '../tokens/console_tokens.dart';

/// 段 widget：三态主题分段选择器（M3 SegmentedButton，控制台中性主色，无大
/// 圆角胶囊开关——符合 ui-design §3.3 开关质感与 §总纲③）。
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

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
              '外观',
              style: TextStyle(
                fontSize: Fsz.sectionTitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '主题模式（暗色 / 亮色 / 暖色，即时生效并记住）',
              style: TextStyle(
                fontSize: Fsz.note,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<AppTheme>(
              valueListenable: AppThemeController.instance,
              builder: (context, current, _) => SegmentedButton<AppTheme>(
                selected: {current},
                onSelectionChanged: (selected) {
                  final next = selected.first;
                  if (next != current) AppThemeController.instance.set(next);
                },
                segments: const [
                  ButtonSegment(
                    value: AppTheme.dark,
                    label: Text('暗色'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: AppTheme.light,
                    label: Text('亮色'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: AppTheme.warm,
                    label: Text('暖色'),
                    icon: Icon(Icons.wb_sunny_outlined),
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
