/// 全局主题模式（暗色 / 亮色 / 暖色）与运行时切换。
///
/// SSOT 纪律（goodhub-ui skill）：色彩/字体/圆角一律 token 化，组件只从
/// `Theme.of(context).extension<ConsoleTokens>()` 取值。本文件承载三套主题
/// 的 **装配**（ColorScheme 中性基底 + ConsoleTokens 语义色），并提供：
/// - [AppTheme] 枚举与中文标签；
/// - [readAppTheme] / [writeAppTheme] 持久化（SharedPreferences）；
/// - [buildAppTheme] 由枚举装配 `ThemeData`；
/// - [AppThemeController] 单例（ValueNotifier），设置页写入、App 根监听重建。
///
/// 暖色 = 暖中性（Stone 系）浅色变体，正文近黑、底色暖纸感；语义色沿用 §1
/// 参考值（600 档），全部 ≥ WCAG AA 4.5:1（ui-design §6 无障碍红线）。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'console_tokens.dart';

/// 三态主题模式（用户显式选择，不再跟随系统）。
enum AppTheme { dark, light, warm }

/// 中文标签（设置页分段控件文案）。
extension AppThemeLabel on AppTheme {
  String get label {
    switch (this) {
      case AppTheme.dark:
        return '暗色';
      case AppTheme.light:
        return '亮色';
      case AppTheme.warm:
        return '暖色';
    }
  }
}

/// 持久键（SharedPreferences）。
const String kAppThemeKey = 'app.theme';

/// 读当前主题（首次未设置：跟随系统亮度，保留原 ThemeMode.system 行为，避免回归）。
Future<AppTheme> readAppTheme() async {
  final sp = await SharedPreferences.getInstance();
  final v = sp.getString(kAppThemeKey);
  if (v != null) {
    for (final e in AppTheme.values) {
      if (e.name == v) return e;
    }
  }
  final brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  return brightness == Brightness.dark ? AppTheme.dark : AppTheme.light;
}

/// 写当前主题。
Future<void> writeAppTheme(AppTheme theme) async {
  final sp = await SharedPreferences.getInstance();
  await sp.setString(kAppThemeKey, theme.name);
}

/// 全局主题控制器（单例）：设置页经 [set] 写入并持久化，App 根经
/// [AnimatedBuilder]/[ValueListenableBuilder] 监听重建。
class AppThemeController extends ValueNotifier<AppTheme> {
  AppThemeController(super.value);

  /// 单例（main 启动期于 runApp 前以持久值覆盖；非 late 默认 = 亮色，免测试/
  /// 子组件在 App 根未装配时访问 LateInitializationError）。
  static AppThemeController instance = AppThemeController(AppTheme.light);

  /// 切换主题：值相同则跳过（免空写 + 免无谓重建），否则更新并持久化。
  Future<void> set(AppTheme next) async {
    if (value == next) return;
    value = next;
    await writeAppTheme(next);
  }
}

/// 由 [AppTheme] 装配 `ThemeData`：中性基底（surface 家族）+ ConsoleTokens
/// 语义色。暖色为暖中性浅色变体，亮/暖均属 light brightness（Material 仅
/// 借 brightness 决定默认组件明暗，底色由 surface 系列显式钉死）。
ThemeData buildAppTheme(AppTheme appTheme) {
  final dark = appTheme == AppTheme.dark;
  final warm = appTheme == AppTheme.warm;
  final brightness = dark ? Brightness.dark : Brightness.light;

  // 中性种子：暗/亮 = Zinc 500；暖 = Stone 500（交互色由种子派生近灰阶，
  // 杜绝「两个 indigo」，见 main.dart C2 注释）。
  final seed = dark
      ? const Color(0xFF71717A)
      : warm
          ? const Color(0xFF78716C)
          : const Color(0xFF71717A);

  final tokens = dark
      ? ConsoleTokens.dark
      : warm
          ? ConsoleTokens.warm
          : ConsoleTokens.light;

  final seeded = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

  // surface 家族贴 ui-design §1 底色表（浅 Slate 50/100；暖 = Stone 暖纸；
  // 深 Zinc 900/950）。暖色卡用纯白保清晰，阅读轨底用暖纸。
  final surface = dark
      ? const Color(0xFF09090B)
      : warm
          ? const Color(0xFFFBF7F1)
          : const Color(0xFFF8FAFC);
  final surfaceLowest = dark ? const Color(0xFF09090B) : Colors.white;
  final surfaceLow = dark
      ? const Color(0xFF18181B)
      : warm
          ? const Color(0xFFF5EFE6)
          : const Color(0xFFF1F5F9);
  final surfaceHigh = dark
      ? const Color(0xFF27272A)
      : warm
          ? const Color(0xFFEAE2D5)
          : const Color(0xFFE2E8F0);
  final onSurface = dark
      ? const Color(0xFFFAFAFA)
      : warm
          ? const Color(0xFF1C1917)
          : const Color(0xFF0F172A);
  final onSurfaceVariant = dark
      ? const Color(0xFFA1A1AA)
      : warm
          ? const Color(0xFF57534E)
          : const Color(0xFF334155); // 亮色 Slate 700：对比度 9.5:1，看清次级文字
  final outline = dark
      ? const Color(0xFF3F3F46)
      : warm
          ? const Color(0xFFD6CCBC)
          : const Color(0xFFCBD5E1);
  final outlineVariant = dark
      ? const Color(0xFF27272A)
      : warm
          ? const Color(0xFFEAE2D5)
          : const Color(0xFFE2E8F0);

  final scheme = seeded.copyWith(
    surface: surface,
    surfaceContainerLowest: surfaceLowest,
    surfaceContainerLow: surfaceLow,
    surfaceContainer: surfaceLow,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: surfaceHigh,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceVariant,
    outline: outline,
    outlineVariant: outlineVariant,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [tokens],
  );
}
