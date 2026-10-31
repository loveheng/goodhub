import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/chat_status_controller.dart';
import 'package:goodhub/ui/components/dual_track_stream.dart';

/// 流式文本气泡边界（2026-10-31 设计修正）：边界由「Run 归属令牌 + 轨道结构」
/// 在状态机内派生，调用方零纪律。
///
/// 回归钉（真机「第二轮回答黏进第一轮气泡」＝用户视角「第二轮没有输出」）：
/// 跨 Run 的文本追加在机制上不可能发生——不依赖任何调用点手工断流。
void main() {
  // 40ms 节拍缓冲 → fake_async 驱动；或直接 flushStreamText 同步刷盘（本测
  // 走同步刷盘路径，免 fake_async 样板）。
  group('流式文本气泡边界（Run 令牌 + 轨道结构派生）', () {
    const runA = ChatRunId(1);
    const runB = ChatRunId(2);

    test('同一 Run 连续刷盘 → 续接同一气泡', () {
      final c = ChatStatusController();
      c.appendStreamText('第一段', run: runA);
      c.flushStreamText();
      c.appendStreamText('第二段', run: runA);
      c.flushStreamText();
      expect(c.tracks, hasLength(1));
      expect((c.tracks.single as TrackText).text.toString(), '第一段第二段');
    });

    test('跨 Run 边界 → 自动另起气泡（残余先刷进旧 Run 条目，保序）', () {
      final c = ChatStatusController();
      c.appendStreamText('一问一答', run: runA);
      c.flushStreamText();
      // Run B 的 delta 在 Run A 残余（缓冲内）之后入池——残余必须先落旧条目。
      c.appendStreamText('第二个回答', run: runB);
      c.flushStreamText();
      final texts = c.tracks.whereType<TrackText>().toList();
      expect(texts, hasLength(2), reason: '跨 Run 必须另起气泡');
      expect(texts[0].text.toString(), '一问一答');
      expect(texts[1].text.toString(), '第二个回答');
    });

    test('跨 Run 边界且缓冲有未刷残余 → 残余落旧 Run 条目（40ms 节拍对账）', () {
      final c = ChatStatusController();
      c.appendStreamText('A-尾帧', run: runA); // 未 flush，滞留缓冲
      c.appendStreamText('B-首帧', run: runB); // Run 切换：add 时先刷 A 残余
      c.flushStreamText();
      final texts = c.tracks.whereType<TrackText>().toList();
      expect(texts, hasLength(2));
      expect(texts[0].text.toString(), 'A-尾帧', reason: 'A 残余落 A 条目（保序铁律）');
      expect(texts[1].text.toString(), 'B-首帧');
    });

    test('块级条目入轨 → 自动关闭活动文本段（工具卡打断，页面层零纪律）', () {
      final c = ChatStatusController();
      c.appendStreamText('工具卡前正文', run: runA);
      c.flushStreamText();
      c.addEntry(TrackCall(tool: 'f')); // 块级条目入轨 = 阅读流打断
      c.appendStreamText('工具卡后正文', run: runA);
      c.flushStreamText();
      final texts = c.tracks.whereType<TrackText>().toList();
      expect(texts, hasLength(2), reason: '块级条目后正文另起气泡');
      expect(texts[0].text.toString(), '工具卡前正文');
      expect(texts[1].text.toString(), '工具卡后正文');
      expect(c.tracks.map((e) => e.runtimeType).toList(),
          [TrackText, TrackCall, TrackText],
          reason: '顺序恒真：正文不得渲染到块级条目之前');
    });

    test('Run 收尾（endRun）→ 尾帧立即落地（不靠 40ms 定时器命中）', () {
      final c = ChatStatusController();
      c.appendStreamText('收尾尾帧', run: runA);
      c.endRun(); // Run 边界由状态机收口
      expect(c.tracks.whereType<TrackText>().single.text.toString(), '收尾尾帧');
    });

    test('flushedTracks 读即刷盘 → 快照必含未落盘的尾帧', () {
      final c = ChatStatusController();
      c.appendStreamText('快照尾帧', run: runA);
      final snap = c.flushedTracks;
      expect(snap.whereType<TrackText>().single.text.toString(), '快照尾帧',
          reason: '落盘/编码轨道快照的读路径必须刷盘（否则恢复会话缺尾句）');
    });

    test('beginRun 逐轮发新令牌（跨轮令牌必不同，归属键不复用）', () {
      final c = ChatStatusController();
      final r1 = c.beginRun(startedAt: DateTime(2026));
      final r2 = c.beginRun(startedAt: DateTime(2026));
      expect(r1, isNot(r2));
      expect(r1 == r2, isFalse);
    });

    test('切会话清归属（令牌不跨会话复用，尾帧不漏进新会话）', () {
      final c = ChatStatusController();
      c.appendStreamText('旧会话尾巴', run: runA);
      c.resetForSession();
      expect(c.tracks, isEmpty);
      c.appendStreamText('新会话', run: runB);
      c.flushStreamText();
      expect(c.tracks.whereType<TrackText>().single.text.toString(), '新会话');
    });
  });
}
