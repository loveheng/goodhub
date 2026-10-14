/// 控制台风格 design tokens（ui-design.md §1/§2/§4 的 Flutter 落地）。
///
/// SSOT 纪律（goodhub-ui skill）：色彩/字体/圆角/边框/动效时长一律 token 化，
/// 组件内禁止散落魔法值——组件只从 `Theme.of(context).extension<ConsoleTokens>()`
/// 取值，未注入时用 [ConsoleTokens.fallback] 兜底。
library;

import 'package:flutter/material.dart';

class ConsoleTokens extends ThemeExtension<ConsoleTokens> {
  const ConsoleTokens({
    required this.l1Ok,
    required this.l1Info,
    required this.l2Warn,
    required this.l2Accent,
    required this.danger,
    required this.dangerDeep,
    required this.terminalMuted,
    required this.hairline,
    required this.codeBg,
    required this.dataRef,
    required this.monoFamily,
    required this.cardRadius,
    required this.fastDuration,
  });

  /// L1 只读执行/成功（Emerald 400，ui-design §1）
  final Color l1Ok;

  /// L1 就绪/轻提示（Cyan 500）
  final Color l1Info;

  /// L2 写操作待确认（Amber 500）
  final Color l2Warn;

  /// L2 联合授权备用（Orange 400，M2.5 `$ref` 卡用）
  final Color l2Accent;

  /// 熔断/中止（Rose 500）
  final Color danger;

  /// 强中止/ABORT（Crimson）
  final Color dangerDeep;

  /// 终态锁定灰阶（ui-design §3.2「灰阶弱化态」）
  final Color terminalMuted;

  /// 1px 细边框基色（预乘 12% 不透明度，§4.3 禁弥散投影）
  final Color hairline;

  /// 代码块/行内代码微深底（§2「代码块背景微深」；M4-T3 阅读轨新增）
  final Color codeBg;

  /// 数据指针与资源（Indigo 400，§1——`$ref` 句柄、链接、媒体降级行）
  final Color dataRef;

  /// 等宽字体族（遥测/参数强制等宽，§2；M3 换 JetBrains Mono 资产）
  final String monoFamily;

  /// 卡片微圆角（§3.2 8~12px）
  final double cardRadius;

  /// 紧凑动效时长（§4.2 150~200ms，禁 Spring）
  final Duration fastDuration;

  /// 深色套（Zinc 900/950 底；fallback 同源——语义色沿用 §1 参考值，hairline
  /// 换白基 12%——黑基 12% 在深底上不可见，属 fallback 历史遗留）。
  static const dark = ConsoleTokens(
    l1Ok: Color(0xFF34D399),
    l1Info: Color(0xFF06B6D4),
    l2Warn: Color(0xFFF59E0B),
    l2Accent: Color(0xFFFB923C),
    danger: Color(0xFFF43F5E),
    dangerDeep: Color(0xFFDC143C),
    terminalMuted: Color(0xFF9E9E9E),
    hairline: Color(0x1FFFFFFF),
    codeBg: Color(0x14FFFFFF),
    dataRef: Color(0xFF818CF8),
    monoFamily: 'monospace',
    cardRadius: 10,
    fastDuration: Duration(milliseconds: 180),
  );

  /// 浅色套（Slate 50/100 底；语义色整体降一档提对比——Emerald/Cyan/Amber/
  /// Orange/Rose 600，Indigo 500；terminalMuted = Slate 500）。
  static const light = ConsoleTokens(
    l1Ok: Color(0xFF059669),
    l1Info: Color(0xFF0891B2),
    l2Warn: Color(0xFFD97706),
    l2Accent: Color(0xFFEA580C),
    danger: Color(0xFFE11D48),
    dangerDeep: Color(0xFF9F1239),
    terminalMuted: Color(0xFF64748B),
    hairline: Color(0x1F000000),
    codeBg: Color(0x141E293B),
    dataRef: Color(0xFF6366F1),
    monoFamily: 'monospace',
    cardRadius: 10,
    fastDuration: Duration(milliseconds: 180),
  );

  static const fallback = ConsoleTokens(
    l1Ok: Color(0xFF34D399),
    l1Info: Color(0xFF06B6D4),
    l2Warn: Color(0xFFF59E0B),
    l2Accent: Color(0xFFFB923C),
    danger: Color(0xFFF43F5E),
    dangerDeep: Color(0xFFDC143C),
    terminalMuted: Color(0xFF9E9E9E),
    hairline: Color(0x1F000000),
    codeBg: Color(0x1427272B),
    dataRef: Color(0xFF818CF8),
    monoFamily: 'monospace',
    cardRadius: 10,
    fastDuration: Duration(milliseconds: 180),
  );

  @override
  ConsoleTokens copyWith({
    Color? l1Ok,
    Color? l1Info,
    Color? l2Warn,
    Color? l2Accent,
    Color? danger,
    Color? dangerDeep,
    Color? terminalMuted,
    Color? hairline,
    Color? codeBg,
    Color? dataRef,
    String? monoFamily,
    double? cardRadius,
    Duration? fastDuration,
  }) {
    return ConsoleTokens(
      l1Ok: l1Ok ?? this.l1Ok,
      l1Info: l1Info ?? this.l1Info,
      l2Warn: l2Warn ?? this.l2Warn,
      l2Accent: l2Accent ?? this.l2Accent,
      danger: danger ?? this.danger,
      dangerDeep: dangerDeep ?? this.dangerDeep,
      terminalMuted: terminalMuted ?? this.terminalMuted,
      hairline: hairline ?? this.hairline,
      codeBg: codeBg ?? this.codeBg,
      dataRef: dataRef ?? this.dataRef,
      monoFamily: monoFamily ?? this.monoFamily,
      cardRadius: cardRadius ?? this.cardRadius,
      fastDuration: fastDuration ?? this.fastDuration,
    );
  }

  @override
  ConsoleTokens lerp(ConsoleTokens? other, double t) {
    if (other == null) return this;
    return ConsoleTokens(
      l1Ok: Color.lerp(l1Ok, other.l1Ok, t)!,
      l1Info: Color.lerp(l1Info, other.l1Info, t)!,
      l2Warn: Color.lerp(l2Warn, other.l2Warn, t)!,
      l2Accent: Color.lerp(l2Accent, other.l2Accent, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerDeep: Color.lerp(dangerDeep, other.dangerDeep, t)!,
      terminalMuted: Color.lerp(terminalMuted, other.terminalMuted, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      dataRef: Color.lerp(dataRef, other.dataRef, t)!,
      monoFamily: t < 0.5 ? monoFamily : other.monoFamily,
      cardRadius: cardRadius + (other.cardRadius - cardRadius) * t,
      fastDuration: t < 0.5 ? fastDuration : other.fastDuration,
    );
  }
}

/// 组件取 token 的统一入口（主题未注入时落 [ConsoleTokens.fallback]）。
ConsoleTokens consoleTokens(BuildContext context) =>
    Theme.of(context).extension<ConsoleTokens>() ?? ConsoleTokens.fallback;

/// 排版字号表（ui-design §2 双轨排印的字号 token；static const——可在
/// `const TextStyle` 内直接引用，全仓 fontSize 字面量经此收敛）。
///
/// 阅读轨 = reading/listPrimary/body/mediaLabel；操作/遥测轨 = note/
/// telemetry/telemetrySm/micro/microSm；面板层级 = sectionTitle/panelTitle。
abstract final class Fsz {
  /// 阅读轨正文（聊天流段落/列表项，行高 1.55）。
  static const reading = 14.5;

  /// 列表主文（比 reading 略收）。
  static const listPrimary = 14.0;

  /// 紧凑正文/表单输入（13）。
  static const body = 13.0;

  /// 媒体降级行链接文本（13.5）。
  static const mediaLabel = 13.5;

  /// 通告/辅助正文（12.5）。
  static const note = 12.5;

  /// 遥测轨主字号（工具名/端口/参数/日志，12）。
  static const telemetry = 12.0;

  /// 小遥测（11.5——错误摘要/概要标题）。
  static const telemetrySm = 11.5;

  /// 微遥测（11——时间戳/元数据/指纹）。
  static const micro = 11.0;

  /// 极微标注（10.5——生效中标签/已卸载角标）。
  static const microSm = 10.5;

  /// 面板区块标题（15）。
  static const sectionTitle = 15.0;

  /// 顶层面板/弹层标题（16）。
  static const panelTitle = 16.0;
}
