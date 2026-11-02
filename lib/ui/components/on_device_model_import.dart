import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../coordinator/on_device_admin.dart';

/// 端侧模型自由导入共享流程（2026-11-02 用户拍板：导入入口从端侧模型设置段
/// 拆到资源中心；设置段保留 选择/删除 管理面）。散文件/压缩包路由 + 命名 +
/// 进度对话框 + 选择持久化 + 导入后准入探针编排——单源实现，两处入口共用
///（禁复制双源）。
abstract final class OnDeviceModelImport {
  /// 运行完整导入流：文件选择 → GGUF 关闸 → 命名 → 进度对话框 → 导入 →
  /// 选择持久化 → 准入探针。失败经 [onFlash] 明示（禁静默）。
  static Future<void> run(
    BuildContext context, {
    OnDeviceAssetManager? assetsOverride,
    void Function(String message)? onFlash,
    Future<void> Function()? onImported,
  }) async {
    final assets = assetsOverride ?? OnDeviceAdmin.assets;
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked.isEmpty) return; // 用户取消
    if (!context.mounted) return; // 文件选择器全屏遮盖跨 async gap（原设置段同款护栏）
    // 首发节奏关闸（decisions.md ADR 2026-11-01）：GGUF（llama.cpp 通路）
    // 先不放出；压缩包内 GGUF 无法在此识别，交 enable() 装载闸兜底。
    if (!kOnDeviceLlamaCppEnabled &&
        picked.any((f) => f.name.toLowerCase().endsWith('.gguf'))) {
      onFlash?.call('GGUF 模型导入暂未开放（首发从 LiteRT-LM 起步）');
      return;
    }
    final firstBase = picked.first.name.split('/').last;
    final suggested = firstBase.replaceFirst(
        RegExp(r'\.(gguf|zip|tar\.gz|tgz|tar|bin)$', caseSensitive: false), '');
    final name = await _promptName(context, suggested.isNotEmpty ? suggested : 'model');
    if (name == null || name.trim().isEmpty) return;
    if (!context.mounted) return; // 命名对话框跨 async gap
    final installed = await assets.listInstalled();
    if (!context.mounted) return;
    final dirName = _uniqueDirName(
        name.trim(), <String>{for (final m in installed) m.dirName});
    final paths = picked.where((f) => f.path != null).map((f) => f.path!).toList();
    final ok = await _import(
      context,
      assets,
      paths: paths,
      target: ImportTarget(dirName: dirName, displayName: name.trim()),
      onFlash: onFlash,
    );
    if (!ok) return;
    // 导入后准入探针（DispatchProfile 设计稿 §3）：后台编排不挡 UI。
    OnDeviceAdmin.probeAdmission(dirName);
    await onImported?.call();
    onFlash?.call('$name 已导入，首次使用端侧时自动加载');
  }

  static Future<String?> _promptName(BuildContext context, String suggested) {
    final ctrl = TextEditingController(text: suggested);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入模型'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '模型名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('导入')),
        ],
      ),
    );
    // 不在此处 dispose [ctrl]：pop 返回时退出动画仍在跑，TextField 仍引用
    // controller——立即 dispose 是同类树生命周期错位（原设置段同注释惯例）。
  }

  /// 由展示名生成唯一落盘目录名（slug 化 + 撞名自增），不与已装模型冲突。
  static String _uniqueDirName(String name, Set<String> taken) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'model' : slug;
    var candidate = base;
    var i = 2;
    while (taken.contains(candidate)) {
      candidate = '$base-$i';
      i++;
    }
    return candidate;
  }

  /// 导入执行：散文件/压缩包路由 + 进度对话框（不可关）+ 失败 flash 明示。
  static Future<bool> _import(
    BuildContext context,
    OnDeviceAssetManager assets, {
    required List<String> paths,
    required ImportTarget target,
    void Function(String message)? onFlash,
  }) async {
    final progress = ValueNotifier<String>('准备导入…');
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (_, text, _) => AlertDialog(
          title: const Text('导入端侧模型'),
          content: Row(children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 14),
            Expanded(child: Text(text)),
          ]),
        ),
      ),
    ));
    try {
      // 单选压缩包（zip/tar/tar.gz）→ 解压导入通道；否则按散文件多选导入。
      final lowerSingle = paths.length == 1 ? paths.single.toLowerCase() : null;
      final isArchive = lowerSingle != null &&
          (lowerSingle.endsWith('.zip') ||
              lowerSingle.endsWith('.tar') ||
              lowerSingle.endsWith('.tar.gz') ||
              lowerSingle.endsWith('.tgz'));
      void onProgress(AssetPullProgress p) {
        switch (p.phase) {
          case 'file':
            final pct =
                p.totalBytes > 0 ? (p.receivedBytes * 100 ~/ p.totalBytes) : 0;
            progress.value =
                '导入中 $pct%（${p.receivedBytes ~/ 1048576}/${p.totalBytes ~/ 1048576}MB）';
          case 'done':
            progress.value = '导入完成';
          default:
            progress.value = p.detail ?? '处理中…';
        }
      }

      final dir = isArchive
          ? await assets.importFromArchive(paths.single,
              target: target, onProgress: onProgress)
          : await assets.importFromPickedFiles(paths,
              target: target, onProgress: onProgress);
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (dir == null) {
        onFlash?.call('导入失败（磁盘门禁/文件读取/重名冲突/资产校验），见日志');
        return false;
      }
      await OnDeviceAdmin.selectModel(target.dirName);
      return true;
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      onFlash?.call('导入失败：$e');
      return false;
    }
  }
}
