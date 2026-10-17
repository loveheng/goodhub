/// ChatSessionService 持久化口径单测。
///
/// 回归钉死（2026-10-17 用户报障：空对话窗口顶部误现「⚠ 会话快照保存失败
/// （见日志）」）：「无当前会话 = 无需落盘 = 成功」——与事实 owner
/// [ConversationArchive.saveCurrent] 早退口径对齐（无会话 no-op 返 true 的
/// 底层语义另由 `conversation_archive_test.dart` 钉死，此处钉服务层透传）。
///
/// 病因回顾：2026-10-16 立核重构（211c9cd）把窗口替身 `_persistConversation`
/// 的「无会话静默早退」下沉到 Archive 时，服务层误写为 `return false`——
/// composer 即时绑定（chat_page._bindSessionServer → _persistCurrent）在会话
/// 懒建（首个任务发送）前触发即被 UI 当成保存失败出红字，而日志并无 DEGRADE
/// 留痕（从未发起落盘，「见日志」无可查）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/chat_session_service.dart';

void main() {
  group('persistCurrent 无快照可存口径', () {
    test('init 前（无 archive）：no-op 返 true，不误报保存失败', () async {
      final svc = ChatSessionService();
      expect(
        await svc.persistCurrent(trackJson: const []),
        isTrue,
        reason: '无快照可存 ≠ 保存失败——禁在空会话窗口误报 DEGRADE 红字',
      );
    });

    test('persistIfAny 无当前会话：静默 no-op 不抛不误报', () async {
      final svc = ChatSessionService();
      await svc.persistIfAny(trackJson: const []);
      // 保底路径幂等：再调一次仍静默（无 archive 可毒化）。
      await svc.persistIfAny(trackJson: const []);
    });
  });
}
