/// 资源中心内核（ResourceStore，resource-center M1-T1）。
///
/// 规格 SSOT：docs/design/resource-center.md（本地文件库一期）。
///
/// - 定位：用户资产库（跨会话持久）——区别于 `$ref` 暂存池（会话即焚 +
///   TTL 30min，`coordinator/ref_store.dart`）；资源被注入会话时由装配位
///   put 进 ref 池获得句柄，`resourceUri` 指回 `local://resource/<uuid>`，
///   合流不合并；
/// - 存储：清单 = 单文件 JSON + [SequentialFileWriter] 原子重写（互斥粒度 =
///   文件路径，同路径跨实例串行安全）；文件实体 = 库内 uuid 命名（防用户
///   原始文件名冲突/路径注入），导入即全量复制（后续编辑原文件不影响库内
///   副本，UI 侧明示）；
/// - 边界（一期拍板）：仅文本类（utf8 严格解码，decode 失败即拒）；单文件
///   上限 10MB（超限即拒）；总配额暂不设；
/// - 错误契约（§5.4）：领域异常 [ResourceStoreException]，`code` 机器可读 +
///   可纠正分支带 `hint`，禁底层 IO 异常裸漏；
/// - 损坏清单 → 空库 + DEGRADE 留痕（宁空勿炸，TaskConsumeLedger 同口径；
///   非数据面读失败降级，见 §4.2——清单可由库内孤儿文件对账重沉淀）。
///
/// 纯 Dart 内核（§8.4-2）：零 `package:flutter` import；生命周期层级 =
/// 应用级（§8.4-1，随进程存亡，装配入口 `underSupportDir` factory）。
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/storage/sequential_file_writer.dart';

/// 单文件大小上限（一期拍板 RC1 = 10MB）。
const int kResourceMaxFileBytes = 10 * 1024 * 1024;

/// 工具读窗口默认值（RC4 拍板 = 64KB；防大文件整读击穿模型上下文）。
const int kResourceReadWindowBytes = 64 * 1024;

/// 资源库领域异常（§5.4：code 机器可读，可纠正分支带 hint）。
class ResourceStoreException implements Exception {
  const ResourceStoreException(this.code, this.message, {this.hint});

  /// `not_found`（id 无此资源）/ `too_large`（超 [kResourceMaxFileBytes]）/
  /// `not_text`（utf8 严格解码失败，一期仅收文本类）/ `io`（复制/落盘失败）。
  final String code;
  final String message;

  /// 下一步该做什么（模型据此向用户解释）。
  final String? hint;

  @override
  String toString() => 'ResourceStoreException($code): $message';
}

/// 导入结果：`entry` = 库内条目，`reused` = 本次是否命中**同内容复用**。
///
/// 复用时不新增副本、不写清单（一期纯文本库，同内容多副本只会虚增 RC5
/// 「已占用」并让清单出现重复条目）；宿主据此区分提示文案与撤销语义
/// ——**复用条目不提供撤销**（撤销=删本次收集，复选既有条目不属收集）。
typedef ResourceImportResult = ({ResourceEntry entry, bool reused});

/// 资源清单条目（不可变，§2.2）。
class ResourceEntry {
  const ResourceEntry({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.importedAtMs,
    this.headPreview = '',
    this.contentHash = '',
  });

  /// 库内 id（随机 hex 16 字节）；文件实体名 = `<id>`，清单键。
  final String id;

  /// 展示名（导入时用户可见文件名；rename 仅改此字段）。
  final String name;
  final int sizeBytes;
  final int importedAtMs;

  /// 摘要行（导入时静态截取：首个非空行前 200 字符，随清单持久化）。
  /// 注入会话的元信息字段——杜绝 LLM 生成摘要（规格 §2 headPreview）。
  final String headPreview;

  /// 内容哈希（sha256，字节级）——**同内容复用判据**（挂载点复盘 #2）：
  /// 直选路径下次选到相同内容不再落副本，避免重复选择污染清单与虚增
  /// 已占用空间（RC5 展示口径）。空串 = 历史数据（无哈希，永不参与复用）。
  final String contentHash;

  /// 注入会话时的资源 URI（ref_store 合流命名）。
  String get resourceUri => 'local://resource/$id';

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'size': sizeBytes,
        'imported_at_ms': importedAtMs,
        'head_preview': headPreview,
        'content_hash': contentHash,
      };

  static ResourceEntry? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final size = raw['size'];
    final at = raw['imported_at_ms'];
    if (id is! String || name is! String || size is! int || at is! int) {
      return null;
    }
    final preview = raw['head_preview'];
    final hash = raw['content_hash'];
    return ResourceEntry(
      id: id,
      name: name,
      sizeBytes: size,
      importedAtMs: at,
      headPreview: preview is String ? preview : '',
      contentHash: hash is String ? hash : '',
    );
  }
}

/// 资源中心内核：导入 / 清单 / 读全文 / 改名 / 删除。
class ResourceStore {
  ResourceStore({required this.dir, this.maxFileBytes = kResourceMaxFileBytes});

  final Directory dir;

  /// 单文件上限（测试注入小阈值用）。
  final int maxFileBytes;

  /// 生产装配：应用支持目录下 `resource_center` 子目录。
  factory ResourceStore.underSupportDir(String supportPath, {int? maxFileBytes}) =>
      ResourceStore(
        dir: Directory('$supportPath/resource_center'),
        maxFileBytes: maxFileBytes ?? kResourceMaxFileBytes,
      );

  File get _manifestFile => File('${dir.path}/manifest.json');

  final List<ResourceEntry> _entries = <ResourceEntry>[];
  bool _loaded = false;

  /// 全部资源（导入序，最新在末尾）。
  List<ResourceEntry> get entries => List.unmodifiable(_entries);

  ResourceEntry? byId(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 按内容哈希查既有条目（未命中返 null）——导入前判重。
  ///
  /// 空哈希（历史数据）永不参与复用：`''` 不视为有效键，避免早于判重特性
  /// 落库的条目互相误判为同内容。
  ResourceEntry? entryByContentHash(String hash) {
    if (hash.isEmpty) return null;
    for (final e in _entries) {
      if (e.contentHash == hash) return e;
    }
    return null;
  }

  /// 读盘（幂等；损坏 → 空库 + DEGRADE 留痕）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await _manifestFile.exists()) return;
      final decoded = jsonDecode(await _manifestFile.readAsString());
      if (decoded is! Map) throw const FormatException('manifest root not object');
      final raw = decoded['resources'];
      // 以盘为准：装载前清空内存（load 可能在内存态已变更后被调——如管理页
      // 重进/reload，不清则清单条目重复、ListTile 重复 ValueKey 即 build 崩）。
      _entries.clear();
      if (raw is List) {
        for (final r in raw) {
          final e = ResourceEntry.parse(r);
          if (e != null) _entries.add(e);
        }
      }
    } on Object catch (e) {
      // 宁空勿炸（清单损坏可由库内文件对账重沉淀）；非阻断启动。
      developer.log('[DEGRADE] resource-store load: $e', name: 'resource_center');
      _entries.clear();
    }
  }

  /// 导入：复制 [sourcePath] 文件入库并登记清单，返回导入结果。
  ///
  /// 校验顺序：存在性 → 大小上限 → utf8 严格解码（一期仅文本类，§4.3
  /// fail-fast 拒绝并明示）。复制走 `.tmp` + rename 原子落位；清单写失败
  /// 时回滚已复制文件（不孤儿）。
  ///
  /// **内容判重（挂载点复盘 #2）**：内容哈希已在册时**复用既有条目**
  /// （[ResourceImportResult.reused] = true，不落副本、不写清单）——一期是纯
  /// 文本库，同内容多副本只会虚增 RC5「已占用」并让清单出现重复条目；
  /// 改名产生的同名不同内容不在此列（仍走 `_dedupeName` 加序号）。
  Future<ResourceImportResult> import(
    String sourcePath, {
    String? displayName,
  }) async {
    final source = File(sourcePath);
    final stat = await source.stat();
    if (stat.size > maxFileBytes) {
      throw ResourceStoreException(
        'too_large',
        '文件 ${(stat.size / 1024 / 1024).toStringAsFixed(1)}MB 超过上限 '
        '${(maxFileBytes / 1024 / 1024).toStringAsFixed(0)}MB',
        hint: '请精简文件内容或拆分后重新导入',
      );
    }
    final rawBytes = await source.readAsBytes();
    final ({String content, String hash}) decoded;
    try {
      // 不走 readAsString：其解码失败会被包装成 FileSystemException，无法与
      // 真不可读区分——自读字节后用 utf8 严格解码（FormatException 即非文本）；
      // >1MB 时解码与哈希**一次 Isolate 内算完**（§3.1 纪律；既防主 isolate
      // 掉帧，也避免为算哈希再扫一遍字节）。
      decoded = rawBytes.length > _isolateDecodeThreshold
          ? await Isolate.run(
              () => (
                content: utf8.decode(rawBytes, allowMalformed: false),
                hash: sha256.convert(rawBytes).toString(),
            ),
          )
          : (
              content: utf8.decode(rawBytes, allowMalformed: false),
              hash: sha256.convert(rawBytes).toString(),
            );
    } on FileSystemException {
      throw ResourceStoreException('io', '文件不可读: $sourcePath');
    } on FormatException {
      throw ResourceStoreException(
        'not_text',
        '仅支持文本类文件（一期不收二进制）',
        hint: '请导入 text/markdown/json/csv 等可解码为文本的文件',
      );
    }
    // 同内容已入库 → 复用既有条目，不落副本（RC5 占用与清单条目口径）。
    final existing = entryByContentHash(decoded.hash);
    if (existing != null) return (entry: existing, reused: true);
    final created = await importContent(
      decoded.content,
      displayName ?? _baseName(sourcePath),
      knownHash: decoded.hash,
    );
    return (entry: created, reused: false);
  }

  /// 从内存内容导入（UI 拿到的是字节串/测试通路；与 [import] 共享落位逻辑）。
  Future<ResourceEntry> importContent(
    String content,
    String displayName, {
    String? knownHash,
  }) async {
    // NUL 字节探测（规格 §4，评审四补）：utf8 对 \x00 判合法，含空字节的
    // 「伪 txt」（损坏文本/改后缀的可执行件头）会混入库——首 1KB 含 NUL 即拒。
    final probeEnd = content.length < 1024 ? content.length : 1024;
    if (content.substring(0, probeEnd).contains('\u0000')) {
      throw ResourceStoreException(
        'not_text',
        '文件含二进制特征（NULL 字节），非纯文本',
        hint: '请导入 text/markdown/json/csv 等纯文本文件',
      );
    }
    final bytes = utf8.encode(content);
    if (bytes.length > maxFileBytes) {
      throw ResourceStoreException(
        'too_large',
        '内容超过上限 ${(maxFileBytes / 1024 / 1024).toStringAsFixed(0)}MB',
        hint: '请精简内容或拆分后重新导入',
      );
    }
    final entry = ResourceEntry(
      id: _newId(),
      name: _dedupeName(displayName.isEmpty ? 'untitled.txt' : displayName),
      sizeBytes: bytes.length,
      importedAtMs: DateTime.now().millisecondsSinceEpoch,
      headPreview: _headPreview(content),
      contentHash: knownHash ?? sha256.convert(bytes).toString(),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final target = _entityFile(entry.id);
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } on FileSystemException catch (e) {
      throw ResourceStoreException('io', '文件落位失败: ${e.message}');
    }
    _entries.add(entry);
    try {
      await _flush();
    } on Object {
      _entries.remove(entry); // 清单写失败回滚，不孤儿（数据面 fail-fast）。
      if (await target.exists()) await target.delete();
      rethrow;
    }
    return entry;
  }

  /// 读全文（Agent `read_local_resource` 工具执行器底层）。
  Future<String> readContent(String id) async {
    final entry = byId(id);
    if (entry == null) {
      throw ResourceStoreException(
        'not_found',
        '资源不存在或已删除: $id',
        hint: '请确认资源 id，或提示用户重新导入',
      );
    }
    try {
      return await _entityFile(id).readAsString(encoding: utf8);
    } on FileSystemException {
      throw ResourceStoreException(
        'io',
        '资源文件缺失（清单在库、实体丢失）: $id',
        hint: '请删除该资源后重新导入',
      );
    }
  }

  /// 读窗口（RC4 防爆，T3 工具执行器调用）：超 [maxBytes] 字节截断返回。
  ///
  /// 截断点做 UTF-8 多字节边界回退（尾部不完整序列丢弃——汉字 3B/Emoji 4B
  /// 撕裂会让严格解码抛 FormatException），解码兜底 `allowMalformed: true`
  /// 末防线；[truncated]=true 时调用方须向用户明示「已截断」。
  Future<({String text, bool truncated})> readContentWindow(
    String id, {
    int maxBytes = kResourceReadWindowBytes,
  }) async {
    final bytes = await _readEntityBytes(id);
    if (bytes.length <= maxBytes) {
      return (text: utf8.decode(bytes), truncated: false);
    }
    var cut = bytes.sublist(0, maxBytes);
    // 边界回退：末尾连续 continuation 字节（10xxxxxx）回溯到首字节，若该
    // 多字节序列不完整（序列长度 > 已含字节数）则整体丢弃。
    var i = cut.length - 1;
    var cont = 0;
    while (i >= 0 && (cut[i] & 0xC0) == 0x80) {
      cont++;
      i--;
    }
    if (i >= 0 && cont > 0) {
      final lead = cut[i];
      final seqLen = (lead & 0xE0) == 0xC0
          ? 2
          : (lead & 0xF0) == 0xE0
              ? 3
              : (lead & 0xF8) == 0xF0
                  ? 4
                  : 1;
      if (seqLen > cont + 1) cut = cut.sublist(0, i);
    }
    final text = utf8.decode(cut, allowMalformed: true); // 末防线，禁抛。
    return (text: text, truncated: true);
  }

  Future<List<int>> _readEntityBytes(String id) async {
    if (byId(id) == null) {
      throw ResourceStoreException(
        'not_found',
        '资源不存在或已删除: $id',
        hint: '请确认资源 id，或提示用户重新导入',
      );
    }
    try {
      return await _entityFile(id).readAsBytes();
    } on FileSystemException {
      throw ResourceStoreException(
        'io',
        '资源文件缺失（清单在库、实体丢失）: $id',
        hint: '请删除该资源后重新导入',
      );
    }
  }

  /// 改展示名（仅清单字段，文件实体不动）。
  Future<ResourceEntry> rename(String id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ResourceStoreException('bad_name', '名称不能为空', hint: '请输入非空名称');
    }
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) {
      throw ResourceStoreException('not_found', '资源不存在或已删除: $id');
    }
    final old = _entries[index];
    final updated = ResourceEntry(
      id: old.id,
      name: trimmed,
      sizeBytes: old.sizeBytes,
      importedAtMs: old.importedAtMs,
      headPreview: old.headPreview,
    );
    _entries[index] = updated;
    try {
      await _flush();
    } on Object {
      _entries[index] = old; // 内存回滚（数据面 fail-fast）。
      rethrow;
    }
    return updated;
  }

  /// 删除（清单 + 文件实体；幂等——不存在时静默返回，删除是收敛操作）。
  Future<void> delete(String id) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final removed = _entries.removeAt(index);
    try {
      await _flush();
    } on Object {
      _entries.insert(index, removed); // 内存回滚。
      rethrow;
    }
    final entity = _entityFile(id);
    // 两段式容错（规格 §4）：清单为准。实体删除失败（句柄占用/磁盘满）容忍 +
    // DEGRADE 留痕（孤儿文件可由清单对账清理），禁裸抛 FileSystemException。
    try {
      if (await entity.exists()) {
        await entity.delete();
      }
    } on FileSystemException catch (e) {
      developer.log(
        '[DEGRADE] resource-store delete entity $id: $e',
        name: 'resource_center',
      );
    }
  }

  /// 落盘排空握手（测试确定性：替代固定延迟猜等）。
  Future<void> get ioDrained async {
    await SequentialFileWriter(_manifestFile).settled;
  }

  /// 孤儿对账（规格 §4）：扫描资源子目录，清理未在清单登记且修改时间超过
  /// [minAge]（默认 2h——远大于导入落位毫秒级竞态窗口，防误删刚复制未登记的
  /// 合法新文件）的孤儿文件（两段式删除残留 / Crash 残留 / .tmp 残渣）。
  /// [extraDirs] = 附加清理目录**路径**（如 `cacheDir/external` 导出临时件）：
  /// 其中修改时间超过 [extraMaxAge]（默认 24h）的文件一律清理，不做清单比对
  /// （系统几乎不主动清 cache，防外部打开大件造成磁盘隐形暴增）。
  /// 返回清理总数；单文件失败容忍 + DEGRADE 留痕，不阻断（非数据面：孤儿本就
  /// 不在册，漏清仅损磁盘占用）。接线 = App 启动 / 进入管理页（T2 装配）。
  Future<int> reconcileOrphans({
    Duration minAge = const Duration(hours: 2),
    List<String> extraDirs = const [],
    Duration extraMaxAge = const Duration(hours: 24),
  }) async {
    if (!_loaded) await load();
    var removed = 0;
    if (await dir.exists()) {
      final known = _entries.map((e) => e.id).toSet();
      await for (final node in dir.list()) {
        if (node is! File) continue;
        final name = _baseName(node.path);
        if (name == 'manifest.json' || known.contains(name)) continue;
        removed += await _purgeIfStale(node, minAge);
      }
    }
    for (final extraPath in extraDirs) {
      final extra = Directory(extraPath);
      if (!await extra.exists()) continue;
      await for (final node in extra.list(recursive: true)) {
        if (node is! File) continue;
        removed += await _purgeIfStale(node, extraMaxAge);
      }
    }
    return removed;
  }

  /// [file] 修改时间超过 [maxAge] 则删除，返回 1/0；失败容忍 DEGRADE 留痕。
  Future<int> _purgeIfStale(File file, Duration maxAge) async {
    try {
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) < maxAge) return 0;
      await file.delete();
      return 1;
    } on FileSystemException catch (e) {
      developer.log(
        '[DEGRADE] resource-store reconcile skip ${file.path}: $e',
        name: 'resource_center',
      );
      return 0;
    }
  }

  /// 外部唤起准备（RC6，T2 管理页调用）：复制资源实体到
  /// `<cachePath>/external/<random_id>_<displayName>`，返回临时件路径。
  ///
  /// - 绝不复用/覆盖同名临时件（评审三补）：外部编辑器持有旧副本时，同名
  ///   覆写在 Windows 共享占用下直接 Sharing violation——每次唤起路径唯一；
  /// - 不暴露库内 uuid 实体原身路径（防外部应用篡改/锁死沙箱实体）；
  /// - 临时件生命周期由 [reconcileOrphans] 的 extraDirs 清理（>24h）。
  Future<String> prepareExternalOpen(String id, {required String cachePath}) async {
    final entry = byId(id);
    if (entry == null) {
      throw ResourceStoreException(
        'not_found',
        '资源不存在或已删除: $id',
        hint: '请确认资源 id，或提示用户重新导入',
      );
    }
    return _prepareExternal(entry, cachePath);
  }

  Future<String> _prepareExternal(ResourceEntry entry, String cachePath) async {
    final safeName = entry.name.replaceAll(RegExp(r'[/\\]'), '_');
    final external = Directory('$cachePath/external');
    if (!await external.exists()) {
      await external.create(recursive: true);
    }
    final temp = File('${external.path}/${_newId().substring(0, 8)}_$safeName');
    try {
      await _entityFile(entry.id).copy(temp.path);
    } on FileSystemException catch (e) {
      throw ResourceStoreException(
        'io',
        '外部打开临时件创建失败: ${e.message}',
        hint: '请稍后重试；若持续失败请删除该资源后重新导入',
      );
    }
    return temp.path;
  }

  File _entityFile(String id) => File('${dir.path}/$id');

  /// 重名去重（规格 §4）：清单已存在同名时追加 ` (n)` 序号后缀（保留扩展名）。
  String _dedupeName(String name) {
    bool taken(String n) => _entries.any((e) => e.name == n);
    if (!taken(name)) return name;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var n = 1;; n++) {
      final candidate = '$base ($n)$ext';
      if (!taken(candidate)) return candidate;
    }
  }

  Future<void> _flush() async {
    final payload = jsonEncode({
      'resources': [for (final e in _entries) e.toJson()],
    });
    await SequentialFileWriter(_manifestFile).write(payload);
  }
}

String _baseName(String path) {
  final norm = path.replaceAll('\\', '/');
  final i = norm.lastIndexOf('/');
  return i < 0 ? norm : norm.substring(i + 1);
}

/// >1MB 的解码入 Worker Isolate（§3.1：>1MB 数据处理禁止主 isolate 承担）。
const int _isolateDecodeThreshold = 1 * 1024 * 1024;

/// headPreview 静态截取（规格 §2）：首个非空行，截前 200 字符。
/// 先剥离 UTF-8 BOM（\uFEFF，Windows 导出件常见）防隐藏字符进清单/上下文；
/// 空内容/全空行兜底 `(empty)`；调用点在导入路径，零额外 IO、零 LLM。
String _headPreview(String content) {
  final stripped =
      content.startsWith('\uFEFF') ? content.substring(1) : content;
  for (final line in stripped.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      return trimmed.length <= 200 ? trimmed : trimmed.substring(0, 200);
    }
  }
  return '(empty)';
}

final Random _rng = Random.secure();

String _newId() {
  final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
