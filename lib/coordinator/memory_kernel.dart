/// Memory 内核（archive-memory-claim 步 2，设计稿 §3）：In-band 提取面的
/// 事实路由 owner。收口 `ConversationSession.memoryFilter` 临时替身
/// （window-kernel-split 步 3-T3 暂寄 session）——Session 回归纯会话态。
///
/// - **路由口径（语义原样迁入）**：session 域（public/session 归一后）落
///   [WorkspaceStateStore]（会话级 store 所有权仍在 Session，按调用传入）；
///   user/srv 域走 [MemoryStore] keyed 映射（G1：同 key 覆盖不追加）；remove
///   幂等；幻觉 scope 丢弃（G4）；
/// - **UI 胶囊通道不变**：每条落盘事实经 [onCapsule] 回传窗口（TrackMemoryCapsule
///   渲染与撤销挂载留在窗口；undo 闭包已含落盘回滚）；
/// - **只调公共 API**：`upsertFacts/removeFacts` + wsStates `upsert/remove`——
///   不碰 MemoryStore 内部（chatmessage epic 的 opsLog 拆分可并行）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../sandbox/memory_store.dart';
import '../sandbox/workspace_state_store.dart';
import 'workspace_stream_filter.dart';

class MemoryKernel {
  MemoryKernel(this.memoryStore);

  /// user/srv 域事实的落点（keyed 映射）。
  final MemoryStore memoryStore;

  /// 构造 In-band 提取面（原 `ConversationSession.memoryFilter` 语义原样迁入，
  /// mcp_runtime.dart:770-806）。
  ///
  /// [onCapsule] 回传 (key, value, action, scope, undo)——action/scope 供
  /// 记忆增量日志（memory_journal，context-stepped-pruning §6.3）区分
  /// SET/OVERRIDE/DEL 与域标签；undo 闭包已含落盘回滚。
  WorkspaceStreamFilter buildFilter({
    required WorkspaceStateStore? wsStates,
    required String conversationId,
    required void Function(
            String key, String value, String action, String scope, void Function() undo)
        onCapsule,
    void Function(String key, String scope)? onWriteFailure,
  }) =>
      WorkspaceStreamFilter(
        onExtracted: (facts) {
          for (final f in facts) {
            final scope = f.normalizedScope;
            if (scope == null) continue; // 幻觉 scope 丢弃（G4）
            // window-slim P1-C：数据面写失败不再静默——写错误上报
            // [onWriteFailure]（chat_page 接 TrackNote 用户可见），未接回调时
            // 至少 DEGRADE 留痕；undo 语义不变（remove 幂等可回滚半写）。
            void reportFailure(Object e) {
              debugPrint(
                  '[DEGRADE] memory-kernel: 事实写失败 key=${f.key} scope=$scope: $e');
              onWriteFailure?.call(f.key, scope);
            }

            Future<void> undo() => scope == 'session'
                ? wsStates!.remove(conversationId, f.key)
                : memoryStore.removeFacts(f.key, scope: scope);
            // window-slim P1-C：写失败不再静默（try/catch 上报，见 reportFailure）。
            Future<void> guardedWrite(Future<Object?> write) async {
              try {
                await write;
              } on Object catch (e) {
                reportFailure(e);
              }
            }

            if (scope == 'session') {
              // ignore: discarded_futures
              unawaited(guardedWrite(f.action == 'remove'
                  ? wsStates!.remove(conversationId, f.key)
                  : wsStates!.upsert(conversationId, f.key, f.value)));
            } else {
              // P2-1b（G1）：user/srv 域走 MemoryStore keyed 映射——同 key
              // 覆盖不追加；remove 幂等。
              // ignore: discarded_futures
              unawaited(guardedWrite(f.action == 'remove'
                  ? memoryStore.removeFacts(f.key, scope: scope)
                  : memoryStore.upsertFacts(f.key, f.value, scope: scope)));
            }
            onCapsule(f.key, f.value, f.action, scope, undo);
          }
        },
      );
}
