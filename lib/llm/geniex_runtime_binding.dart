/// GenieX 增配安装面 Dart 绑定（npu-geniex-runtime 设计稿 §7，P2）：
/// 主进程通道 `goodhub/geniex_runtime`——status / install（进度/完成经
/// 通道反投）/ uninstall；镜像列表经 SharedPreferences 持久化（D3 裁决
/// 双源为默认，可配置化覆盖）。安装面 = 主进程（文件同 uid 共享）；
/// :engine 装载面 = GenieSession 侧 GenieXRuntime.ensureLoaded（只装不下载）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 增配运行库状态快照（Kotlin statusMap 投影）。
class GenieXStatus {
  const GenieXStatus({
    required this.supported,
    required this.installed,
    required this.installing,
    required this.version,
    this.arch,
    this.sizeBytes = 0,
  });

  final bool supported;
  final bool installed;
  final bool installing;
  final String version;
  final int? arch;

  /// 运行目录实际占用字节（仅已装时有意义）。
  final int sizeBytes;

  static GenieXStatus fromMap(Object? raw) {
    final m = raw as Map<Object?, Object?>? ?? const {};
    return GenieXStatus(
      supported: m['supported'] as bool? ?? false,
      installed: m['installed'] as bool? ?? false,
      installing: m['installing'] as bool? ?? false,
      version: m['version'] as String? ?? '',
      arch: m['arch'] as int?,
      sizeBytes: m['sizeBytes'] as int? ?? 0,
    );
  }
}

/// 增配运行库控制绑定。特权能力集中于此（ui 域禁直连通道——N1）；
/// 测试经注入回调替换（见 OnDeviceModelSection.geniexOverride）。
abstract final class GenieXRuntimeControl {
  static const MethodChannel _channel = MethodChannel('goodhub/geniex_runtime');
  static const String _mirrorsKey = 'geniex.mirrors';

  /// 镜像列表：空 = 内置双源默认（Maven Central + 阿里云）。
  static Future<List<String>> loadMirrors() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_mirrorsKey) ?? '';
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.startsWith('http'))
        .toList();
  }

  static Future<void> saveMirrors(List<String> mirrors) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mirrorsKey, mirrors.join(','));
  }

  static Future<GenieXStatus> status() async {
    try {
      return GenieXStatus.fromMap(await _channel.invokeMethod<Object?>('status'));
    } on PlatformException {
      // 通道不可用（旧装机/测试环境）= 视作不支持，UI 隐藏增配入口。
      return const GenieXStatus(supported: false, installed: false, installing: false, version: '');
    }
  }

  /// 受理安装（true = 已受理；进度/完成经 [onProgress]/[onDone] 反投）。
  static Future<bool> install(List<String> mirrors) async {
    try {
      return await _channel.invokeMethod<bool>('install', {'mirrors': mirrors}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> uninstall({bool deleteCache = false}) async {
    try {
      return await _channel.invokeMethod<bool>('uninstall', {'deleteCache': deleteCache}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 进度/完成事件订阅（通道反投）；返回取消订阅闭包。
  static void Function() listen({
    required void Function(int pct) onProgress,
    required void Function(bool ok) onDone,
  }) {
    Future<dynamic> handler(MethodCall call) async {
      final m = call.arguments as Map<Object?, Object?>? ?? const {};
      if (call.method == 'onProgress') {
        onProgress(m['pct'] as int? ?? 0);
      } else if (call.method == 'onDone') {
        onDone(m['ok'] as bool? ?? false);
      }
    }
    _channel.setMethodCallHandler(handler);
    return () => _channel.setMethodCallHandler(null);
  }
}

/// LiteRT-LM NPU 增配状态快照（多机型口径 2026-11-02：按芯片下载，取消 APK
/// 内置）。`registered` = 该 Hexagon 代际工件是否已在增配通道注册（未注册 =
/// 设置面显式「待远端工件发布」，非可安装态）。
class LiteRtLmNpuStatus {
  const LiteRtLmNpuStatus({
    required this.supported,
    required this.installed,
    required this.installing,
    required this.registered,
    required this.version,
    this.arch,
    this.sizeBytes = 0,
  });

  final bool supported;
  final bool installed;
  final bool installing;
  final bool registered;
  final String version;
  final int? arch;
  final int sizeBytes;

  static LiteRtLmNpuStatus fromMap(Object? raw) {
    final m = raw as Map<Object?, Object?>? ?? const {};
    return LiteRtLmNpuStatus(
      supported: m['supported'] as bool? ?? false,
      installed: m['installed'] as bool? ?? false,
      installing: m['installing'] as bool? ?? false,
      registered: m['registered'] as bool? ?? false,
      version: m['version'] as String? ?? '',
      arch: m['arch'] as int?,
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// LiteRT-LM NPU 增配控制绑定（与 GenieXRuntimeControl 同通道共存，方法/事件
/// 带 litertlm 前缀；镜像列表复用 GenieX 的持久化——双源裁决一套）。
abstract final class LiteRtLmNpuControl {
  static const MethodChannel _channel = MethodChannel('goodhub/geniex_runtime');

  static Future<LiteRtLmNpuStatus> status() async {
    try {
      return LiteRtLmNpuStatus.fromMap(
          await _channel.invokeMethod<Object?>('litertlmStatus'));
    } on PlatformException {
      // 通道不可用（旧装机/测试环境）= 视作不支持，UI 隐藏增配入口。
      return const LiteRtLmNpuStatus(
          supported: false,
          installed: false,
          installing: false,
          registered: false,
          version: '');
    }
  }

  /// 受理安装（true = 已受理；进度/完成经 [listen] 反投）。
  static Future<bool> install(List<String> mirrors) async {
    try {
      return await _channel
              .invokeMethod<bool>('litertlmInstall', {'mirrors': mirrors}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// 增配通道事件订阅（**合并分发**，litertlm + geniex 双族）：两族共用同一
  /// MethodChannel——`setMethodCallHandler` 相互覆盖，禁各自独立订阅（后挂
  /// 者吃掉先挂者的事件）。返回取消订阅闭包。
  static void Function() listen({
    void Function(int pct)? onGeniexProgress,
    void Function(bool ok)? onGeniexDone,
    required void Function(int pct) onProgress,
    required void Function(bool ok) onDone,
  }) {
    Future<dynamic> handler(MethodCall call) async {
      final m = call.arguments as Map<Object?, Object?>? ?? const {};
      switch (call.method) {
        case 'litertlmOnProgress':
          onProgress(m['pct'] as int? ?? 0);
        case 'litertlmOnDone':
          onDone(m['ok'] as bool? ?? false);
        case 'onProgress':
          onGeniexProgress?.call(m['pct'] as int? ?? 0);
        case 'onDone':
          onGeniexDone?.call(m['ok'] as bool? ?? false);
      }
    }
    _channel.setMethodCallHandler(handler);
    return () => _channel.setMethodCallHandler(null);
  }
}
