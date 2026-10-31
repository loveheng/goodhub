import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/storage/sequential_file_writer.dart';
import 'on_device_engine_binding.dart';
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
    this.now,
  });

  /// 测试注入构造：基址/磁盘余量/驱动指纹/support 根目录全部可注入，
  /// 单测以本地 HttpServer + 临时目录全链路跑通，不触平台通道。
  @visibleForTesting
  OnDeviceAssetManager.forTest({
    String? baseUrlOverride,
    Future<int?> Function()? freeBytesProvider,
    Future<String?> Function()? fingerprintProvider,
    Future<Directory> Function()? supportDirResolver,
    DateTime Function()? now,
  }) : this._(
          baseUrlOverride: baseUrlOverride,
          freeBytesProvider: freeBytesProvider,
          fingerprintProvider: fingerprintProvider,
          supportDirResolver: supportDirResolver,
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
  Future<List<InstalledModel>> listInstalled() =>
      ModelRegistry.scan(supportDirResolver: supportDirResolver);

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

  Future<void> _writeMeta(Directory dir, _AssetManifest manifest) async {
    final fingerprint = await _currentFingerprint();
    final meta = {
      'version': manifest.version,
      'installedAt': (now ?? DateTime.now)().toIso8601String(),
      'driverFingerprint': fingerprint,
      'sizes': {for (final f in manifest.files) f.name: f.size},
      'sha256': {for (final f in manifest.files) f.name: f.sha256},
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
      } else if (ggufs.isNotEmpty) {
        runtime = OnDeviceRuntime.llamaCpp;
      } else {
        runtime = OnDeviceRuntime.auto;
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
    final meta = {
      'version': '$_importedVersionPrefix-${(now ?? DateTime.now)().millisecondsSinceEpoch}',
      'installedAt': (now ?? DateTime.now)().toIso8601String(),
      'driverFingerprint': fingerprint,
      'totalBytes': totalBytes,
      'sizes': sizes,
      // 多模型导入制（2026-10-31）：注册表据此渲染展示名 + doLoad 据此选运行时
      // 主路。runtime 由结构校验检测回填（qairt/llama_cpp/auto）。
      'runtime': runtime,
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
