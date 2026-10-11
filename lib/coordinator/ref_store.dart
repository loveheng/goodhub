/// $ref 暂存池内核（Ref Store，M2.5-T3）。
/// 规格 SSOT：architecture.md §9（Ref Store Specification）+ M2.5 施工设计
/// docs/design/m2-5-skill-refstore.md §1.3/§5。
///
/// - 介质（三轮评审裁撤 SQLite）：内存 Map + >1MB 大 Payload 落 cacheDir 临时
///   文件（写失败 fail-fast 上抛，禁静默降级——池写失败 = 工具输出丢失）；
/// - 作用域：`$ref:<server>:<id>` 与单次 Agent Session 绑定，Session 结束即焚
///   （[expireAll]）；全局兜底 TTL 30 分钟（[gc] 运行期联动删 tmp 文件——C-3：
///   Android 常驻进程长期不冷启动时仅靠启动清扫不够）；
/// - 会话崩溃后下次启动全量清池（[sweepStartupOrphans] 幂等清扫，挂启动流程——
///   C-3 评审定案：全量清空比 mtime 甄别更彻底且更简单，进程死即无主孤儿）；
/// - 句柄携带来源 Server 绑定（跨源校验与注水拦截 = T4 消费）；C-2 定案：查无
///   此 ref → read 返回 null，调用方立即 isError 回填，禁挂起等待。
/// 暂存池只管「跨 App 写管道的参数传引用」，只读注入走 Resources（§12 正交）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

/// 单条引用元数据 + 载荷（≤[RefStore.inlineMaxBytes] 内存驻留，超限落盘）。
class RefEntry {
  const RefEntry({
    required this.serverId,
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.sizeBytes,
    required this.preview,
    this.inlinePayload,
    this.filePath,
    this.resourceUri,
  }) : assert(inlinePayload != null || filePath != null);

  /// 来源 Server 绑定（跨源联合授权卡的校验依据，T4 消费）。
  final String serverId;
  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// 载荷字节数（utf8 口径）。
  final int sizeBytes;

  /// 展示摘要（标题+前 N 行截断）——注水 L2 联合授权卡消费，禁盲签（§9）。
  final String preview;

  /// ≤inlineMaxBytes 时内存驻留；超限落 [filePath]（二者互斥恰一）。
  final String? inlinePayload;
  final String? filePath;

  /// 合流命名（architecture §12）：载荷来自 resources/read 时记录其
  /// `goodshare://items/{uuid}`——$ref 元数据可指向 Resource URI，正交合流。
  final String? resourceUri;

  String get handle => refHandle(serverId, id);
}

/// 句柄格式：`$ref:<serverId>:<id>`（id 由本池生成，不含冒号——多段即非法）。
String refHandle(String serverId, String id) => '\$ref:$serverId:$id';

/// 句柄解析：合法返回 (serverId, id)；非法返回 null（调用方按「查无此 ref」
/// 处理——C-2：立即 isError 回填，禁挂起等待）。
({String serverId, String id})? parseRefHandle(String handle) {
  if (!handle.startsWith(r'$ref:')) return null;
  final parts = handle.substring(5).split(':');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return (serverId: parts[0], id: parts[1]);
}

/// 生成预览摘要：首行当标题 + 前 [maxLines] 行、总长 [maxChars] 封顶。
String refPreview(String payload, {int maxLines = 5, int maxChars = 300}) {
  final lines = payload.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return '（空载荷）';
  final taken = lines.take(maxLines).join('\n');
  return taken.length <= maxChars ? taken : '${taken.substring(0, maxChars)}…';
}

class RefStore {
  RefStore({
    required this.cacheDir,
    this.ttl = const Duration(minutes: 30),
    this.inlineMaxBytes = 1 << 20,
    this.gcInterval = const Duration(seconds: 30),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _random = Random.secure() {
    if (gcInterval != null) {
      _gcTimer = Timer.periodic(gcInterval!, (_) => gc());
    }
  }

  /// cacheDir（App 沙盒临时目录）——大 Payload 落盘点与启动清扫扫描域。
  final Directory cacheDir;
  final Duration ttl;
  final int inlineMaxBytes;

  /// 运行期 TTL GC 周期；null = 不内置定时器（测试或外驱模式），gc() 仍可手动调。
  final Duration? gcInterval;
  final DateTime Function() _clock;
  final Random _random;
  Timer? _gcTimer;
  final Map<String, RefEntry> _entries = {};

  static const _filePrefix = 'ref_';
  static const _fileSuffix = '.tmp';

  int get length => _entries.length;
  List<RefEntry> list() => List.unmodifiable(_entries.values);

  /// 存入载荷，返回 `$ref` 句柄。utf8 字节 >inlineMaxBytes 落盘（fail-fast，
  /// 写失败上抛）——字节口径必须真 utf8（CJK 的 UTF-16 单元数低估 3 倍，会让
  /// 大载荷滞留内存，违背「>1MB 落盘」的内存压力控制意图）。
  Future<String> put({
    required String serverId,
    required String payload,
    DateTime? expiresAt,
    String? resourceUri,
  }) async {
    if (serverId.isEmpty) throw ArgumentError('serverId 不能为空');
    final id = _newId();
    final bytes = utf8.encode(payload);
    final entry = bytes.length > inlineMaxBytes
        ? await _spillToDisk(serverId, id, bytes,
            expiresAt: expiresAt, resourceUri: resourceUri)
        : RefEntry(
            serverId: serverId,
            id: id,
            createdAt: _clock(),
            expiresAt: expiresAt ?? _clock().add(ttl),
            sizeBytes: bytes.length,
            preview: refPreview(payload),
            inlinePayload: payload,
            resourceUri: resourceUri,
          );
    _entries[id] = entry;
    return entry.handle;
  }

  /// 读载荷（内存或回读文件）；句柄非法/查无/已过期 → null（C-2 语义，不抛）。
  Future<String?> read(String handle) async {
    final parsed = parseRefHandle(handle);
    if (parsed == null) return null;
    final entry = _entries[parsed.id];
    if (entry == null || entry.serverId != parsed.serverId) return null;
    if (_isExpired(entry)) {
      await gc();
      return null;
    }
    final path = entry.filePath;
    if (path == null) return entry.inlinePayload;
    final file = File(path);
    if (!await file.exists()) {
      // UNCERTAIN: 文件在 TTL 内丢失（用户清缓存/外部清理）——按查无处理回 null，
      // 走 C-2 isError 回填轨；高频复现再评估重建通道。
      debugPrint('[DEGRADE] ref-store: spilled file missing mid-TTL: $path');
      _entries.remove(parsed.id);
      return null;
    }
    return file.readAsString();
  }

  /// Session 结束即焚：全清内存 + 本池落盘文件（幂等）。
  Future<void> expireAll() async {
    final ids = List.of(_entries.keys);
    _entries.clear();
    for (final id in ids) {
      await _deleteFileOf(id);
    }
  }

  /// 运行期 TTL GC：过期条目内存删 + tmp 文件同删（C-3 联动口径）。
  Future<void> gc() async {
    final expired = [
      for (final e in _entries.values)
        if (_isExpired(e)) e.id,
    ];
    for (final id in expired) {
      _entries.remove(id);
      await _deleteFileOf(id);
    }
  }

  /// 过期判定统一走注入时钟（测试假时钟可控；严禁 DateTime.now 散布）。
  bool _isExpired(RefEntry e) => _clock().isAfter(e.expiresAt);

  /// 启动幂等清池（挂 App 冷启动流程）：扫 cacheDir 删除全部 `ref_*.tmp`
  /// 孤儿文件——进程被杀（OOM/系统清理）后 TTL GC 停摆的兜底；无关文件不碰。
  Future<void> sweepStartupOrphans() async {
    if (!await cacheDir.exists()) return;
    await for (final f in cacheDir.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (name.startsWith(_filePrefix) && name.endsWith(_fileSuffix)) {
        try {
          await f.delete();
        } catch (e) {
          // DEGRADE: 单文件删除失败（已被并发清理/权限）不阻断清扫，留痕。
          debugPrint('[DEGRADE] ref-store: orphan sweep failed for $name: $e');
        }
      }
    }
  }

  /// 释放内置 GC 定时器（接线层 dispose 时调用；池数据不因此清除）。
  void dispose() {
    _gcTimer?.cancel();
    _gcTimer = null;
  }

  Future<RefEntry> _spillToDisk(
    String serverId,
    String id,
    List<int> bytes, {
    DateTime? expiresAt,
    String? resourceUri,
  }) async {
    await cacheDir.create(recursive: true);
    final file = File('${cacheDir.path}/$_filePrefix$id$_fileSuffix');
    await file.writeAsBytes(bytes, flush: true);
    return RefEntry(
      serverId: serverId,
      id: id,
      createdAt: _clock(),
      expiresAt: expiresAt ?? _clock().add(ttl),
      sizeBytes: bytes.length,
      preview: refPreview(utf8.decode(bytes)),
      filePath: file.path,
      resourceUri: resourceUri,
    );
  }

  Future<void> _deleteFileOf(String id) async {
    final file = File('${cacheDir.path}/$_filePrefix$id$_fileSuffix');
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      // DEGRADE: 单文件删除失败不阻断清池（下次启动清扫兜底），留痕。
      debugPrint('[DEGRADE] ref-store: file delete failed for $id: $e');
    }
  }

  /// 128-bit 安全随机 hex（无 uuid 依赖；id 只需池内唯一 + 不含冒号）。
  String _newId() =>
      List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
}
