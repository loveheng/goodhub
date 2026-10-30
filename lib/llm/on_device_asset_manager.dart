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

  static const String _defaultBase =
      'http://127.0.0.1:8090/qwen3_1_7b-geniex_qairt-w4a16-qualcomm_snapdragon_8_elite_for_galaxy';
  static const String _defaultDirName = 'qwen3_1_7b-geniex_qairt-w4a16';

  /// 本地导入资产的 meta 版本前缀（2026-10-30 用户裁决：模型改导入制，
  /// 废弃在线 OTA 依赖——模型体积过大无在线存储）。带此前缀的资产在
  /// [ensureAssets] 里完全跳过 manifest/网络面，尺寸校验过即用。
  static const String _importedVersionPrefix = 'local-import';

  /// 装载目标解析（§4.5 分发键经 catalog 选项承载）：显式 model（设置页
  /// 选择）优先 > 实例构造 override（测试注入）> 默认（1.7B 首发资产）。
  String _baseOf(OnDeviceModelOption? model) =>
      model?.base ?? baseUrlOverride ?? _defaultBase;

  String _dirOf(OnDeviceModelOption? model) =>
      model?.dirName ?? _defaultDirName;

  /// §4.6 双倍空间门禁（≈2.5× 1.8GB 模型体积，含解压峰值余量）。
  static const int _minFreeBytes = 5 * 1024 * 1024 * 1024;

  /// 导入内容体积与所选档位预期值的容差（±20%）：超出即判「档位错配」拒绝
  /// 导入——真机实证「1.7B 档装 4B 分片」把装载内存峰值翻倍，装载必被 LMK
  /// 打断（端侧永远装不上）。
  static const double _assetSizeTolerance = 0.2;

  /// 可注入探针（测试面）：磁盘余量 / 驱动指纹。真机走平台通道。
  final Future<int?> Function()? freeBytesProvider;
  final Future<String?> Function()? fingerprintProvider;
  final Future<Directory> Function()? supportDirResolver;
  final DateTime Function()? now;

  /// 装配入口（main.dart 启动引导 / 冒烟诊断 / 设置页共用）：幂等——已装
  /// 版本与 manifest 一致且文件尺寸全对即跳过；否则整包重下并原子替换。
  /// [model] = 装载目标（设置页选择；null = 默认 1.7B 首发资产）。
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

    final base = _baseOf(model);
    try {
      final support = await (supportDirResolver ?? getApplicationSupportDirectory)();
      final modelsRoot = Directory('${support.path}/models');
      final target = Directory('${modelsRoot.path}/${_dirOf(model)}');

      // 导入资产优先（2026-10-30 拍板：模型改导入制）：在盘且尺寸全对即
      // 直接返回，manifest 不可达/在线通道退役都不影响装载。
      if (await _isImportedVerified(target)) {
        report(const AssetPullProgress(
            phase: 'done', detail: '本地导入资产校验通过（跳过下载）'));
        return target;
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
    try {
      final support =
          await (supportDirResolver ?? getApplicationSupportDirectory)();
      final target = Directory('${support.path}/models/${_dirOf(model)}');
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
    final support =
        await (supportDirResolver ?? getApplicationSupportDirectory)();
    final target = Directory('${support.path}/models/${_dirOf(model)}');
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

  /// 在盘导入资产校验：meta 版本带导入前缀 + meta 记录的每个文件在场且
  /// 尺寸全对。sha256 不重算（导入源完整性由用户侧保证，同 [_verifyInstalled]
  /// 的廉价口径）。
  Future<bool> _isImportedVerified(Directory target) async {
    try {
      final metaFile = File('${target.path}/.asset-meta.json');
      if (!await metaFile.exists()) return false;
      final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final version = meta['version'] as String? ?? '';
      if (!version.startsWith(_importedVersionPrefix)) return false;
      final sizes = (meta['sizes'] as Map<String, dynamic>?) ?? const {};
      if (sizes.isEmpty) return false;
      for (final entry in sizes.entries) {
        final file = File('${target.path}/${entry.key}');
        if (!await file.exists()) return false;
        if (await file.length() != (entry.value as num).toInt()) return false;
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
    OnDeviceModelOption? model,
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
      final target = Directory('${modelsRoot.path}/${_dirOf(model)}');

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
      // 档位一致性校验（2026-10-30 真机实证）：所选档位 ↔ 导入内容必须同档
      // ——「1.7B 档装 4B 分片」把装载内存峰值翻倍（3.17GB 权重 + ION 瞬态
      // 击穿整机 min watermark → `:engine` 被 LMK 连杀 5 次 → 端侧永远装不上）。
      // 目录名自拟不可信 → 靠体积对账钉死（偏差超容差即拒绝）。
      final expected = model?.expectedTotalBytes;
      if (expected != null) {
        final drift = (totalBytes - expected).abs() / expected;
        if (drift > _assetSizeTolerance) {
          debugPrint('[DEGRADE] import size mismatch: dir=${_dirOf(model)} '
              'expected≈${expected ~/ 1048576}MB got=${totalBytes ~/ 1048576}MB '
              '(drift=${(drift * 100).round()}%) → refused');
          report(AssetPullProgress(
              phase: 'file',
              fileName: entries.first.$2,
              totalBytes: totalBytes,
              detail: '导入内容与所选档位不符（预期 ≈${expected ~/ 1048576}MB，'
                  '实测 ${totalBytes ~/ 1048576}MB）'));
          return null;
        }
      }

      report(AssetPullProgress(
          phase: 'file', fileName: entries.first.$2, totalBytes: totalBytes));
      final staging = Directory(
          '${modelsRoot.path}/.staging-import-${(now ?? DateTime.now)().millisecondsSinceEpoch}');
      await staging.create(recursive: true);
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
        await _writeImportMeta(staging, entries, totalBytes);
        await _atomicSwap(staging, target, modelsRoot);
      } catch (_) {
        await _rmdirQuiet(staging);
        rethrow;
      }
      debugPrint('[on-device] assets imported '
          '(${entries.length} files, ${totalBytes ~/ 1048576}MB) → ${target.path}');
      // 逐文件尺寸对账（S2-5 闪退换向）：4B@W4A16 全 bundle 预期 ~2.3GB，
      // 目录名自拟不可信——合计 ~4.5GB+ 即导入误标大模型，装载期 dmabuf 对账用。
      for (final (src, name) in entries) {
        debugPrint('[on-device] import size: $name='
            '${await File(src).length()}B');
      }
      report(AssetPullProgress(
          phase: 'done',
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
          detail: 'local-import'));
      return target;
    } catch (e) {
      debugPrint('[DEGRADE] asset import: $e');
      return null;
    }
  }

  /// 压缩包导入（2026-10-30 增补）：单选 zip/tar/tar.gz 模型包 → archive 包
  /// 流式解压进 `.staging-archive-*`（不整载内存）→ 压平到 staging 根
  /// （嵌套目录按 basename 提升；点前缀文件删除、重名整批拒绝）→
  /// 档位体积对账（同 [importFromPickedFiles] 容差）→ 写 local-import
  /// meta → `_atomicSwap` 原子替换。解压解码错误抛 ArchiveException →
  /// 外层 catch 收口 null。
  Future<Directory?> importFromArchive(
    String archivePath, {
    OnDeviceModelOption? model,
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
      final target = Directory('${modelsRoot.path}/${_dirOf(model)}');
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
      // 档位体积对账（同 importFromPickedFiles：包名/目录名自拟不可信）。
      final expected = model?.expectedTotalBytes;
      if (expected != null) {
        final drift = (totalBytes - expected).abs() / expected;
        if (drift > _assetSizeTolerance) {
          debugPrint("[DEGRADE] archive import size mismatch: "
              "dir=${_dirOf(model)} expected≈${expected ~/ 1048576}MB "
              "got=${totalBytes ~/ 1048576}MB");
          report(AssetPullProgress(
              phase: "file",
              fileName: entries.first.$2,
              totalBytes: totalBytes,
              detail: "导入内容与所选档位不符"));
          return await _cleanupStaging(staging);
        }
      }

      await _writeImportMeta(staging, entries, totalBytes);
      await _atomicSwap(staging, target, modelsRoot);
      staging = null; // 已原子转正，finally 不再清
      debugPrint("[on-device] assets imported from archive "
          "(${entries.length} files, ${totalBytes ~/ 1048576}MB) "
          "-> ${target.path}");
      report(AssetPullProgress(
          phase: "done",
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
          detail: "local-import"));
      return target;
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
      Directory dir, List<(String, String)> entries, int totalBytes) async {
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

/// sha256 分块转换的接收端（close 前最终 Digest 落 [value]）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
