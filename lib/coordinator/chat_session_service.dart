/// 会话持久化与生命周期服务（arch-hardening 断点③ step1）。
///
/// 把 `chat_page` 的会话**内核状态**（[ConversationArchive] / [ConversationSession]
/// / 侧边栏列表）与编排逻辑下沉到 coordinator 纯内核层；窗口只持本服务句柄 + UI 态。
///
/// 边界纪律（防 coordinator→ui 反向边复燃）：本服务**不依赖 ui 层类型**。
/// `TrackEntry`/`TrackEntryCodec` 位于 `lib/ui/components/dual_track_stream.dart`
/// （ui 层），故轨道卡编解码由调用方在边界完成——[persistCurrent]/[persistIfAny]
/// 收 `trackJson` 字符串参数（UI 经 `TrackEntryCodec` 编码后传入），[loadSnapshot]
/// 返回原始 [ConversationSnapshot]（messages/track 解码留在 UI 层）。
/// `ChatMessageCodec` 位于 `lib/llm/cloud/`（llm 层，coordinator 已依赖），可安全使用。
library;

import 'package:path_provider/path_provider.dart';
import 'package:goodhub/coordinator/conversation_archive.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/sandbox/conversation_store.dart';
import 'package:goodhub/llm/cloud/chat_message_codec.dart';

class ChatSessionService {
  ChatSessionService();

  ConversationArchive? _archive;
  ConversationSession _session = ConversationSession();
  var conversations = <ConversationMeta>[];

  ConversationSession get session => _session;
  ConversationArchive? get archive => _archive;

  /// 初始化：建 Archive 内核 + 恢复配额 + 列会话。返回的会话已应用持久化配额
  /// （null 配额记录时仍返回全新会话）。配额损坏提示（`lastQuotaError`）由 UI 层
  /// 读取 [archive] 后处理——属 UI 关切，不在此层。
  Future<ConversationSession> init() async {
    final support = await getApplicationSupportDirectory();
    _archive = ConversationArchive.underSupportDir(support.path);
    final quota = await _archive!.loadQuota();
    if (quota != null) _session = ConversationSession(samplingQuota: quota);
    await refresh();
    return _session;
  }

  Future<void> refresh() async {
    final a = _archive;
    if (a == null) return;
    conversations = await a.list();
  }

  /// Run 收尾/绑定即存快照。[trackJson] 由 UI 层经 `TrackEntryCodec` 编码后传入
  /// （本服务不依赖 ui 的 [TrackEntry]）。返回是否保存成功，失败由 UI 出轨道提示。
  Future<bool> persistCurrent(
      {required List<Map<String, Object?>> trackJson}) async {
    final a = _archive;
    if (a == null || !a.hasCurrent) return false;
    final ok = await a.saveCurrent(trackJson: trackJson, session: _session);
    if (ok) await a.saveQuota(_session.samplingQuota);
    await refresh();
    return ok;
  }

  Future<void> persistIfAny(
      {required List<Map<String, Object?>> trackJson}) async {
    if (_archive?.hasCurrent ?? false) await persistCurrent(trackJson: trackJson);
  }

  /// 会话内核态重置（**不含** UI/Run 态——由调用方负责清轨道/卡死监视/状态带）。
  void resetSession() {
    _session = ConversationSession();
    _archive?.resetCurrent();
  }

  Future<ConversationSnapshot?> loadSnapshot(String id) =>
      _archive?.load(id) ?? Future<ConversationSnapshot?>.value(null);

  /// 采用快照恢复内核态。messages 解码在 coordinator 层合法（`ChatMessageCodec`
  /// 在 llm 层）；track 解码仍在 UI 层完成（service 不碰 [TrackEntry]）。
  Future<void> adoptSnapshot(ConversationSnapshot snap) async {
    _archive?.adoptSnapshot(snap);
    _session.bindPrivateServer(snap.activePrivateServerId);
    _session.replaceTranscript(ChatMessageCodec.decodeCloud(snap.messages));
  }

  Future<void> delete(String id) async {
    await _archive?.delete(id);
    await refresh();
  }

  Future<bool> rename(String id, String title) async {
    final ok = await _archive?.rename(id, title) ?? false;
    if (ok) await refresh();
    return ok;
  }
}
