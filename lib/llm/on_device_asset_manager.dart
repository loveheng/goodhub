import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/storage/sequential_file_writer.dart';
import 'on_device_dispatch_profile.dart';
import 'on_device_engine_binding.dart';
import 'on_device_gguf_header.dart';
import 'on_device_model_catalog.dart';

/// 端侧模型资产 OTA 正式分发通道（on-device S2-2，接替 S2-1 冒烟直下载
/// PATCH）。规格 SSOT：on-device-npu-deployment.md §4.5/§4.6/§4.8。
///
/// 职责链（全部在落盘前完成校验，杜绝半份资产被 :engine 装载）：
/// 1. **manifest 分发**（§4.5 版本对齐）：远端 `manifest.json` 单源声明
///    `version` + 每文件 `size`/`sha256`——tokenizer 与 ctx-bin 分片同一次
///    CI 产出、同版本 hash 绑定，杜绝「新权重 + 旧词表」Detokenize 乱码；
/// 2. **≥5GB 磁盘门禁**（§4.6）：下载前校验空闲空间，不满足直接中止
///    （DEGRADE 留痕），防 ENOSPC 崩溃与反复重下；
/// 3. **流式下载 + 字节级校验**（2026-10-28 真机实证：`bodyBytes` 对百 MB
///    级响应静默截断）——边下边算 sha256 + 计数，Content-Length 与
///    manifest 双重核对，不符即弃；
/// 4. **原子替换**（§4.6 防 SIGBUS）：整包下载到 `.staging-*` 暂存目录，
///    全量校验通过后旧目录挪 `.trash-*`（mmap 旧句柄持旧 inode，不段错）、
///    staging rename 转正、trash 删除——`:engine` 装载期间热更新不损毁；
/// 5. **驱动指纹元数据**（§4.8）：下载完成时记录 `Build.FINGERPRINT` 进
///    `.asset-meta.json`；驱动 OTA 后指纹漂移 → [recoverIfDriverChanged]
///    脏删重拉。不兼容自愈**不计入熔断**（§6.5 口径：环境变更非本端
///    Bug）——本件不触碰 EngineCircuitBreaker，死亡计数仍只来自生成链路。
///
/// 落盘目录沿用 S2-1 实证通路：`getApplicationSupportDirectory()/models/`
/// （本 ROM `run-as` 被 SELinux 全禁，内部私有目录是唯一可靠落点，`filesDir`
/// 语义——**严禁 cacheDir**，§4.6 静默清空坑）。
class OnDeviceAssetManager {
  OnDeviceAssetManager._({
    this.baseUrlOverride,
    this.freeBytesProvider,
    this.fingerprintProvider,
    this.supportDirResolver,
    this.modelSpecsSource,
    this.now,
  });

  /// 测试注入构造：基址/磁盘余量/驱动指纹/support 根目录/规格表源全部可注入，
  /// 单测以本地 HttpServer + 临时目录全链路跑通，不触平台通道。
  @visibleForTesting
  OnDeviceAssetManager.forTest({
    String? baseUrlOverride,
    Future<int?> Function()? freeBytesProvider,
    Future<String?> Function()? fingerprintProvider,
    Future<Directory> Function()? supportDirResolver,
    Future<String> Function()? modelSpecsSource,
    DateTime Function()? now,
  }) : this._(
          baseUrlOverride: baseUrlOverride,
          freeBytesProvider: freeBytesProvider,
          fingerprintProvider: fingerprintProvider,
          supportDirResolver: supportDirResolver,
          modelSpecsSource: modelSpecsSource,
          now: now,
        );

  static final OnDeviceAssetManager instance = OnDeviceAssetManager._();

  /// 冒烟期资产源（内网 HTTP + `adb reverse tcp:8090 tcp:8090` 回环；LAN
  /// 直连被 PC 防火墙拦，2026-10-28 实证）。正式分发换远端对象存储时只改
  /// 此值——分发键（SoC × HTP 版本 × 驱动指纹）经 manifest.url/query 承载。
  final String? baseUrlOverride;

  /// 本地导入资产的 meta 版本前缀（2026-10-30 用户裁决：模型改导入制，
  /// 废弃在线 OTA 依赖——模型体积过大无在线存储）。带此前缀的资产在
  /// [ensureAssets] 里完全跳过 manifest/网络面，尺寸校验过即用。
  static const String _importedVersionPrefix = 'local-import';

  /// 装载目标解析（§4.5 分发键经选项承载）：显式 model（设置页选择）优先 >
  /// 实例构造 override（测试注入）。**无默认模型**（2026-10-31 固定档位退役，
  /// 纯导入制）：未选/未装模型 → null，调用方收口「资产缺失」，不拉默认资产。
  String? _baseOf(OnDeviceModelOption? model) =>
      model?.base ?? baseUrlOverride;

  String? _dirOf(OnDeviceModelOption? model) => model?.dirName;

  /// 资产身份 modelId（设计 §2.5 I3 单点计算）：`目录名@meta版本摘要前12位`。
  /// 导入/删除/重导后取值必然变化——装载单飞去重键（I7）与会话票据对账
  /// （I3）共用此值；`:engine` 票据回显经 loadModel 入参承载，双端口径同源。
  /// meta 不可读退化为目录名（仍可对账，只是丢失版本粒度）。
  Future<String?> modelIdOf(OnDeviceModelOption? model) async {
    final dirName = _dirOf(model);
    if (dirName == null) return null;
    try {
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final metaFile =
          File('${support.path}/models/$dirName/${ModelRegistry.metaFileName}');
      if (!await metaFile.exists()) return dirName;
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final version = meta['version'] as String? ?? '';
      if (version.isEmpty) return dirName;
      final digest = version.length > 12 ? version.substring(0, 12) : version;
      return '$dirName@$digest';
    } catch (e) {
      // C6 修正：资产身份是 I3 对账的锚点，降级必留痕（禁静默）——降级值
      // 仍可用（目录名回退），但任何下游身份对账异常都需能归因到这里。
      // ignore: avoid_print
      print('[DEGRADE] modelIdOf fallback to dirName: $e');
      return dirName;
    }
  }

  /// §4.6 双倍空间门禁（≈2.5× 1.8GB 模型体积，含解压峰值余量）。
  static const int _minFreeBytes = 5 * 1024 * 1024 * 1024;

  /// 自由导入**绝对体积上限**（唯一体积硬闸）：12GB 远超任何现实
  /// 端侧模型（7B@Q8≈4.5GB），越过即拒——防用户误把超大权重导到端侧必 OOM。
  static const int _importMaxBytes = 12 * 1024 * 1024 * 1024;

  /// 自由导入体积**告警线**（4GB，7B@Q8 量级）：越过仅提示「可能内存不足」
  /// 不阻断——装载期内存护栏 + 快死棘轮仍是运行时兜底，此处只作 UX 预警。
  static const int _importWarnBytes = 4 * 1024 * 1024 * 1024;

  /// 可注入探针（测试面）：磁盘余量 / 驱动指纹。真机走平台通道。
  final Future<int?> Function()? freeBytesProvider;
  final Future<String?> Function()? fingerprintProvider;
  final Future<Directory> Function()? supportDirResolver;
  final DateTime Function()? now;

  /// per-bundle 规格表源（S1 策展声明数据面，2026-11-03 用户拍板「通用实现
  /// 禁止在代码里绑定具体模型」）：默认读打包资产 `assets/model-specs.json`，
  /// 测试注入覆盖。文件 schema：`{bundles: [{id, runtime, artifactPattern,
  /// contextTokens?, recommendedSampling?}]}`——模型适配数据住配置文件，
  /// 代码只留通用匹配逻辑；读失败/畸形 → 空表（S1 字段缺席，增强面非门禁）。
  final Future<String> Function()? modelSpecsSource;

  /// 规格表加载 + 按 bundle 文件名匹配（大小写不敏感 contains）。[artifact]
  /// = 目录内首个 bundle 工件文件名；无命中/表不可读 → null（字段缺席）。
  Future<Map<String, dynamic>?> _matchBundleSpec(
      String runtime, String? artifact) async {
    if (artifact == null || artifact.isEmpty) return null;
    try {
      final raw = await (modelSpecsSource ??
          () => rootBundle.loadString('assets/model-specs.json'))();
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final bundles = parsed['bundles'];
      if (bundles is! List) return null;
      final lower = artifact.toLowerCase();
      for (final row in bundles) {
        if (row is! Map<String, dynamic>) continue;
        if (row['runtime'] != runtime) continue;
        final pattern = (row['artifactPattern'] as String?)?.toLowerCase();
        if (pattern == null || !lower.contains(pattern)) continue;
        return row;
      }
      return null;
    } catch (e) {
      debugPrint('[DEGRADE] model-specs load: $e');
      return null;
    }
  }

  /// 装配入口（main.dart 启动引导 / 冒烟诊断 / 设置页共用）：已装（导入 meta
  /// 在场且尺寸全对）即返回；否则对带 [model.base] 的目标走 manifest 下载
  /// 通道（测试/冒烟面）。**纯导入制无默认模型**（2026-10-31 固定档位退役）：
  /// [model] 为 null → 资产缺失返回 null（调用方收口云端），不拉默认资产。
  /// 返回模型目录；失败返回 null（DEGRADE 留痕，调用方走云端默认通路）。
  Future<Directory?> ensureAssets({
    OnDeviceModelOption? model,
    void Function(AssetPullProgress progress)? onProgress,
  }) async {
    void report(AssetPullProgress p) {
      try {
        onProgress?.call(p);
      } catch (_) {}
    }

    if (model == null) {
      debugPrint('[DEGRADE] on-device assets: no model selected → 资产缺失（无默认模型）');
      return null;
    }
    final base = _baseOf(model);
    try {
      final support = await (supportDirResolver ?? getApplicationSupportDirectory)();
      final modelsRoot = Directory('${support.path}/models');
      final target = Directory('${modelsRoot.path}/${model.dirName}');

      // 导入资产优先（2026-10-30 拍板：模型改导入制）：在盘且尺寸全对即
      // 直接返回，manifest 不可达/在线通道退役都不影响装载。
      if (await _isImportedVerified(target)) {
        report(const AssetPullProgress(
            phase: 'done', detail: '本地导入资产校验通过（跳过下载）'));
        return target;
      }

      // base 空串语义 = 导入制无下载基址（fromInstalled/toOption 约定），
      // 与 null 同归「无基址」——否则空串拼 URI 空跑一次必然失败的 manifest 拉取。
      if (base == null || base.isEmpty) {
        debugPrint('[DEGRADE] on-device assets: ${model.dirName} 未导入且无下载基址 → 资产缺失');
        return null;
      }
      report(const AssetPullProgress(phase: 'manifest'));
      final manifest = await _fetchManifest(base);
      if (manifest == null) return await _installedFallback(target);

      final installed = await _verifyInstalled(target, manifest);
      if (installed) {
        report(AssetPullProgress(
            phase: 'done', detail: '已装资产校验通过（跳过下载）'));
        return target;
      }

      // §4.8：驱动指纹漂移（系统 OTA 更新 DSP 驱动）→ 旧资产视为脏数据，
      // 本轮整包重拉即自愈；失败不重试旧产物。
      final drift = await _driverFingerprintDrifted(target);
      if (drift) {
        debugPrint('[on-device] asset driver-fingerprint drift → full re-fetch');
      }

      if (!await _diskGate(manifest.totalBytes)) return null;

      final staging =
          Directory('${modelsRoot.path}/.staging-${DateTime.now().millisecondsSinceEpoch}');
      await staging.create(recursive: true);
      try {
        var doneBytes = 0;
        for (final entry in manifest.files) {
          final ok = await _downloadVerified(base, entry, staging);
          if (!ok) return await _cleanupStaging(staging);
          doneBytes += entry.size;
          report(AssetPullProgress(
            phase: 'file',
            fileName: entry.name,
            receivedBytes: doneBytes,
            totalBytes: manifest.totalBytes,
          ));
        }
        await _writeMeta(staging, manifest);
        await _atomicSwap(staging, target, modelsRoot);
        report(AssetPullProgress(
          phase: 'done',
          receivedBytes: manifest.totalBytes,
          totalBytes: manifest.totalBytes,
          detail: manifest.version,
        ));
      } catch (_) {
        await _rmdirQuiet(staging);
        rethrow;
      }
      debugPrint('[on-device] assets ${manifest.version} installed '
          '(${manifest.files.length} files, ${manifest.totalBytes ~/ 1048576}MB)');
      return target;
    } catch (e) {
      debugPrint('[DEGRADE] on-device assets: $e');
      return null;
    }
  }

  /// §4.8 自愈入口：装载报不兼容（`INCOMPATIBLE_BINARY` 错误族 / 驱动指纹
  /// 漂移）时由调用方触发——脏删本地资产（静默、不重试旧产物），下轮
  /// [ensureAssets] 整包重拉。**不计入熔断**（§6.5 口径），本件不触碰
  /// EngineCircuitBreaker。
  Future<void> markDirty({OnDeviceModelOption? model}) async {
    final dirName = _dirOf(model);
    if (dirName == null) return; // 无目标（未选模型）→ no-op
    try {
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final target = Directory('${support.path}/models/$dirName');
      if (await target.exists()) {
        await _rmdirQuiet(target);
        debugPrint('[on-device] asset marked dirty (removed for re-fetch)');
      }
    } catch (e) {
      debugPrint('[DEGRADE] asset markDirty: $e');
    }
  }

  /// 驱动指纹漂移自愈：已装资产的指纹 ≠ 当前指纹 → 脏删（§4.8 单向匹配，
  /// 旧产物不回灌也不复用）。
  Future<bool> recoverIfDriverChanged({OnDeviceModelOption? model}) async {
    final dirName = _dirOf(model);
    if (dirName == null) return false; // 无目标（未选模型）→ 无可自愈
    final support =
        await (supportDirResolver ?? getApplicationSupportDirectory)();
    final target = Directory('${support.path}/models/$dirName');
    if (!await target.exists()) return false;
    if (await _driverFingerprintDrifted(target)) {
      await markDirty(model: model);
      return true;
    }
    return false;
  }

  /// 廉价在位检查（设置段目录态展示用）：目录 + `.asset-meta.json` 在场即
  /// 视为已装（不拉 manifest 不验尺寸——真伪由装载路径 [_verifyInstalled]
  /// 与 §4.8 漂移自愈兜底）。
  Future<bool> isInstalled(OnDeviceModelOption model) async {
    try {
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final target =
          Directory('${support.path}/models/${_dirOf(model)}');
      if (!await target.exists()) return false;
      return await File('${target.path}/.asset-meta.json').exists();
    } catch (_) {
      return false;
    }
  }

  /// 注册表扫描（身份唯一源，2026-10-31 多模型导入制）：已装模型列表（含
  /// 自由导入 + 内置档位）。注入 [supportDirResolver] 生效（测试面）；失败
  /// 降级为空（不阻断）。设置页据此渲染「已装模型」而非固定目录。
  /// 扫描前先跑存量 modelProfile 幂等迁移（规格 §7），扫描后回填模板可
  /// 应用性徽章（规格 §6）。
  Future<List<InstalledModel>> listInstalled() async {
    await _migrateMissingProfiles();
    final scanned =
        await ModelRegistry.scan(supportDirResolver: supportDirResolver);
    final support =
        await (supportDirResolver ?? getApplicationSupportDirectory)();
    final out = <InstalledModel>[];
    for (final m in scanned) {
      final verified = await templateApplicability(
          Directory('${support.path}/models/${m.dirName}'), m.runtime);
      out.add(m.withTemplateVerified(verified));
    }
    return out;
  }

  /// 存量模型幂等迁移（规格 on-device-asset-metadata.md §7）：modelProfile
  /// 块缺失（机制落地前的旧 meta）→ 补探测 → 整文件原子重写。幂等：块
  /// 在场不再触发；探测失败不写（保块缺席，下轮重试，不阻断读）。version
  /// 保持 → modelId 稳定（身份仅认 version 前缀），迁移不触发资产变更
  /// 重装。顺带回填存量下载通道 meta 缺失的结构区字段（runtime/family）。
  Future<void> _migrateMissingProfiles() async {
    try {
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final modelsRoot = Directory('${support.path}/models');
      if (!await modelsRoot.exists()) return;
      await for (final entity in modelsRoot.list()) {
        if (entity is! Directory) continue;
        final name = entity.path.split('/').last;
        if (name.isEmpty || name.startsWith('.')) continue;
        await _migrateOneIfMissing(entity);
      }
    } catch (e) {
      debugPrint('[DEGRADE] model-profile migration: $e');
    }
  }

  Future<void> _migrateOneIfMissing(Directory dir) async {
    try {
      final metaFile = File('${dir.path}/.asset-meta.json');
      if (!await metaFile.exists()) return;
      final meta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      if (meta.containsKey('modelProfile')) return;
      final rawRuntime = meta['runtime'] as String?;
      final runtime = OnDeviceRuntime.isKnown(rawRuntime)
          ? rawRuntime!
          : await _runtimeOfDir(dir);
      final profile = await _probeModelProfile(dir, runtime);
      if (profile == null) return; // 探测失败：保块缺席，不写半效迁移
      meta['runtime'] = runtime;
      meta['family'] = OnDeviceAssetFamily.familyOf(runtime);
      meta['modelProfile'] = profile;
      // 规格 §4：meta 只允许整文件原子重写，禁局部 patch。
      await SequentialFileWriter(metaFile).write(jsonEncode(meta));
      debugPrint('[on-device] model-profile migration: '
          '${dir.path.split('/').last} (runtime=$runtime, profile=$profile)');
    } catch (e) {
      debugPrint('[DEGRADE] model-profile migration '
          '${dir.path.split('/').last}: $e');
    }
  }

  /// 模板可应用性静态探针（规格 on-device-asset-metadata.md §6，测试钩子）：
  /// 判据 = 资产内是否存在可应用的 tokenizer 模板，**不是 meta 字段 null
  /// 性**——模板优先路径（SDK applyChatTemplate / bundle 原生模板）下，
  /// family 标注只在手写 fallback 路径起作用。
  /// - qairt：`tokenizer.json` 在场（applyChatTemplate 内嵌模板载体）；
  /// - llama_cpp/GGUF：`tokenizer.chat_template` KV 在场且非空；
  /// - litertlm：模板归 bundle 原生（SDK Conversation 角色映射），静态
  ///   检查止于布局（至少一个 .litertlm 文件在场）；
  /// - auto / 未知布局：false（布局未判 = 未验证）。
  @visibleForTesting
  static Future<bool> templateApplicability(
      Directory dir, String runtime) async {
    switch (runtime) {
      case OnDeviceRuntime.qairt:
        return File('${dir.path}/tokenizer.json').exists();
      case OnDeviceRuntime.litertlm:
        try {
          await for (final e in dir.list()) {
            if (e is File && e.path.toLowerCase().endsWith('.litertlm')) {
              return true;
            }
          }
        } catch (_) {}
        return false;
      case OnDeviceRuntime.llamaCpp:
        final gguf = await _firstGguf(dir);
        if (gguf == null) return false;
        final tpl = (await _ggufProbe(gguf))?[GgufKeys.chatTemplate] as String?;
        return tpl?.isNotEmpty ?? false;
      default:
        return false;
    }
  }

  // ---- manifest ----

  Future<_AssetManifest?> _fetchManifest(String base) async {
    try {
      final resp =
          await http.get(Uri.parse('$base/manifest.json')).timeout(const Duration(minutes: 2));
      if (resp.statusCode != 200) {
        debugPrint('[DEGRADE] asset manifest: HTTP ${resp.statusCode}');
        return null;
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final version = json['version'] as String?;
      final files = (json['files'] as List?)
          ?.map((e) => _AssetFile.fromJson(e as Map<String, dynamic>))
          .toList();
      if (version == null || version.isEmpty || files == null || files.isEmpty) {
        debugPrint('[DEGRADE] asset manifest malformed');
        return null;
      }
      return _AssetManifest(version, files);
    } catch (e) {
      debugPrint('[DEGRADE] asset manifest fetch: $e');
      return null;
    }
  }

  // ---- 校验 ----

  /// 廉价在位校验（启动引导每次跑）：meta 版本一致 + 文件尺寸全对。
  /// sha256 不在此重算（1.8GB 逐轮哈希不现实）——完整性由下载时点保证，
  /// 尺寸漂移/装载异常走 [markDirty] 脏删重拉。
  Future<bool> _verifyInstalled(Directory target, _AssetManifest manifest) async {
    try {
      if (!await target.exists()) return false;
      final metaFile = File('${target.path}/.asset-meta.json');
      if (!await metaFile.exists()) return false;
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      if (meta['version'] != manifest.version) return false;
      final sizes = (meta['sizes'] as Map<String, dynamic>?) ?? const {};
      for (final f in manifest.files) {
        final file = File('${target.path}/${f.name}');
        if (!await file.exists()) return false;
        if (await file.length() != f.size) return false;
        if (sizes[f.name] != f.size) return false;
      }
      return true;
    } catch (e) {
      debugPrint('[DEGRADE] asset verify: $e');
      return false;
    }
  }

  Future<bool> _driverFingerprintDrifted(Directory target) async {
    try {
      final metaFile = File('${target.path}/.asset-meta.json');
      if (!await metaFile.exists()) return false; // 无 meta 视为未知，不判漂移
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final recorded = meta['driverFingerprint'] as String?;
      final current = await _currentFingerprint();
      if (recorded == null || current == null) return false; // 拿不到指纹不误判
      return recorded != current;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _currentFingerprint() async {
    if (fingerprintProvider != null) return fingerprintProvider!();
    try {
      return await OnDeviceEngineBinding.channel
          .invokeMethod<String>('deviceFingerprint')
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[DEGRADE] deviceFingerprint: $e');
      return null;
    }
  }

  // ---- 磁盘门禁 ----

  Future<bool> _diskGate(int requiredBytes) async {
    final free = await _freeBytes();
    if (free == null) {
      // 拿不到余量：真机平台通道不可用属异常——放行但留痕（下载端仍有
      // 字节级校验兜底，ENOSPC 会以写盘异常暴露，不静默损坏）。
      debugPrint('[on-device] disk-gate skipped (free-space unavailable)');
      return true;
    }
    if (free < _minFreeBytes) {
      debugPrint('[DEGRADE] disk-gate reject: free=${(free / 1073741824).toStringAsFixed(2)}GB '
          '< ${_minFreeBytes ~/ 1073741824}GB (§4.6)');
      return false;
    }
    debugPrint('[on-device] disk-gate ok: free=${(free / 1073741824).toStringAsFixed(2)}GB');
    return true;
  }

  Future<int?> _freeBytes() async {
    if (freeBytesProvider != null) return freeBytesProvider!();
    try {
      return await OnDeviceEngineBinding.channel
          .invokeMethod<int>('freeDiskSpace')
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[DEGRADE] freeDiskSpace: $e');
      return null;
    }
  }

  // ---- 下载 ----

  /// 流式下载单文件到 [dir]，边下边 sha256 + 计数；Content-Length、manifest
  /// 尺寸、sha256 三重核对全过才转正（`.part` → 原名）。
  Future<bool> _downloadVerified(String base, _AssetFile entry, Directory dir) async {
    final sw = Stopwatch()..start();
    try {
      final req = http.Request('GET', Uri.parse('$base/${entry.name}'));
      final resp = await http.Client().send(req).timeout(const Duration(minutes: 30));
      if (resp.statusCode != 200) {
        debugPrint('[DEGRADE] asset ${entry.name}: HTTP ${resp.statusCode}');
        return false;
      }
      final part = File('${dir.path}/${entry.name}.part');
      final sink = part.openWrite();
      final shaSink = _DigestSink();
      final digest = sha256.startChunkedConversion(shaSink);
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          sink.add(bytes);
          digest.add(bytes);
          received += bytes.length;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final expectedLength = resp.contentLength;
      if (expectedLength != null && received != expectedLength) {
        digest.close();
        debugPrint('[DEGRADE] asset ${entry.name} truncated: $received vs $expectedLength');
        await _rmdirQuiet(part); // 仅删本文件的 staging 内残留
        return false;
      }
      if (received != entry.size) {
        digest.close();
        debugPrint('[DEGRADE] asset ${entry.name} size mismatch: $received vs ${entry.size}');
        return false;
      }
      digest.close();
      final got = shaSink.value.toString();
      if (got != entry.sha256) {
        debugPrint('[DEGRADE] asset ${entry.name} sha256 mismatch');
        return false;
      }
      await part.rename('${dir.path}/${entry.name}');
      debugPrint('[on-device] asset ${entry.name} '
          '${(received / 1048576).toStringAsFixed(1)}MB in ${sw.elapsedMilliseconds}ms');
      return true;
    } catch (e) {
      debugPrint('[DEGRADE] asset ${entry.name}: $e');
      return false;
    }
  }

  // ---- 落盘元数据与原子替换 ----

  /// 准入画像文件名（DispatchProfile 设计稿 §2）：与 `.asset-meta.json` 同目录，
  /// 生命周期同源——`markDirty`/`recoverIfDriverChanged` 删目录时随 meta 一并
  /// 脏删（画像落模型目录内，无独立清理面）。指纹漂移由 [readDispatchProfile]
  /// 读取时判定（文件内自含指纹，漂移 = 失效并清除）。
  static const String _admissionFileName = '.admission.json';

  /// 读取准入画像（DispatchProfile 契约 = `on_device_dispatch_profile.dart`）：
  /// 文件缺失/损坏/指纹漂移（`driverFingerprint` ≠ 当前）→ null 并清脏文件。
  /// 纯本地读，路由查表零开销（设计稿 §6）。
  Future<DispatchProfile?> readDispatchProfile(
      OnDeviceModelOption model) async {
    final dir = await _dirOfModel(model);
    if (dir == null) return null;
    final f = File('${dir.path}/$_admissionFileName');
    if (!await f.exists()) return null;
    final profile = DispatchProfile.fromJson(await f.readAsString());
    if (profile == null) {
      await _deleteQuietly(f);
      return null;
    }
    final current = await _currentFingerprint();
    if (current != null && profile.driverFingerprint != current) {
      // 驱动 OTA → 画像整体失效（§1 键含 FINGERPRINT）：清脏，等重探。
      await _deleteQuietly(f);
      return null;
    }
    return profile;
  }

  /// 写入准入画像（两个写入方共用：导入探针 HEALTHY / 运行时坏后端 EXCLUDED）。
  /// 指纹在写入时点采样——画像有效性锚定本机当次驱动状态。
  Future<void> writeDispatchProfile(
    OnDeviceModelOption model,
    Map<String, BackendProfile> backends, {
    int? probedAtMs,
  }) async {
    final dir = await _dirOfModel(model);
    if (dir == null) return;
    final fingerprint = await _currentFingerprint();
    if (fingerprint == null) {
      debugPrint('[DEGRADE] admission write skipped (fingerprint unavailable)');
      return; // 拿不到指纹不写半效画像（读取面靠指纹判定失效）
    }
    final profile = DispatchProfile(
      driverFingerprint: fingerprint,
      backends: backends,
      probedAtMs: probedAtMs ?? (now ?? DateTime.now)().millisecondsSinceEpoch,
    );
    await SequentialFileWriter(File('${dir.path}/$_admissionFileName'))
        .write(jsonEncode(profile.toJson()));
  }

  Future<Directory?> _dirOfModel(OnDeviceModelOption model) async {
    final dirName = _dirOf(model);
    if (dirName == null) return null;
    final support =
        await (supportDirResolver ?? getApplicationSupportDirectory)();
    return Directory('${support.path}/models/$dirName');
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[DEGRADE] admission file cleanup: $e');
    }
  }

  Future<void> _writeMeta(Directory dir, _AssetManifest manifest) async {
    final fingerprint = await _currentFingerprint();
    // 下载通道无显式 runtime 标注，按 staging 实盘布局判（genie_config →
    // qairt；.litertlm → litertlm）。runtime/family 与导入通道同字段集落盘
    //（规格 on-device-asset-metadata.md §2 结构区——两通道对齐禁漂移）。
    final runtime = await _runtimeOfDir(dir);
    final modelProfile = await _probeModelProfile(dir, runtime);
    final meta = {
      'version': manifest.version,
      'installedAt': (now ?? DateTime.now)().toIso8601String(),
      'driverFingerprint': fingerprint,
      'runtime': runtime,
      'family': OnDeviceAssetFamily.familyOf(runtime),
      'sizes': {for (final f in manifest.files) f.name: f.size},
      'sha256': {for (final f in manifest.files) f.name: f.sha256},
      'modelProfile': ?modelProfile,
    };
    // 临时文件 + rename 原子替换（R10 纪律，复用既有写队列）。
    await SequentialFileWriter(File('${dir.path}/.asset-meta.json'))
        .write(jsonEncode(meta));
  }

  /// §4.6 热更新原子替换：staging → target 三步——旧目录挪 trash（mmap 旧
  /// 句柄持旧 inode 不 SIGBUS）、staging rename 转正、trash 异步清除。
  /// POSIX rename 对非空目标目录失败，故必须先挪走旧目录；挪走与转正之间
  /// 崩溃的恢复面 = target 缺失，下轮 ensureAssets 整包重下（幂等）。
  Future<void> _atomicSwap(
      Directory staging, Directory target, Directory modelsRoot) async {
    final trash = Directory(
        '${modelsRoot.path}/.trash-${(now ?? DateTime.now)().millisecondsSinceEpoch}');
    if (await target.exists()) {
      await target.rename(trash.path);
    }
    await staging.rename(target.path);
    if (await trash.exists()) {
      // 清除失败不致命（仅占磁盘），下轮启动门禁仍按真实余量判。
      await _rmdirQuiet(trash);
    }
  }

  /// manifest 不可达时的已装兜底：旧冒烟通道装的资产（有 `.size-verified`
  /// 标记）仍可用——避免升级瞬间把可用资产判失效重下 1.8GB。
  Future<Directory?> _installedFallback(Directory target) async {
    try {
      if (await File('${target.path}/.size-verified').exists() ||
          await File('${target.path}/.asset-meta.json').exists()) {
        return target;
      }
    } catch (_) {}
    return null;
  }

  // ---- 本地导入通道（2026-10-30 拍板：模型改导入制，废弃在线 OTA 依赖）----

  /// 导入期**结构校验**（预过滤，非最终裁定）：在 staging 压平后、原子替换前
  /// 跑。规则（spike 冻结前口径）：
  /// - **GGUF 魔数硬拒**（无歧义）：任一 `.gguf` 头 4 字节非 `GGUF` → 拒（坏包）。
  /// - **运行时检测**（回填 meta，不强制布局）：`genie_config.json` 在场 →
  ///   [OnDeviceRuntime.qairt]；否则有 `.gguf` → [OnDeviceRuntime.llamaCpp]；
  ///   否则 [OnDeviceRuntime.auto]（未知布局**不硬拒**——spike 实证 llama_cpp
  ///   资产布局前，避免误拒合法资产）。
  /// - **qairt 布局告警**：`tokenizer.json` / `metadata.json` 缺失仅 `[DEGRADE]`
  ///   留痕不拒——**最终裁定在 `doLoad`（build 真伪）**，导入期只省垃圾拷贝。
  /// 校验自身异常降级为 auto（不阻断，保持兼容既有 .bin 形态测试资产）。
  Future<_AssetLayout> _validateAssetLayout(Directory dir) async {
    try {
      final files = <String>[];
      await for (final e in dir.list()) {
        if (e is File) files.add(e.uri.pathSegments.last);
      }
      final lower = {for (final f in files) f.toLowerCase()};
      final ggufs = [
        for (final f in files)
          if (f.toLowerCase().endsWith('.gguf')) f
      ];
      final litertlms = [
        for (final f in files)
          if (f.toLowerCase().endsWith('.litertlm')) f
      ];
      final hasGenie = lower.contains('genie_config.json');

      for (final g in ggufs) {
        if (!await _ggufMagicOk(File('${dir.path}/$g'))) {
          return _AssetLayout(error: '$g 非有效 GGUF（头魔数不符）');
        }
      }

      String runtime;
      if (hasGenie) {
        runtime = OnDeviceRuntime.qairt;
        if (!lower.contains('tokenizer.json')) {
          debugPrint('[DEGRADE] asset layout: qairt bundle missing tokenizer.json');
        }
        if (!lower.contains('metadata.json')) {
          debugPrint('[DEGRADE] asset layout: qairt bundle missing metadata.json '
              '(qairt dispatch 强制，doLoad 将失败)');
        }
      } else if (litertlms.isNotEmpty) {
        // D-1 资产族（2026-11-01）：`.litertlm` 单文件标准化资产 → LiteRT-LM 系；
        // 装载由 Dart 侧 `kOnDeviceLiteRtLmEnabled` 闸裁定（Runner 未集成前
        // fail-fast），导入面只负责识别入册。
        runtime = OnDeviceRuntime.litertlm;
        // NPU 包 arch 校验（2026-11-02 拍板）：本机 Hexagon 代际未知（非高通/
        // 不支持）→ 显式留痕「将走 GPU 档」——不拒（GPU 档合法），防无感知
        // 回落；bundle-SoC 不匹配仍由 doLoad warmup 裁定（bundle 自身语义）。
        final arch = await OnDeviceEngineBinding().hexagonArch();
        if (arch == null) {
          debugPrint('[DEGRADE] asset layout: litertlm imported but '
              'hexagonArch unknown → NPU 档不可用（GPU 档运行）');
        }
      } else if (ggufs.isNotEmpty) {
        // GGUF 通道按首发节奏关闸（2026-11-01 拍板三闸之一）：归档夹带 GGUF
        //（无 genie_config）→ 导入期即拒，不进注册表；装载闸兜底仍在。
        return _AssetLayout(
            error: 'GGUF 通道按首发节奏关闸（llama.cpp 代码保留未开放）');
      } else {
        // 族级导入拒绝（2026-11-02 拍板）：未知布局显式拒（联发科包等不支持的
        // 运行时），非静默 auto——不认识的族不许进注册表踩装载失败。
        return _AssetLayout(error: '未知模型布局（支持 .litertlm / GenieX bundle）');
      }
      return _AssetLayout(runtime: runtime);
    } catch (e) {
      debugPrint('[DEGRADE] asset layout validate: $e');
      return const _AssetLayout();
    }
  }

  /// GGUF 文件头魔数校验：前 4 字节须为 `GGUF`（0x47 0x47 0x55 0x46）。
  Future<bool> _ggufMagicOk(File f) async {
    try {
      final raf = await f.open(mode: FileMode.read);
      try {
        await raf.setPosition(0);
        final head = <int>[0, 0, 0, 0];
        final n = await raf.readInto(head);
        return n == 4 &&
            head[0] == 0x47 &&
            head[1] == 0x47 &&
            head[2] == 0x55 &&
            head[3] == 0x46;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  // ---- modelProfile（声明式解析元数据，规格 on-device-asset-metadata.md）----

  /// 导入/安装期声明式解析元数据探测：写入 `.asset-meta.json` 的
  /// `modelProfile` 块，供各 Runner 装载期自治消费（禁中心化 token 级解析，
  /// D-3 纪律——本块只记声明式属性，不是解析逻辑的收口）。
  ///
  /// 探测策略（保守，无实证不写字段，规格 §3 溯源纪律）：
  /// - litertlm：模板归 bundle 原生（Runner 不自绘），只标 contextTokens
  ///   （Gemma3-1B 官方 bundle 规格单源 [kLitertlmContextTokens]）；终止靠
  ///   模型原生 EOS，不写 stopSequences（跨栈模板不引入）；
  /// - qairt：GenieX SDK applyChatTemplate 读资产内嵌模板，手写 fallback
  ///   家族假设 = Qwen/ChatML（ChatMLComposer UNCERTAIN 同源）——显式落盘
  ///   使假设可查；stopSequences 按家族闭合 token 推导（推导非猜测）；
  /// - GGUF（llama_cpp/auto 布局）：解析头内嵌 `tokenizer.chat_template`
  ///   KV 映射模板家族，探不出标 `unknown`；contextTokens 读
  ///   `<arch>.context_length` KV（架构前缀键单源——通用 `context_length`
  ///   键在真实工件不存在，2026-11-02 真机文件实证）。
  Future<Map<String, dynamic>?> _probeModelProfile(
      Directory dir, String runtime) async {
    final profile = <String, dynamic>{};
    if (runtime == OnDeviceRuntime.litertlm) {
      // S1 策展声明（§3.5）走 per-bundle 规格表（assets/model-specs.json，
      // 数据非代码——2026-11-03 用户拍板「通用实现禁止在代码里绑定具体模型」）：
      // 按 bundle 工件名匹配行，命中才写 contextTokens/recommendedSampling；
      // 无命中行 → 字段缺席（S2 内建缺省归目录层消费口径，不在此猜值）。
      final spec = await _matchBundleSpec(
          runtime, (await _firstLitertlm(dir))?.split('/').last);
      if (spec != null) {
        final ctx = (spec['contextTokens'] as num?)?.toInt();
        if (ctx != null) profile['contextTokens'] = ctx;
        final sampling = spec['recommendedSampling'];
        if (sampling is Map<String, dynamic>) {
          profile['recommendedSampling'] = sampling;
        }
      }
      return profile.isEmpty ? null : profile;
    }
    if (runtime == OnDeviceRuntime.qairt) {
      profile['chatTemplateFamily'] = 'qwen_chatml';
      final stops = stopSequencesForFamily('qwen_chatml');
      if (stops != null) profile['stopSequences'] = stops;
      return profile;
    }
    // llama_cpp / auto 布局按实盘文件判（防 meta runtime 与布局漂移）。
    final gguf = await _firstGguf(dir);
    if (gguf != null) {
      final probe = await _ggufProbe(gguf);
      final chatTemplate = probe?[GgufKeys.chatTemplate] as String?;
      final family = chatTemplate == null
          ? 'unknown'
          : chatTemplateFamilyOfTemplate(chatTemplate);
      profile['chatTemplateFamily'] = family;
      final stops = stopSequencesForFamily(family);
      if (stops != null) profile['stopSequences'] = stops;
      final ctx = probe?.contextLength;
      if (ctx != null) {
        profile['contextTokens'] = ctx;
      }
    }
    return profile.isEmpty ? null : profile;
  }

  /// 实盘布局 → runtime 粗判（仅 modelProfile 探测用；非装载分派语义）。
  Future<String> _runtimeOfDir(Directory dir) async {
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split('/').last.toLowerCase();
        if (name == 'genie_config.json') return OnDeviceRuntime.qairt;
        if (name.endsWith('.litertlm')) return OnDeviceRuntime.litertlm;
        if (name.endsWith('.gguf')) return OnDeviceRuntime.llamaCpp;
      }
    } catch (_) {}
    return OnDeviceRuntime.auto;
  }

  /// 模板文本 → 家族名（标记单源映射；无命中 unknown）。
  @visibleForTesting
  static String chatTemplateFamilyOfTemplate(String template) {
    if (template.contains('<|im_start|>')) return 'qwen_chatml';
    if (template.contains('<|start_header_id|>')) return 'llama3';
    if (template.contains('<start_of_turn>')) return 'gemma';
    return 'unknown';
  }

  /// 模板家族 → 闭合 token（stopSequences 推导单源，规格
  /// on-device-asset-metadata.md §2 声明区）：家族由模板内容标记判定（上方
  /// 单源映射），闭合 token 是家族固定属性——推导非猜测。unknown / null →
  /// null（字段缺席，禁猜测值）。
  /// 字面量用 \u 转义书写，与 Kotlin StopSequenceMatcher.DEFAULT 同值。
  @visibleForTesting
  static List<String>? stopSequencesForFamily(String? family) {
    switch (family) {
      case 'qwen_chatml':
        return const ['\u003c|im_end|\u003e'];
      case 'llama3':
        return const ['\u003c|eot_id|\u003e'];
      case 'gemma':
        return const ['\u003cend_of_turn\u003e'];
      default:
        return null;
    }
  }

  static Future<File?> _firstGguf(Directory dir) async {
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.gguf')) return e;
      }
    } catch (_) {}
    return null;
  }

  /// 目录内首个 .litertlm bundle 工件路径（规格表匹配用，取文件名部分）。
  static Future<String?> _firstLitertlm(Directory dir) async {
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.litertlm')) {
          return e.path;
        }
      }
    } catch (_) {}
    return null;
  }

  /// GGUF 头探测：委托单源解析器 `on_device_gguf_header.dart`（2026-11-03
  /// 收敛——本类原私有 _GgufKvReader 副本已删，双解析器是漂移温床）。探测
  /// 失败（magic/版本/结构非法/超预算）返 null，调用方落 unknown / 不写
  /// 字段，不抛异常打断导入。
  static Future<GgufHeader?> _ggufProbe(File f) async {
    try {
      return await Future(() => readGgufHeader(f));
    } on Object {
      return null;
    }
  }

  /// 测试钩子：单测喂合成头取 chat_template（公有面只暴露标量结果）。
  @visibleForTesting
  static Future<String?> ggufChatTemplate(File f) async =>
      (await _ggufProbe(f))?[GgufKeys.chatTemplate] as String?;

  /// 测试钩子：仅取架构上下文窗口。
  @visibleForTesting
  static Future<int?> ggufContextLength(File f) async =>
      (await _ggufProbe(f))?.contextLength;

  /// 在盘导入资产校验：meta 版本带导入前缀 + meta 记录的每个文件在场且
  /// 尺寸全对。sha256 不重算（导入源完整性由用户侧保证，同 [_verifyInstalled]
  /// 的廉价口径）。
  Future<bool> _isImportedVerified(Directory target) async {
    try {
      final metaFile = File('${target.path}/.asset-meta.json');
      if (!await metaFile.exists()) {
        debugPrint('[DEGRADE] imported-asset verify: meta 缺失 (${target.path})');
        return false;
      }
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final version = meta['version'] as String? ?? '';
      if (!version.startsWith(_importedVersionPrefix)) {
        debugPrint('[DEGRADE] imported-asset verify: 版本前缀不符 '
            '(version=$version, 期望 $_importedVersionPrefix*)');
        return false;
      }
      final sizes = (meta['sizes'] as Map<String, dynamic>?) ?? const {};
      if (sizes.isEmpty) {
        debugPrint('[DEGRADE] imported-asset verify: meta sizes 为空');
        return false;
      }
      for (final entry in sizes.entries) {
        final file = File('${target.path}/${entry.key}');
        if (!await file.exists()) {
          debugPrint('[DEGRADE] imported-asset verify: ${entry.key} 缺失');
          return false;
        }
        if (await file.length() != (entry.value as num).toInt()) {
          debugPrint('[DEGRADE] imported-asset verify: ${entry.key} 尺寸不符 '
              '(盘=${await file.length()} meta=${entry.value})');
          return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('[DEGRADE] imported-asset verify: $e');
      return false;
    }
  }

  /// 本地导入：用户经系统文件选择器（SAF，file_picker 复制语义）多选模型
  /// 目录下的文件后，把选中文件拷入应用私有 models/ 目标目录并写 meta。
  ///
  /// 纪律（同下载通道）：≥5GB 磁盘门禁 → `.staging-import-*` 暂存 → 逐文件
  /// 字节数核对（SAF 缓存路径 → 拷贝中断不静默）→ `_atomicSwap` 原子替换
  /// （防 `:engine` 装载中热替换 SIGBUS）。选中的点前缀隐藏文件一律忽略
  /// （防覆盖 `.asset-meta.json`）；文件名冲突（跨目录重名）整批拒绝。
  /// 驱动指纹照记——§4.8 漂移自愈对导入资产同样生效（脏删后需重新导入）。
  Future<Directory?> importFromPickedFiles(
    List<String> pickedPaths, {
    required ImportTarget target,
    void Function(AssetPullProgress progress)? onProgress,
  }) async {
    void report(AssetPullProgress p) {
      try {
        onProgress?.call(p);
      } catch (_) {}
    }
    try {
      if (pickedPaths.isEmpty) return null;
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final modelsRoot = Directory('${support.path}/models');
      final destDir = Directory('${modelsRoot.path}/${target.dirName}');

      // 展开为 (源路径, 落盘文件名)，同名校验 + 体积累计。
      final entries = <(String, String)>[];
      final names = <String>{};
      var totalBytes = 0;
      for (final path in pickedPaths) {
        final name = path.split('/').last;
        if (name.isEmpty || name.startsWith('.')) continue;
        if (!names.add(name)) {
          debugPrint('[DEGRADE] import: duplicate file name $name');
          return null;
        }
        final len = await File(path).length();
        entries.add((path, name));
        totalBytes += len;
      }
      if (entries.isEmpty) return null;
      if (!await _diskGate(totalBytes)) return null;
      // 绝对体积上限（自由导入唯一硬闸，无档位对账兜底）：超 12GB 直接拒。
      if (totalBytes > _importMaxBytes) {
        debugPrint('[DEGRADE] import size over hard ceiling: '
            '${totalBytes ~/ 1073741824}GB > ${_importMaxBytes ~/ 1073741824}GB '
            '→ refused');
        report(AssetPullProgress(
            phase: 'file',
            fileName: entries.first.$2,
            totalBytes: totalBytes,
            detail: '模型体积超出端侧上限（>${_importMaxBytes ~/ 1073741824}GB），'
                '已拒绝'));
        return null;
      }

      report(AssetPullProgress(
          phase: 'file', fileName: entries.first.$2, totalBytes: totalBytes));
      final staging = Directory(
          '${modelsRoot.path}/.staging-import-${(now ?? DateTime.now)().millisecondsSinceEpoch}');
      await staging.create(recursive: true);
      String importedRuntime = OnDeviceRuntime.auto;
      try {
        var doneBytes = 0;
        for (final (src, name) in entries) {
          final dst = File('${staging.path}/$name');
          await File(src).copy(dst.path); // dart:io File.copy = 流式，不整载内存
          if (await dst.length() != await File(src).length()) {
            debugPrint('[DEGRADE] import $name: copied size mismatch');
            return await _cleanupStaging(staging);
          }
          doneBytes += await dst.length();
          report(AssetPullProgress(
              phase: 'file',
              fileName: name,
              receivedBytes: doneBytes,
              totalBytes: totalBytes));
        }
        // 结构校验（预过滤，非最终裁定）：GGUF 魔数硬拒 + 运行时检测回填 meta。
        final layout = await _validateAssetLayout(staging);
        if (layout.error != null) {
          debugPrint('[DEGRADE] import layout: ${layout.error} → refused');
          report(AssetPullProgress(
              phase: 'file',
              fileName: entries.first.$2,
              totalBytes: totalBytes,
              detail: '资产校验失败：${layout.error}'));
          return await _cleanupStaging(staging);
        }
        // 模板可应用性黄灯（规格 on-device-asset-metadata.md §6）：不通过 =
        // 导入侧黄灯警告，不拒收（最终裁定在装载期；不做能力降级）。
        if (!await templateApplicability(staging, layout.runtime)) {
          debugPrint('[DEGRADE] import template-applicability: unverified '
              '(runtime=${layout.runtime})');
          report(AssetPullProgress(
              phase: 'file',
              fileName: entries.first.$2,
              totalBytes: totalBytes,
              detail: '模板可应用性未验证（未验证模型，装载效果待真机裁定）'));
        }
        if (totalBytes > _importWarnBytes) {
          debugPrint('[on-device] import size warn: '
              '${totalBytes ~/ 1048576}MB > ${_importWarnBytes ~/ 1048576}MB '
              '(可能内存不足，装载期内存护栏兜底)');
        }
        await _writeImportMeta(staging, entries, totalBytes,
            runtime: layout.runtime, displayName: target.displayName);
        await _atomicSwap(staging, destDir, modelsRoot);
        importedRuntime = layout.runtime;
      } catch (_) {
        await _rmdirQuiet(staging);
        rethrow;
      }
      debugPrint('[on-device] assets imported (runtime=$importedRuntime) '
          '(${entries.length} files, ${totalBytes ~/ 1048576}MB) '
          '→ ${destDir.path}');
      // 逐文件尺寸对账（S2-5 闪退换向）：目录名自拟不可信——合计 ~4.5GB+
      // 即导入误标大模型，装载期 dmabuf 对账用。
      for (final (src, name) in entries) {
        debugPrint('[on-device] import size: $name='
            '${await File(src).length()}B');
      }
      report(AssetPullProgress(
          phase: 'done',
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
          detail: 'local-import'));
      return destDir;
    } catch (e) {
      debugPrint('[DEGRADE] asset import: $e');
      return null;
    }
  }

  /// 压缩包导入（2026-10-30 增补）：单选 zip/tar/tar.gz 模型包 → archive 包
  /// 流式解压进 `.staging-archive-*`（不整载内存）→ 压平到 staging 根
  /// （嵌套目录按 basename 提升；点前缀文件删除、重名整批拒绝）→
  /// 绝对体积上限 + 结构校验 → 写 local-import meta → `_atomicSwap` 原子替换。
  /// 解压解码错误抛 ArchiveException → 外层 catch 收口 null。
  Future<Directory?> importFromArchive(
    String archivePath, {
    required ImportTarget target,
    void Function(AssetPullProgress progress)? onProgress,
  }) async {
    void report(AssetPullProgress p) {
      try {
        onProgress?.call(p);
      } catch (_) {}
    }
    Directory? staging;
    try {
      if (_archiveExtension(archivePath) == null) {
        debugPrint("[DEGRADE] archive import: unsupported archive $archivePath");
        return null;
      }
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final modelsRoot = Directory('${support.path}/models');
      final destDir = Directory('${modelsRoot.path}/${target.dirName}');
      // 解压膨胀留量：压缩包体积 ×3 作为磁盘门禁输入（模型权重压缩比有限，
      // ×3 覆盖文本类 tokenizer 包；真不足时 extractFileToDisk 亦会抛盘满）。
      if (!await _diskGate(await File(archivePath).length() * 3)) return null;

      report(const AssetPullProgress(phase: "manifest", detail: "解压中…"));
      staging = Directory(
          '${modelsRoot.path}/.staging-archive-${(now ?? DateTime.now)().millisecondsSinceEpoch}');
      await staging.create(recursive: true);
      await extractFileToDisk(archivePath, staging.path, callback: (entry) {
        if (!entry.isFile) return;
        report(AssetPullProgress(
            phase: "file", fileName: entry.name, detail: "解压中…"));
      });

      // 压平：嵌套目录文件按 basename 提升到 staging 根（:engine 装载要平铺）。
      final entries = <(String, String)>[];
      final names = <String>{};
      final pending = <Directory>[staging];
      while (pending.isNotEmpty) {
        final dir = pending.removeLast();
        await for (final entity in dir.list()) {
          if (entity is Directory) {
            pending.add(entity);
            continue;
          }
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (name.startsWith(".")) {
            await entity.delete(); // 压缩包内点前缀文件一律不入库
            continue;
          }
          if (entity.parent.path == staging.path) {
            if (!names.add(name)) {
              debugPrint("[DEGRADE] archive import: duplicate $name");
              return await _cleanupStaging(staging);
            }
            entries.add((entity.path, name));
            continue;
          }
          final dst = File("${staging.path}/$name");
          if (await dst.exists()) {
            debugPrint("[DEGRADE] archive import: duplicate $name");
            return await _cleanupStaging(staging);
          }
          await entity.rename(dst.path);
          names.add(name);
          entries.add((dst.path, name));
        }
      }
      if (entries.isEmpty) {
        debugPrint("[DEGRADE] archive import: empty archive");
        return await _cleanupStaging(staging);
      }
      var totalBytes = 0;
      for (final (src, _) in entries) {
        totalBytes += await File(src).length();
      }
      // 绝对体积上限（自由导入唯一硬闸）：超 12GB 直接拒。
      if (totalBytes > _importMaxBytes) {
        debugPrint("[DEGRADE] archive import size over hard ceiling: "
            "${totalBytes ~/ 1073741824}GB > ${_importMaxBytes ~/ 1073741824}GB");
        report(AssetPullProgress(
            phase: "file",
            fileName: entries.first.$2,
            totalBytes: totalBytes,
            detail: "模型体积超出端侧上限（>${_importMaxBytes ~/ 1073741824}GB），"
                "已拒绝"));
        return await _cleanupStaging(staging);
      }
      // 结构校验（预过滤）：GGUF 魔数硬拒 + 运行时检测回填 meta。
      final layout = await _validateAssetLayout(staging);
      if (layout.error != null) {
        debugPrint("[DEGRADE] archive import layout: ${layout.error} → refused");
        report(AssetPullProgress(
            phase: "file",
            fileName: entries.first.$2,
            totalBytes: totalBytes,
            detail: "资产校验失败：${layout.error}"));
        return await _cleanupStaging(staging);
      }
      // 模板可应用性黄灯（规格 on-device-asset-metadata.md §6）：不通过 =
      // 导入侧黄灯警告，不拒收（最终裁定在装载期；不做能力降级）。
      if (!await templateApplicability(staging, layout.runtime)) {
        debugPrint("[DEGRADE] archive import template-applicability: "
            "unverified (runtime=${layout.runtime})");
        report(AssetPullProgress(
            phase: "file",
            fileName: entries.first.$2,
            totalBytes: totalBytes,
            detail: "模板可应用性未验证（未验证模型，装载效果待真机裁定）"));
      }
      if (totalBytes > _importWarnBytes) {
        debugPrint("[on-device] archive import size warn: "
            "${totalBytes ~/ 1048576}MB > ${_importWarnBytes ~/ 1048576}MB");
      }

      await _writeImportMeta(staging, entries, totalBytes,
          runtime: layout.runtime, displayName: target.displayName);
      await _atomicSwap(staging, destDir, modelsRoot);
      staging = null; // 已原子转正，finally 不再清
      debugPrint("[on-device] assets imported from archive "
          "(runtime=${layout.runtime}) (${entries.length} files, "
          "${totalBytes ~/ 1048576}MB) -> ${destDir.path}");
      report(AssetPullProgress(
          phase: "done",
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
          detail: "local-import"));
      return destDir;
    } catch (e) {
      debugPrint("[DEGRADE] asset archive import: $e");
      return null;
    } finally {
      if (staging != null) await _rmdirQuiet(staging);
    }
  }

  /// 压缩包扩展名识别（仅收 zip/tar/tar.gz/tgz；其余 null）。
  static String? _archiveExtension(String path) {
    final lower = path.toLowerCase();
    for (final ext in [".tar.gz", ".tgz", ".tar", ".zip"]) {
      if (lower.endsWith(ext)) return ext;
    }
    return null;
  }

  Future<void> _writeImportMeta(
    Directory dir,
    List<(String, String)> entries,
    int totalBytes, {
    required String runtime,
    String? displayName,
  }) async {
    final fingerprint = await _currentFingerprint();
    final sizes = <String, int>{};
    for (final (_, name) in entries) {
      sizes[name] = await File('${dir.path}/$name').length();
    }
    // 声明式解析元数据（2026-11-02）：探测失败/空 = 字段缺席（消费方按
    // 既有内建口径走，禁臆造默认）。
    final modelProfile = await _probeModelProfile(dir, runtime);
    final meta = {
      'version': '$_importedVersionPrefix-${(now ?? DateTime.now)().millisecondsSinceEpoch}',
      'installedAt': (now ?? DateTime.now)().toIso8601String(),
      'driverFingerprint': fingerprint,
      'totalBytes': totalBytes,
      'sizes': sizes,
      // 多模型导入制（2026-10-31）：注册表据此渲染展示名 + doLoad 据此选运行时
      // 主路。runtime 由结构校验检测回填（qairt/llama_cpp/litertlm/auto）。
      'runtime': runtime,
      // D-1 资产族（2026-11-01）：backend 维度栈映射，单源 = familyOf(runtime)。
      'family': OnDeviceAssetFamily.familyOf(runtime),
      'modelProfile': ?modelProfile,
      if (displayName != null && displayName.isNotEmpty)
        'displayName': displayName,
    };
    await SequentialFileWriter(File('${dir.path}/.asset-meta.json'))
        .write(jsonEncode(meta));
  }

  Future<Directory?> _cleanupStaging(Directory staging) async {
    await _rmdirQuiet(staging);
    return null;
  }

  Future<void> _rmdirQuiet(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (e) {
      debugPrint('[DEGRADE] rmdir ${entity.path}: $e');
    }
  }
}

/// 下载进度事件（设置页「下载模型」进度显示）：phase=manifest/门禁/单文件
/// 完成/整包完成/失败；receivedBytes/totalBytes 为当前文件或整包累计。
class AssetPullProgress {
  const AssetPullProgress({
    required this.phase,
    this.fileName,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.detail,
  });

  final String phase;
  final String? fileName;
  final int receivedBytes;
  final int totalBytes;
  final String? detail;
}

class _AssetManifest {
  _AssetManifest(this.version, this.files);

  final String version;
  final List<_AssetFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
}

class _AssetFile {
  _AssetFile(this.name, this.size, this.sha256);

  final String name;
  final int size;
  final String sha256;

  factory _AssetFile.fromJson(Map<String, dynamic> json) => _AssetFile(
        json['name'] as String,
        (json['size'] as num).toInt(),
        json['sha256'] as String,
      );
}

/// 结构校验结果（文件顶层，Dart 无嵌套类）：[error] 非 null = 无歧义损坏
/// （拒）；[runtime] = 按资产布局检测出的运行时（回填 meta）。
class _AssetLayout {
  const _AssetLayout({this.error, this.runtime = OnDeviceRuntime.auto});
  final String? error;
  final String runtime;
}

/// sha256 分块转换的接收端（close 前最终 Digest 落 [value]）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
