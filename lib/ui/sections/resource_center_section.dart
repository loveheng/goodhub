/// 设置页 · 资源中心段（resource-center M1-T2）：本地文件库管理面。
///
/// 规格 SSOT：docs/design/resource-center.md。职责：
/// - 消费 ResourceStore 快照（清单列表 + 占用展示 RC5）；启动/进入段触发
///   `reconcileOrphans`（孤儿 >2h + `cacheDir/external` 临时件 >24h）；
/// - 导入（file_picker 系统选择器 → 内核 import，text-only/10MB 拒收文案
///   由内核 ResourceStoreException 透出）、改名、删除、外部打开（RC6：
///   `prepareExternalOpen` 唯一临时副本 → [openExternalPath] 唤起系统应用，
///   零内建查看器）；
/// - 注入位（§8.1 范式）：[storeOverride]/[cachePathOverride]/[externalOpenerOverride]/
///   [filePickerOverride] 供测试假件；生产装配在段内（path_provider，
///   CowSection 同款先例）；
/// - 初始化失败置**面板级**错误态（ux-hardening P0-3：Rose + 重试），
///   不打死整页；操作失败走 [onFlash]（页面级 toast 口径）。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/external_open.dart';
import '../../app/service_directory.dart';
import '../../resources/resource_store.dart';
import '../tokens/console_tokens.dart';

/// 字节量展示（RC5 占用 / 条目副标题 / picker 共用）。
String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 附件选择结果（窗口层只持此 record，不触 resources 域类型）。
///
/// [collected] = 本次是否**新收集入库**（直选路径）：
/// true = 条目由本次选择顺带沉淀，宿主须明示并提供「撤销」；
/// false = 复选既有条目，撤销只移出待发项，**不得删库**。
typedef PickedResource = ({String id, String name, bool collected});

/// 附件选择 sheet（M1-T3；2026-10-19 升级为「选择即收集」）。
///
/// 供 chat_page 附件入口调用——本文件已在 ui→resources 直连白名单，选择结果
/// 以 record [PickedResource] 返回，调用方零 resources 域类型依赖。
/// 返回 null = 用户取消。
///
/// **两条路径合流（选择即收集，而非先收集才可选）**：
/// - 首项「从系统选择…」：系统文件选择器 → 经 [ResourceStore.import] 校验闸门
///   入库 → 直接作为本次附件返回（消「先导入才能用」的硬门槛）；
/// - 下方库列表：复用已收集条目（RC6 口径：选资源进对话，非内建查看）。
///
/// **闸门不旁路**：导入失败（too_large / not_text / io）一律在 sheet 内明示
/// 结构化文案，不为「快捷」跳过校验——否则原文件被改/删会造成会话引用漂移，
/// 且击穿一期「文本类 + 单文件 10MB + 复制入库隔离」边界。
Future<PickedResource?> showResourcePickerSheet(
  BuildContext context, {
  ResourceStore? storeOverride,
  Future<String?> Function()? filePickerOverride,
}) async {
  // 单实例（ServiceDirectory）：禁每次调用新建 store + 读盘一遍。
  final store = storeOverride ?? await resourceStore();
  if (!context.mounted) return null;
  final t = consoleTokens(context);
  var busy = false;
  String? error;
  return showModalBottomSheet<PickedResource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> pickFromSystem() async {
            if (busy) return;
            setSheet(() {
              busy = true;
              error = null;
            });
            try {
              final path = await (filePickerOverride ?? _pickSystemFile)();
              if (path == null || !ctx.mounted) {
                setSheet(() => busy = false);
                return;
              }
              final result = await store.import(path);
              // 等清单落盘再返回：调用方拿到 id 时库内已可查（管理页/下次
              // picker 必然可见），避免「返回了但清单还没写完」的窗口。
              await store.ioDrained;
              if (!ctx.mounted) return;
              // collected = 本次**新**入库：命中同内容复用时不再提示「已收入」，
              // 也不提供撤销（撤销 = 删本次收集；复选既有条目不属收集）。
              Navigator.of(ctx).pop((
                id: result.entry.id,
                name: result.entry.name,
                collected: !result.reused,
              ));
            } on ResourceStoreException catch (e) {
              if (!ctx.mounted) return;
              setSheet(() {
                busy = false;
                error = '${e.message}${e.hint == null ? '' : '（${e.hint}）'}';
              });
            } on Object catch (e) {
              if (!ctx.mounted) return;
              setSheet(() {
                busy = false;
                error = '选择失败: $e';
              });
            }
          }

          return ListView(
            shrinkWrap: true,
            children: [
              // 直选路径：选了就用，顺带入库（选择即收集）。
              ListTile(
                key: const ValueKey('pick-system'),
                dense: true,
                leading: const Icon(Icons.file_open_outlined),
                title: const Text('从系统选择…'),
                subtitle: const Text('立即附加本次发送，并收入资源中心供下次复用'),
                enabled: !busy,
                onTap: () => unawaited(pickFromSystem()),
              ),
              if (error != null)
                Padding(
                  key: const ValueKey('pick-error'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    '⚠ $error',
                    style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
                  ),
                ),
              const Divider(height: 1),
              if (store.entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '资源中心暂无资源——可直接点上方「从系统选择…」。',
                    style: TextStyle(
                      fontSize: Fsz.body,
                      color: t.terminalMuted,
                    ),
                  ),
                )
              else
                for (final e in store.entries)
                  ListTile(
                    key: ValueKey('pick-${e.id}'),
                    dense: true,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(
                      e.name,
                      style: const TextStyle(fontSize: Fsz.body),
                    ),
                    subtitle: Text(
                      '${_fmtBytes(e.sizeBytes)} · ${e.headPreview}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Fsz.telemetry,
                        color: t.terminalMuted,
                      ),
                    ),
                    onTap: () =>
                        Navigator.of(ctx)
                            .pop((id: e.id, name: e.name, collected: false)),
                  ),
            ],
          );
        },
      ),
    ),
  );
}

/// 系统文件选择器（生产路径；file_picker 13.x 起为静态 API）。
///
/// 取消返回 null。选择结果**必须**经 [ResourceStore.import] 入库后再使用，
/// 不得直接持原路径注入会话。
Future<String?> _pickSystemFile() async {
  final picked = await FilePicker.pickFile(type: FileType.any);
  return picked?.path;
}

/// 撤销「选择即收集」的入库副作用：删除本次收集入册的条目（幂等）。
///
/// 窗口层经此调用——本文件在 ui→resources 直连白名单内，chat_page 仍零
/// resources 域依赖。**仅对 collected=true 的条目调用**：从库里复选的既有
/// 资源不属本次收集，撤销不得删库。删后会话内句柄读返回结构化 isError
/// （`not_found`，规格 §4）。
Future<void> undoResourceCollect(String id) async =>
    (await resourceStore()).delete(id);

/// 段 widget：注入位见类注释。
class ResourceCenterSection extends StatefulWidget {
  const ResourceCenterSection({
    super.key,
    this.storeOverride,
    this.cachePathOverride,
    this.externalOpenerOverride,
    this.filePickerOverride,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  /// 测试注入位；null = 生产路径（应用支持目录 resource_center 子目录）。
  final ResourceStore? storeOverride;

  /// 测试注入位；null = 生产路径（应用缓存目录，external 临时件挂其下）。
  final String? cachePathOverride;

  /// 测试注入位；null = 生产路径（[openExternalPath]，lib/app 平台收敛件）。
  final Future<void> Function(String path)? externalOpenerOverride;

  /// 测试注入位；null = 生产路径（file_picker 系统选择器）。返回 null = 用户取消。
  final Future<String?> Function()? filePickerOverride;

  final void Function(String message) onFlash;

  /// 面板级错误态（ux-hardening P0-3 口径：Rose 文案 + 重试入口）。
  final Widget Function(
    ConsoleTokens t,
    String message,
    VoidCallback onRetry, {
    ValueKey<String>? key,
  })
  errorRowBuilder;

  @override
  State<ResourceCenterSection> createState() => _ResourceCenterSectionState();
}

class _ResourceCenterSectionState extends State<ResourceCenterSection>
    with AutomaticKeepAliveClientMixin {
  /// ListView 懒构建滚出视口会销毁重建段 State（清单/错误态丢失）——段一律
  /// 申请 keepAlive（window-slim P1-A 口径，settings_sections_keepalive_test 闸）。
  @override
  bool get wantKeepAlive => true;

  ResourceStore? _store;
  List<ResourceEntry> _entries = const [];
  String _cachePath = '';
  int _reconcileRemoved = 0;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      // 注入位优先（测试假件环境无平台插件，严禁触 path_provider）；
      // 生产路径才走 path_provider 装配（CowSection 同款先例）。
      if (widget.storeOverride != null) {
        _store = widget.storeOverride;
        await _store!.load();
      } else {
        // 单实例（ServiceDirectory）：与 picker sheet 共享同一 store——
        // 禁各自 underSupportDir 新造（规格 §4 并发纪律）。
        _store = await resourceStore();
      }
      final store = _store!;
      // 缓存路径**先判注入位再取平台路径**：否则纯 Dart 环境（无插件）
      // 即便传了 override 也会因 getTemporaryDirectory 抛异常而落错误态。
      final cachePath =
          widget.cachePathOverride ?? (await getTemporaryDirectory()).path;
      if (!mounted) return;
      setState(() {
        _store = store;
        _cachePath = cachePath;
        _entries = store.entries;
        _error = null;
      });
      // 孤儿对账（启动/进入段触发，后台不阻断渲染）：清完有产出则刷新清单/占用。
      unawaited(
        store.reconcileOrphans(extraDirs: ['$_cachePath/external']).then((
          removed,
        ) {
          if (removed > 0 && mounted) {
            setState(() {
              _reconcileRemoved = removed;
              _entries = store.entries;
            });
          }
        }),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '资源库读取失败: $e');
    }
  }

  int get _totalBytes => _entries.fold(0, (sum, e) => sum + e.sizeBytes);

  Future<void> _reload() async {
    final store = _store;
    if (store == null) return;
    await store.load();
    if (!mounted) return;
    setState(() => _entries = store.entries);
  }

  Future<void> _importFile() async {
    if (_busy) return;
    final store = _store;
    if (store == null) return;
    final pick = widget.filePickerOverride ?? _pickFile;
    setState(() => _busy = true);
    try {
      final path = await pick();
      if (path == null) return; // 用户取消。
      final result = await store.import(path);
      await _reload();
      // 复用命中 = 该内容已在册（改名产生的「同名不同内容」不在此列）。
      widget.onFlash(
        result.reused
            ? '✓ 内容已在资源中心：《${result.entry.name}》'
            : '✓ 已导入：${result.entry.name}',
      );
    } on ResourceStoreException catch (e) {
      widget.onFlash(
        '⚠ 导入失败：${e.message}${e.hint == null ? '' : '（${e.hint}）'}',
      );
    } on Object catch (e) {
      widget.onFlash('⚠ 导入失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 生产路径 = 系统文件选择器（与 picker sheet 共用，禁两处各写一份）。
  Future<String?> _pickFile() => _pickSystemFile();

  Future<void> _rename(ResourceEntry entry) async {
    final store = _store;
    if (store == null) return;
    final ctrl = TextEditingController(text: entry.name);
    // A10（review-fix-2026-10）：弹窗作用域 controller 用完即 dispose（弹窗
    // 关闭路径含取消/确定/点外部，finally 兜底）。
    try {
      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重命名资源'),
          content: TextField(controller: ctrl, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (newName == null || !mounted) return;
      try {
        await store.rename(entry.id, newName);
        await _reload();
        widget.onFlash('✓ 已重命名');
      } on ResourceStoreException catch (e) {
        widget.onFlash('⚠ 重命名失败：${e.message}');
      }
    } finally {
      ctrl.dispose(); // A10：弹窗关闭（取消/确定/点外部）后必释放
    }
  }

  Future<void> _delete(ResourceEntry entry) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除资源'),
        content: Text('确定删除「${entry.name}」？会话内已注入的附件引用将失效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await store.delete(entry.id);
      await _reload();
      widget.onFlash('✓ 已删除：${entry.name}');
    } on Object catch (e) {
      widget.onFlash('⚠ 删除失败: $e');
    }
  }

  Future<void> _openExternal(ResourceEntry entry) async {
    final store = _store;
    if (store == null) return;
    final open = widget.externalOpenerOverride ?? openExternalPath;
    try {
      final path = await store.prepareExternalOpen(
        entry.id,
        cachePath: _cachePath,
      );
      await open(path);
      widget.onFlash('✓ 已唤起系统应用打开：${entry.name}');
    } on ResourceStoreException catch (e) {
      widget.onFlash('⚠ 打开失败：${e.message}');
    } on Object catch (e) {
      widget.onFlash('⚠ 打开失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('资源中心', style: TextStyle(fontSize: Fsz.listPrimary)),
            const Spacer(),
            Text(
              '${_entries.length} 项 · 已占用 ${_fmtBytes(_totalBytes)}',
              style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
            ),
            IconButton(
              key: const ValueKey('resource-import'),
              tooltip: '导入文本文件',
              onPressed: _busy ? null : _importFile,
              // 图标分化（挂载点复盘 #12）：原用 Icons.add 与 composer 左端
              // 「+」挂载菜单同形，而此处语义 = 上传入库。
              icon: const Icon(Icons.upload_file_outlined, size: 20),
            ),
          ],
        ),
        if (_reconcileRemoved > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '已清理 $_reconcileRemoved 个失效临时/孤儿文件',
              style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
            ),
          ),
        if (_error != null)
          widget.errorRowBuilder(
            t,
            _error!,
            _bootstrap,
            key: const ValueKey('resource-error'),
          ),
        if (_store != null && _entries.isEmpty && _error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '暂无资源。点右上 + 导入文本文件（txt/md/json/csv 等，≤10MB）。',
              style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
            ),
          ),
        for (final e in _entries)
          ListTile(
            key: ValueKey('resource-${e.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(e.name, style: const TextStyle(fontSize: Fsz.body)),
            subtitle: Text(
              '${_fmtBytes(e.sizeBytes)} · ${e.headPreview}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('resource-open-${e.id}'),
                  tooltip: '用系统应用打开',
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () => unawaited(_openExternal(e)),
                ),
                IconButton(
                  key: ValueKey('resource-rename-${e.id}'),
                  tooltip: '重命名',
                  icon: const Icon(Icons.edit, size: 18),
                  onPressed: () => unawaited(_rename(e)),
                ),
                IconButton(
                  key: ValueKey('resource-delete-${e.id}'),
                  tooltip: '删除',
                  icon: Icon(Icons.delete_outline, size: 18, color: t.danger),
                  onPressed: () => unawaited(_delete(e)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
