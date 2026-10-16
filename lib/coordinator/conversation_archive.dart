/// ConversationArchive——应用级内核（archive-memory-claim 步 1，设计稿 §3）：
/// 会话快照落盘的事实 owner。收口窗口侧临时替身 `_persistConversation`
/// （chat_page），`ConversationStore`（lib/sandbox/）降为存储实现细节。
///
/// - **纯 Dart 门面**：本文件不 import Flutter（Directory 构造经
///   [ConversationStore.underSupportDir] 收在 sandbox 层，层级纪律 ④ 不 import ⑤）；
/// - **save 组装**：transcript 编码（`ConversationStore.encodeMessages`）收在
///   内核——窗口只传轨道条目 JSON（TrackEntry 是 UI 模型，codec 留 UI 层，
///   `conversation_store.dart:10-12` SSOT）；绑定三态从 [ConversationSession]
///   直读（核心↔核心横向具体类型，两层+端口形态）；
/// - **失败不抛穿**：save 异常 DEGRADE 留痕返 false——调用方在 finally 中
///   使用，抛穿会吞掉 Run 收尾的原生异常路径（原替身同口径）；
/// - **不做全量 session 持久化**：落盘格式由 `ConversationStore` 定义
///   （§7.5），激活集跨会话重开（§15）；SamplingQuota 落盘防篡改口径
///   AM1 已拍板（2026-10-16）：HMAC-SHA256，密钥入 SecureKeyValue。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/security/flutter_secure_key_value.dart';
import '../core/security/secure_key_value.dart';
import '../mcp/sampling.dart';
import '../sandbox/conversation_store.dart';
import 'mcp_runtime.dart';

class ConversationArchive {
  ConversationArchive(this.store, {SecureKeyValue? secure})
      : _secure = secure ?? FlutterSecureKeyValue();

  /// 生产装配入口（UI 层禁 dart:io，与 ConversationStore.underSupportDir 同口径）。
  factory ConversationArchive.underSupportDir(String supportPath,
          {SecureKeyValue? secure}) =>
      ConversationArchive(ConversationStore.underSupportDir(supportPath),
          secure: secure);

  /// 存储实现细节（会话列表/快照原语经本 store）。
  final ConversationStore store;

  final SecureKeyValue _secure;

  // ---------------------------------------------------------------------------
  // SamplingQuota 落盘（AM1 拍板：HMAC-SHA256 防篡改，密钥入安全存储）——
  // 防杀进程刷新额度（设计稿 §3 步 1 / 遗留 (风险)[long]）。
  // ---------------------------------------------------------------------------

  static const _quotaFileName = 'sampling_quota.json';
  static const _quotaKeyName = 'conversation_archive.quota_hmac_key';

  File get _quotaFile => File('${store.dir.path}/$_quotaFileName');

  /// HMAC 密钥：首次使用时生成 32 字节随机值入安全存储（重装即重置，AM1 口径）。
  /// 存取按 latin1 编解码——字节与码元一一对应，读回即原字节序列。
  Future<List<int>> _quotaHmacKey() async {
    final existing = await _secure.read(_quotaKeyName);
    if (existing != null && existing.isNotEmpty) return existing.codeUnits;
    final key = [
      for (var i = 0; i < 32; i++) Random.secure().nextInt(256),
    ];
    await _secure.write(_quotaKeyName, latin1.decode(key));
    return key;
  }

  String _sign(List<int> key, String payload) =>
      Hmac(sha256, key).convert(payload.codeUnits).toString();

  /// 配额命中记录落盘（Run 收尾随快照一并调用）；失败 DEGRADE 留痕返 false
  /// 不抛穿（配额是防滥用辅助，落盘失败不阻断 Run 收尾）。
  Future<bool> saveQuota(SamplingQuota quota) async {
    try {
      final hits = quota.snapshotHits(DateTime.now());
      final payload = jsonEncode(hits);
      final sig = _sign(await _quotaHmacKey(), payload);
      await store.dir.create(recursive: true);
      await _quotaFile.writeAsString(
        jsonEncode(<String, Object?>{'hits': hits, 'sig': sig}),
        flush: true,
      );
      return true;
    } on Object catch (e) {
      // DEGRADE: 配额落盘失败日志可查即可（下次 Run 收尾重试），不抛穿。
      // ignore: avoid_print
      print('[DEGRADE] conversation-archive: 配额落盘失败: $e');
      return false;
    }
  }

  /// 读取落盘的配额（进程重启恢复；文件缺失/损坏/签名不符 → null——
  /// 篡改检出按无配额记录处理，宁可重置不信任被改数据）。
  ///
  /// P2-1：损坏/签名不符不再静默清零——原文件备份保留（防之后 saveQuota
  /// 无声覆盖证据），并经 [lastQuotaError] 供窗口出用户可见提示。
  Future<SamplingQuota?> loadQuota() async {
    try {
      if (!await _quotaFile.exists()) return null;
      final data =
          jsonDecode(await _quotaFile.readAsString()) as Map<String, Object?>;
      final hits = <String, List<int>>{
        for (final e in (data['hits'] as Map? ?? const {}).entries)
          if (e.key is String)
            e.key as String: [
              for (final ms in (e.value as List? ?? const []))
                if (ms is int) ms,
            ],
      };
      final payload = jsonEncode(hits);
      final sig = data['sig'] as String? ?? '';
      final expected = _sign(await _quotaHmacKey(), payload);
      if (!_constantTimeEquals(sig, expected)) {
        // 篡改/密钥轮换：按无记录处理（安全立场），但备份 + 留因可可见。
        await _backupCorruptQuota();
        _lastQuotaError = '配额记录签名不符（疑似篡改或密钥轮换），已按无记录处理';
        return null;
      }
      final quota = SamplingQuota();
      quota.restoreHits(hits);
      return quota;
    } on Object catch (e) {
      // DEGRADE: 配额文件损坏按无记录（重置）——先备份 + lastQuotaError 面板
      // 可见（P2-1：额度不再静默清零），日志留痕。
      // ignore: avoid_print
      print('[DEGRADE] conversation-archive: 配额文件损坏按重置（已备份，面板可见）: $e');
      await _backupCorruptQuota();
      _lastQuotaError = '配额记录损坏，已按无记录处理（$e）';
      return null;
    }
  }

  /// 上次 loadQuota 的损坏/签名不符原因（P2-1；null = 正常或无文件）。
  String? _lastQuotaError;

  /// 供窗口出用户可见提示（chat_page 会话初始化时读）。
  String? get lastQuotaError => _lastQuotaError;

  /// 损坏/异常配额文件备份（rename 原子；失败不阻断——原文件保留留痕）。
  Future<void> _backupCorruptQuota() async {
    try {
      if (!await _quotaFile.exists()) return;
      final backup = File(
          '${_quotaFile.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      await _quotaFile.rename(backup.path);
    } on Object catch (e) {
      // ignore: avoid_print
      print('[DEGRADE] conversation-archive: 配额损坏文件备份失败（原文件保留）: $e');
    }
  }

  /// 定长比较防时序侧信道（safety 例行，非性能路径）。
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String? _currentId;

  /// 标题截取策略收内核：首行截断，超 20 字符加省略号（原 chat_page._titleFrom）。
  static String titleFrom(String prompt) {
    final line = prompt.trim().split('\n').first;
    return line.length > 20 ? '${line.substring(0, 20)}…' : line;
  }

  /// 当前会话 id（null = 尚未懒建）。
  String? get currentId => _currentId;

  /// 当前会话标题（新建时采纳，恢复时随快照）。
  String get currentTitle => _currentTitle;

  var _currentTitle = '';

  /// 是否有可落盘的当前会话（_persistIfAny 保底判据）。
  bool get hasCurrent => _currentId != null;

  /// 会话懒建 + 标题兜底（首个任务起落盘；已有会话仅在标题为空时采纳——
  /// 原 chat_page._send :604-607 语义）。
  Future<void> ensureCurrent({required String prompt}) async {
    _currentTitle =
        _currentTitle.isEmpty ? titleFrom(prompt) : _currentTitle;
    _currentId ??= await store.create(title: _currentTitle);
  }

  /// Run 收尾快照（原子重写，语义原样迁入 `_persistConversation`）：
  /// transcript 编码 + 绑定三态组装在内核；失败 DEGRADE 留痕返 false 不抛穿。
  Future<bool> saveCurrent({
    required List<Map<String, Object?>> trackJson,
    required ConversationSession session,
  }) async {
    final id = _currentId;
    if (id == null) return true; // 无当前会话：无需落盘（原替身早退口径）
    try {
      await store.save(
        id: id,
        title: _currentTitle,
        track: trackJson,
        messages: ConversationStore.encodeMessages(session.transcript),
        activePrivateServerId: session.activePrivateServerId,
      );
      return true;
    } on Object catch (e) {
      // DEGRADE: 快照保存失败至少日志可查（禁静默吞会话）——返回 false 由
      // 窗口出可观测提示（原替身 TrackNote 同口径），异常不抛穿 finally。
      // ignore: avoid_print
      print('[DEGRADE] conversation-archive: 会话快照保存失败 $id: $e');
      return false;
    }
  }

  /// 回读快照（损坏/缺失返 null，DEGRADE 留痕在 store 层）。
  Future<ConversationSnapshot?> load(String id) => store.load(id);

  /// 会话列表（updatedAt 倒序；窗口侧边栏投影源）。
  Future<List<ConversationMeta>> list() => store.list();

  /// 恢复采纳：切会话后以快照元数据为当前态（transcript/轨道解码归窗口视图）。
  void adoptSnapshot(ConversationSnapshot snap) {
    _currentId = snap.id;
    _currentTitle = snap.title;
  }

  /// 删除会话（文件缺失幂等，透传 store）。
  Future<void> delete(String id) => store.delete(id);

  /// 重命名（ux-hardening P1-5，透传 store）：当前会话同名时同步
  /// [_currentTitle]——否则下次 [saveCurrent] 会把旧标题写回，重命名被覆盖。
  Future<bool> rename(String id, String title) async {
    final ok = await store.rename(id, title);
    if (ok && id == _currentId) _currentTitle = title;
    return ok;
  }

  /// 重置当前态：新建会话/删除当前会话后调用（激活集属会话，随新 session 重开）。
  void resetCurrent() {
    _currentId = null;
    _currentTitle = '';
  }
}
