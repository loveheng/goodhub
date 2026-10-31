/// 端侧模型注册表（纯导入制，2026-10-31 用户拍板：固定 qwen 双档位退役）。
///
/// 模型身份 = **磁盘注册表**：`models/` 下每个含 `.asset-meta.json` 的目录即
/// 一个已装模型——能跑什么模型完全由磁盘上实际装了哪些决定（llama.cpp 运行
/// 时纳入后可用模型为任意 GGUF/QAIRT 包）。**无内置目录、无默认模型**：
/// 未导入任何模型时端侧即不可用（收口云端），不偷偷拉取任何默认资产。
///
/// 选择持久化于 shared_preferences，键存 **dirName**（磁盘对齐：导入模型无
/// catalog id，只能用落盘目录名定位）；启动引导 / enable 据此解析
/// [OnDeviceModelOption]（[OnDeviceModelSelection.read]）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 运行时标识（`doLoad` 据此选主路，decisions.md ADR④）。
/// - [qairt]：HTP/NPU 专属 bundle（genie_config.json + tokenizer.json + metadata.json）
/// - [llamaCpp]：通用 GGUF（CPU/GPU，llama.cpp 运行时）
/// - [auto]：未标注 / 混合 → doLoad 按资产布局自适应（genie_config 在场走 qairt 主路）
abstract final class OnDeviceRuntime {
  static const String qairt = 'qairt';
  static const String llamaCpp = 'llama_cpp';
  static const String auto = 'auto';

  static bool isKnown(String? r) =>
      r == qairt || r == llamaCpp || r == auto;
}

/// 端侧模型描述符（装载目标）。身份锚点 = [dirName]（`models/` 下落盘目录名）。
class OnDeviceModelOption {
  const OnDeviceModelOption({
    required this.id,
    required this.displayName,
    required this.base,
    required this.dirName,
    this.runtime = OnDeviceRuntime.auto,
    this.totalBytes,
    this.installed = false,
  });

  /// 由磁盘已装记录合成（导入模型：无下载基址）。
  OnDeviceModelOption.fromInstalled(this.dirName)
      : id = dirName,
        displayName = dirName,
        base = '',
        runtime = OnDeviceRuntime.auto,
        totalBytes = null,
        installed = true;

  final String id;
  final String displayName;

  /// 下载基址（内置档位 manifest 所在）；导入模型无基址 = ''。
  final String base;

  /// `models/` 下落盘目录名——身份锚点（注册表 / 选择 / 装载均按此定位）。
  final String dirName;

  /// 运行时标识（[OnDeviceRuntime] 常量之一）。
  final String runtime;

  /// 实盘资产体积（字节）：磁盘扫描回填；未扫描 = null。
  final int? totalBytes;

  /// 是否已落盘（注册表扫描回填）。
  final bool installed;

  OnDeviceModelOption copyWith({
    String? displayName,
    String? runtime,
    int? totalBytes,
    bool? installed,
  }) =>
      OnDeviceModelOption(
        id: id,
        displayName: displayName ?? this.displayName,
        base: base,
        dirName: dirName,
        runtime: runtime ?? this.runtime,
        totalBytes: totalBytes ?? this.totalBytes,
        installed: installed ?? this.installed,
      );
}

/// 磁盘注册表条目（`.asset-meta.json` 解析产物）。
class InstalledModel {
  const InstalledModel({
    required this.dirName,
    required this.displayName,
    required this.runtime,
    required this.totalBytes,
    required this.imported,
    this.installedAt,
  });

  final String dirName;
  final String displayName;
  final String runtime;
  final int totalBytes;
  final DateTime? installedAt;
  final bool imported;

  OnDeviceModelOption toOption() => OnDeviceModelOption(
        id: dirName,
        displayName: displayName,
        base: '',
        dirName: dirName,
        runtime: runtime,
        totalBytes: totalBytes,
        installed: true,
      );
}

/// 自由导入目标（导入制新增模型：落盘目录名 + 展示名 + 运行时标注）。
///
/// 与 [OnDeviceModelOption] 区分——目标此刻**尚无实盘资产**，导入成功写 meta
/// 后即成为注册表条目。[runtime] 缺省 [OnDeviceRuntime.auto]：结构校验会按
/// 资产布局（genie_config / .gguf）回填真实运行时。
class ImportTarget {
  const ImportTarget({
    required this.dirName,
    required this.displayName,
    this.runtime = OnDeviceRuntime.auto,
  });

  final String dirName;
  final String displayName;
  final String runtime;
}

/// 磁盘模型注册表（身份唯一源）：扫 `models/` 下含 `.asset-meta.json` 的目录。
///
/// 失败一律**降级为空**（try/catch 兜底）——注册表不可达不应阻断引擎引导
/// （启动路径据此落默认），只影响设置页已装列表。
abstract final class ModelRegistry {
  static const String metaFileName = '.asset-meta.json';
  static const String importedVersionPrefix = 'local-import';

  /// 扫描已装模型。[supportDirResolver] 注入根目录（测试面）；默认应用支持目录。
  static Future<List<InstalledModel>> scan({
    Future<Directory> Function()? supportDirResolver,
  }) async {
    final out = <InstalledModel>[];
    try {
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final modelsRoot = Directory('${support.path}/models');
      if (!await modelsRoot.exists()) return out;
      await for (final entity in modelsRoot.list()) {
        if (entity is! Directory) continue;
        // 目录名取 entity.path 尾段——**禁用 entity.uri.pathSegments.last**：
        // Dart 的 Directory.uri 对目录恒补尾部斜杠（file:///…/foo/），末段
        // 是空串（真机实证：全部已装模型 dirName='' → 装载目标打在 models/
        // 根 → 「资产缺失」误报）。File 的 uri 无此补齐，File 场景不受影响。
        final name = entity.path.split('/').last;
        if (name.isEmpty || name.startsWith('.')) {
          continue; // 空段防御 + .staging-*/.trash-* 隐藏目录
        }
        final m = await _readMeta(entity, name);
        if (m != null) out.add(m);
      }
      out.sort((a, b) => a.dirName.compareTo(b.dirName));
    } catch (e) {
      debugPrint('[DEGRADE] model-registry scan: $e');
    }
    return out;
  }

  /// 解析单目录 meta（测试面直接调用）；无 meta / 解析失败返 null（不入库）。
  @visibleForTesting
  static Future<InstalledModel?> readMeta(Directory dir, String dirName) =>
      _readMeta(dir, dirName);

  static Future<InstalledModel?> _readMeta(
      Directory dir, String dirName) async {
    try {
      final metaFile = File('${dir.path}/$metaFileName');
      if (!await metaFile.exists()) return null;
      final meta = jsonDecode(await metaFile.readAsString())
          as Map<String, dynamic>;
      final version = meta['version'] as String? ?? '';
      final sizes = (meta['sizes'] as Map<String, dynamic>?) ?? const {};
      int totalBytes = (meta['totalBytes'] as num?)?.toInt() ?? 0;
      if (totalBytes == 0) {
        for (final v in sizes.values) {
          if (v is num) totalBytes += v.toInt();
        }
      }
      final rawRuntime = meta['runtime'] as String?;
      final runtime = OnDeviceRuntime.isKnown(rawRuntime)
          ? rawRuntime!
          : OnDeviceRuntime.auto;
      final rawName = (meta['displayName'] as String?)?.trim();
      final installedAt = (meta['installedAt'] as String?) != null
          ? DateTime.tryParse(meta['installedAt'] as String)
          : null;
      return InstalledModel(
        dirName: dirName,
        displayName: (rawName != null && rawName.isNotEmpty) ? rawName : dirName,
        runtime: runtime,
        totalBytes: totalBytes,
        installedAt: installedAt,
        imported: version.startsWith(importedVersionPrefix),
      );
    } catch (e) {
      debugPrint('[DEGRADE] model-registry meta parse: $e');
      return null;
    }
  }
}

/// 选择持久化（shared_preferences 单键，存 **dirName**；磁盘对齐）。
abstract final class OnDeviceModelSelection {
  static const String _key = 'on_device.model.selected_dir';

  /// 解析当前选中模型：prefs(dirName) > 磁盘首个已装。全部落空返 **null**
  /// （未导入任何模型 → 端侧不可用，调用方收口云端；**无默认模型**）。
  static Future<OnDeviceModelOption?> read({
    Future<Directory> Function()? supportDirResolver,
  }) async {
    String? dirName;
    try {
      final prefs = await SharedPreferences.getInstance();
      dirName = prefs.getString(_key);
    } catch (_) {
      return null; // prefs 不可达（测试环境）→ 未选模型
    }

    final installed =
        await ModelRegistry.scan(supportDirResolver: supportDirResolver);
    if (dirName != null && dirName.isNotEmpty) {
      for (final m in installed) {
        if (m.dirName == dirName) return m.toOption();
      }
      // 选中目录已不在盘（被删）→ 落默认。
    }
    // 导入制自然默认：盘上首个已装；否则 null。
    return installed.isNotEmpty ? installed.first.toOption() : null;
  }

  static Future<void> write(String dirName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, dirName);
  }
}
