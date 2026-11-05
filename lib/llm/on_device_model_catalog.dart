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
/// - [llamaCpp]：通用 GGUF（GPU 档，llama.cpp 运行时；CPU 兜底已于 2026-10-31 全量退役）
/// - [litertlm]：`.litertlm` 标准化资产（LiteRT-LM 运行时，D-1 双段路由 2026-11-01）
/// - [auto]：未标注 / 混合 → doLoad 按资产布局自适应（genie_config 在场走 qairt 主路）
abstract final class OnDeviceRuntime {
  static const String qairt = 'qairt';
  static const String llamaCpp = 'llama_cpp';
  static const String litertlm = 'litertlm';
  static const String auto = 'auto';

  static bool isKnown(String? r) =>
      r == qairt || r == llamaCpp || r == litertlm || r == auto;
}

/// 资产族（backend 维度，D-1 双段路由 2026-11-01）：**资产分发期定栈**的映射
/// 单源——运行期仅同族内降级（NPU→GPU→云），禁跨栈横跳（资产内存镜像不互通，
/// 切栈=1.5~2GB 卸载+冷装载）；构型选择发生在下载/导入面，不发生在推理运行时。
abstract final class OnDeviceAssetFamily {
  /// GenieX 系：qairt bundle（QAIRT+NPU 主路）与 GGUF（llama.cpp GPU 档），
  /// 同栈内共享 GenieX 运行库与降级链。
  static const String geniex = 'geniex';

  /// LiteRT-LM 系：`.litertlm` 标准化资产（首发路线，联发科 APU 通路同族）。
  static const String litertlm = 'litertlm';

  /// 未知（auto / 布局待判）：装载期由 Runner 裁定。
  static const String unknown = 'unknown';

  static bool isKnown(String? f) =>
      f == geniex || f == litertlm || f == unknown;

  /// runtime → 资产族**单源映射**：meta `family` 字段写入与路由判定共用此
  /// 函数（禁双源）。auto 归 unknown——布局待判，装载期由 Runner 裁定。
  static String familyOf(String runtime) {
    switch (runtime) {
      case OnDeviceRuntime.qairt:
      case OnDeviceRuntime.llamaCpp:
        return geniex;
      case OnDeviceRuntime.litertlm:
        return litertlm;
      default:
        return unknown;
    }
  }
}

/// LiteRT-LM 栈装载开关（首发节奏，decisions.md ADR「首发节奏」2026-11-01）：
/// 首发 = 仅 `.litertlm` 族（从 LiteRT-LM 起步）。Runner 集成已落地
/// 2026-11-01（`LiteRtLmRunner`，多栈构型 ADR）——翻真：`.litertlm` 装载
/// 经 `:engine`（NPU（GenieX 增配已装）→ GPU → 云端收口，CPU 全程出局）。
const bool kOnDeviceLiteRtLmEnabled = true;

/// llama.cpp 通路用户面开关（**已放开**，用户拍板 2026-11-05 推翻 ADR
/// 「首发节奏」2026-11-01 关闸口径：llama_cpp 通路经 Qwen 真机轮实证健康
/// （装载 3s / 生成 9 tok/s 慢档已记录画像），GGUF 导入即导入即用）——
/// 关闸点保留（导入 UI / `_select` / `enable()` 装载闸），仅默认值翻转；
/// 如需再关闸：`--dart-define=ON_DEVICE_LLAMACPP=false`。
const bool kOnDeviceLlamaCppEnabled =
    bool.fromEnvironment('ON_DEVICE_LLAMACPP', defaultValue: true);

/// 端侧模型描述符（装载目标）。身份锚点 = [dirName]（`models/` 下落盘目录名）。
///
/// litertlm 族**不再设统一窗口默认**（2026-11-03 治理）：原
/// `kLitertlmContextTokens = 1280` 实为 Gemma3-1B 一家的规格冒充族默认，
/// 第二款 litertlm bundle（如 Qwen）会被错标——窗口规格归 per-bundle
/// 规格表（`assets/model-specs.json`，导入期回填 meta）；无命中行 =
/// contextTokens 未标注，历史预算走全局字符预算既有口径。

class OnDeviceModelOption {
  const OnDeviceModelOption({
    required this.id,
    required this.displayName,
    required this.base,
    required this.dirName,
    this.runtime = OnDeviceRuntime.auto,
    this.totalBytes,
    this.installed = false,
    this.contextTokens,
    this.recommendedSampling,
    this.loadTimeoutSec,
  });

  /// 由磁盘已装记录合成（导入模型：无下载基址）。
  OnDeviceModelOption.fromInstalled(this.dirName)
      : id = dirName,
        displayName = dirName,
        base = '',
        runtime = OnDeviceRuntime.auto,
        totalBytes = null,
        installed = true,
        contextTokens = null,
        recommendedSampling = null,
        loadTimeoutSec = null;

  final String id;
  final String displayName;

  /// 下载基址（内置档位 manifest 所在）；导入模型无基址 = ''。
  final String base;

  /// `models/` 下落盘目录名——身份锚点（注册表 / 选择 / 装载均按此定位）。
  final String dirName;

  /// 运行时标识（[OnDeviceRuntime] 常量之一）。
  final String runtime;

  /// 装载上界声明（lifecycle-single-source §7 裁决 5，meta
  /// `modelProfile.loadTimeoutSec` 透传）；null = 缺席走默认 90s。
  final int? loadTimeoutSec;

  /// 实盘资产体积（字节）：磁盘扫描回填；未扫描 = null。
  final int? totalBytes;

  /// 是否已落盘（注册表扫描回填）。
  final bool installed;

  /// 模型上下文窗口（token 上限）——历史预算按此动态推导（[on_device_chat_prompt]
  /// 的预算裁剪从全局字符预算升级为模型感知）。null = 未标注（保持全局预算，
  /// 存量 GenieX 系模型口径不变）。真机实证（2026-11-02）：全局 1200 字符
  /// 预算对 1280-context 的 .litertlm bundle 在 ASCII 最坏情形（1 字符 = 1
  /// token）必然溢出 → SDK 硬失败（`Input token ids are too long: 1293 >=
  /// 1280`）。
  final int? contextTokens;

  OnDeviceModelOption copyWith({
    String? displayName,
    String? runtime,
    int? totalBytes,
    bool? installed,
    int? contextTokens,
    OnDeviceSamplingPreset? recommendedSampling,
  }) =>
      OnDeviceModelOption(
        id: id,
        displayName: displayName ?? this.displayName,
        base: base,
        dirName: dirName,
        runtime: runtime ?? this.runtime,
        totalBytes: totalBytes ?? this.totalBytes,
        installed: installed ?? this.installed,
        contextTokens: contextTokens ?? this.contextTokens,
        recommendedSampling: recommendedSampling ?? this.recommendedSampling,
      );

  /// 推荐采样（S1 下发链透出，`modelProfile.recommendedSampling` 同源）；
  /// null = 缺席，发送链走引擎内建默认。
  final OnDeviceSamplingPreset? recommendedSampling;
}

/// 声明式解析元数据（`.asset-meta.json` 的 `modelProfile` 块，2026-11-02）：
/// 导入/安装期探测落盘，供 Runner 装载期自治消费——禁中心化 token 级解析
/// （D-3），本类型只承载声明式属性。字段全可空：meta 无块 / 探测失败 =
/// 消费方按既有内建口径走（禁臆造默认）。
class OnDeviceModelProfile {
  const OnDeviceModelProfile({
    this.chatTemplateFamily,
    this.stopSequences = const [],
    this.contextTokens,
    this.recommendedSampling,
    this.loadTimeoutSec,
  });

  /// 模板家族（qwen_chatml / llama3 / gemma / unknown）。
  final String? chatTemplateFamily;

  /// 模型级默认停用词（请求未下发时的回退位；当前写入侧暂不产出）。
  final List<String> stopSequences;

  /// 模型上下文窗口（token 上限）；与运行时默认值冲突时**本字段优先**
  /// （导入 meta 是该模型实盘的更近真相）。
  final int? contextTokens;

  /// 推荐采样（S1 策展声明，on-device-asset-metadata.md §3.5）：GGUF 头无
  /// 此字段（S0 探不出），数据来自提供方文档/规格声明——litertlm Gemma3-1B
  /// bundle = 官方 Gallery 值；null = 缺席，消费方走引擎内建默认（禁猜值）。
  final OnDeviceSamplingPreset? recommendedSampling;

  /// 装载上界声明（lifecycle-single-source §7 裁决 5：按体积预填、可改；
  /// null = 缺席走默认 90s）。过热降频/OEM 冻结恢复环境下大模型装载实测
  /// 可超 90s（2026-11-05 真机实证：2B GGUF 降频装载 100s+ 必被 90s 上界
  /// 打断），按体积声明放宽——数据住配置文件，零代码适配。
  final int? loadTimeoutSec;

  /// meta `modelProfile` map → 类型（防御式：非 Map / 字段类型不符忽略）。
  static OnDeviceModelProfile? fromMeta(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final family = (raw['chatTemplateFamily'] as String?)?.trim();
    final stops = (raw['stopSequences'] as List?)
        ?.whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final ctx = (raw['contextTokens'] as num?)?.toInt();
    final loadTimeout = (raw['loadTimeoutSec'] as num?)?.toInt();
    final samplingRaw = raw['recommendedSampling'];
    final sampling = samplingRaw is Map<String, dynamic>
        ? OnDeviceSamplingPreset.fromMeta(samplingRaw)
        : null;
    if ((family == null || family.isEmpty) &&
        (stops == null || stops.isEmpty) &&
        ctx == null &&
        sampling == null &&
        (loadTimeout == null || loadTimeout <= 0)) {
      return null;
    }
    return OnDeviceModelProfile(
      chatTemplateFamily: (family != null && family.isNotEmpty) ? family : null,
      stopSequences: stops ?? const [],
      contextTokens: ctx,
      loadTimeoutSec: (loadTimeout != null && loadTimeout > 0) ? loadTimeout : null,
      recommendedSampling: sampling,
    );
  }
}

/// 推荐采样预设（S1 策展声明，元数据管线 §3.5）：请求级采样覆盖的数据面。
/// 值域纪律同 meta：非 null 字段才下发，缺温度/缺 topP 各自独立（禁整包
/// 臆造）。
class OnDeviceSamplingPreset {
  const OnDeviceSamplingPreset({this.temperature, this.topP});

  /// 推荐温度；null = 不覆盖（引擎内建默认）。
  final double? temperature;

  /// 推荐 top-p；null = 不覆盖。
  final double? topP;

  /// meta map → 类型（防御式：字段缺失/类型不符逐字段独立容忍）。
  static OnDeviceSamplingPreset? fromMeta(Map<String, dynamic> raw) {
    final t = (raw['temperature'] as num?)?.toDouble();
    final p = (raw['topP'] as num?)?.toDouble();
    if (t == null && p == null) return null;
    return OnDeviceSamplingPreset(temperature: t, topP: p);
  }

  Map<String, dynamic> toMeta() => {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
      };
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
    this.modelProfile,
    this.templateVerified,
  });

  final String dirName;
  final String displayName;
  final String runtime;
  final int totalBytes;
  final DateTime? installedAt;
  final bool imported;

  /// 声明式解析元数据（meta 无块 = null）。
  final OnDeviceModelProfile? modelProfile;

  /// 模板可应用性探针结果（规格 on-device-asset-metadata.md §6，资产面
  /// listInstalled 扫描时回填）：false = 未验证（注册表黄灯徽章）；null =
  /// 未探测（选择路径不走探针面）。
  final bool? templateVerified;

  /// 徽章回填（资产面 listInstalled 专用——ModelRegistry.scan 保持纯读）。
  InstalledModel withTemplateVerified(bool? verified) => InstalledModel(
        dirName: dirName,
        displayName: displayName,
        runtime: runtime,
        totalBytes: totalBytes,
        imported: imported,
        installedAt: installedAt,
        modelProfile: modelProfile,
        templateVerified: verified,
      );

  OnDeviceModelOption toOption() => OnDeviceModelOption(
        id: dirName,
        displayName: displayName,
        base: '',
        dirName: dirName,
        runtime: runtime,
        totalBytes: totalBytes,
        installed: true,
        // 上下文窗口：导入 meta `modelProfile.contextTokens` 单源（per-bundle
        // 规格表导入期回填，§3.5）；未标注 = null，历史预算走全局字符预算
        // 既有口径——**禁在目录层造家族级窗口默认**（原 kLitertlmContextTokens
        // 实为 Gemma3-1B 单模型规格冒充族默认，2026-11-03 治理删除）。
        contextTokens: modelProfile?.contextTokens,
        // 推荐采样：S1 策展声明透出（下发链，§3.5）；无块 = null 走内建默认。
        recommendedSampling: modelProfile?.recommendedSampling,
        // 装载上界声明（§7 裁决 5）：meta 声明透出，null 走默认 90s。
        loadTimeoutSec: modelProfile?.loadTimeoutSec,
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
        modelProfile: OnDeviceModelProfile.fromMeta(meta['modelProfile']),
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
    // 导入制自然默认：盘上首个已装；**litertlm 族优先**（2026-11-02 默认栈
    // 拍板：默认 LiteRT-LM，GenieX 系经显式切换入口选用）。
    if (installed.isEmpty) return null;
    final preferred = installed.firstWhere(
      (m) => m.runtime == OnDeviceRuntime.litertlm,
      orElse: () => installed.first,
    );
    return preferred.toOption();
  }

  static Future<void> write(String dirName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, dirName);
  }
}
