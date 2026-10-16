import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/workspace_stream_filter.dart';

/// P2-2（G2/G6 / §3.3 / §9.2）：In-band 捎带提取流式分流 FSM。
void main() {
  const startTag = WorkspaceStreamFilter.startTag;
  const endTag = WorkspaceStreamFilter.endTag;

  String payload(List<Map<String, String>> facts) =>
      jsonEncode(<String, Object?>{'facts': facts});

  test('普通文本直通（含裸 < 不误吞）', () {
    final f = WorkspaceStreamFilter();
    expect(f.feed('你好 <b>world</b>'), '你好 <b>world</b>');
  });

  test('G4 scope 归一（P2-5）：public/session→session，user→user，srv: 原样，幻觉→null', () {
    WorkspaceFactUpdate build(String scope) => WorkspaceFactUpdate(
        key: 'k', value: 'v', scope: scope, action: 'upsert');
    expect(build('public').normalizedScope, 'session',
        reason: '"public" 映射本会话域（§3.5 G4）');
    expect(build('session').normalizedScope, 'session');
    expect(build('user').normalizedScope, 'user');
    expect(build('srv:goodshare').normalizedScope, 'srv:goodshare');
    expect(build('srv:').normalizedScope, isNull, reason: '空 id 视为幻觉');
    expect(build('everything').normalizedScope, isNull, reason: '幻觉 scope 丢弃');
  });

  test('完整标签单 chunk：UI 无结构化段残留，onExtracted 收解析后 facts', () {
    final texts = <String>[];
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(
      onText: texts.add,
      onExtracted: extracted.add,
    );
    final ui = f.feed('结论：用 Postgres。$startTag'
        '${payload([
      {'key': 'db', 'value': 'PostgreSQL', 'scope': 'public', 'action': 'upsert'}
    ])}$endTag');
    expect(ui, '结论：用 Postgres。');
    expect(texts.join(), '结论：用 Postgres。', reason: 'JSON 绝不闪烁在气泡');
    expect(extracted.single.single.key, 'db');
    expect(extracted.single.single.value, 'PostgreSQL');
    expect(extracted.single.single.scope, 'public');
    expect(extracted.single.single.action, 'upsert');
  });

  test('跨 chunk 分割（逐字符喂入）：分流与单 chunk 一致', () {
    final texts = <String>[];
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(
      onText: texts.add,
      onExtracted: extracted.add,
    );
    final full = '答A。$startTag${payload([
      {'key': 'k1', 'value': 'v1', 'scope': 'user', 'action': 'upsert'}
    ])}$endTag答B。';
    var ui = '';
    for (final ch in full.runes) {
      ui += f.feed(String.fromCharCode(ch));
    }
    expect(ui, '答A。答B。');
    expect(extracted.single.single.key, 'k1');
  });

  test('疑似前缀误报（<work 而非标签）：原文 flush 回 UI 不误吞', () {
    final f = WorkspaceStreamFilter();
    expect(f.feed('<work in progress'), '<work in progress');
  });

  test('用户正常 <tag> 标签直通（START tag 前缀断裂回退）', () {
    final f = WorkspaceStreamFilter();
    expect(f.feed('<workspace_update_v2>伪</workspace_update_v2>'),
        '<workspace_update_v2>伪</workspace_update_v2>',
        reason: '非 v1 命名空间一律按普通文本（§9.3 防伪）');
  });

  test('无闭合标签：绝不触发 onExtracted（闭环原子提交）', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    f.feed('$startTag${payload([])}'); // 有头无尾
    expect(extracted, isEmpty);
    // UI 侧已 flush 的普通文本不受影响（本例无普通文本）。
  });

  test('残缺 JSON + 完整闭合：静默丢弃（不抛、不回调）', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    expect(
      () => f.feed('$startTag{"facts": [ {"key": }$endTag'),
      returnsNormally,
      reason: 'FormatException 不上抛中断 UI（§3.3 黄金法则）',
    );
    expect(extracted, isEmpty);
  });

  test('```json 围栏包裹：剥离后仍可解析提交', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    f.feed('$startTag```json\n${payload([
      {'key': 'k', 'value': 'v', 'scope': 'user', 'action': 'upsert'}
    ])}\n```$endTag');
    expect(extracted.single.single.key, 'k');
  });

  test('空对象 {}（闲聊空标签）：回调收到空 facts 列表', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    f.feed('$startTag{}$endTag');
    expect(extracted.single, isEmpty);
  });

  test('cancelCommit：清空缓冲 + 已捕获未闭合内容绝不提交（tool-call 轮硬压）', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    f.feed(startTag + payload(const [])); // 未闭合即 tool-call 轮结算
    f.cancelCommit();
    // 随后闭合标签到达也不提交（禁令在位）。
    f.feed(endTag);
    expect(extracted, isEmpty);
  });

  test('cancelCommit 后新开的结构化段仍须提交（禁令不株连后续轮次）', () {
    // 复现：首个工具轮 cancelCommit 置禁令后，下一自然结算轮的合法段
    // 曾被静默丢弃（记忆胶囊不出现/不落盘）——修复：新段开启即解除禁令。
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    f.feed('中途$startTag{"facts":['); // 工具轮残段（未闭合）
    f.cancelCommit(); // 结算硬压：清空 + 禁令
    // 下一轮自然作答：完整合法段必须提交。
    f.feed('答案$startTag${payload([
      {'key': 'k', 'value': 'v', 'scope': 'user', 'action': 'upsert'}
    ])}$endTag');
    expect(extracted, hasLength(1));
    expect(extracted.single.single.key, 'k');
  });

  test('discard：全量复位后下轮干净起步（abort 生命线）', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final texts = <String>[];
    final f = WorkspaceStreamFilter(
      onText: texts.add,
      onExtracted: extracted.add,
    );
    f.feed('$startTag{"facts"'); // 残缺段残留
    f.discard();
    // 复位后正常文本直通 + 正常提取可用。
    expect(f.feed('新轮文本'), '新轮文本');
    f.feed('$startTag${payload([
      {'key': 'k2', 'value': 'v2', 'scope': 'session', 'action': 'upsert'}
    ])}$endTag');
    expect(extracted.single.single.key, 'k2');
    expect(texts.join(), contains('新轮文本'));
  });

  test('jsonBuffer 超限未闭合：整段丢弃不膨胀（防御病态流）', () {
    final extracted = <List<WorkspaceFactUpdate>>[];
    final f = WorkspaceStreamFilter(onExtracted: extracted.add);
    final giant = 'x' * (64 * 1024 + 10);
    expect(() => f.feed(startTag + giant), returnsNormally);
    // 超限后状态已复位：闭合标签按普通文本流出。
    expect(f.feed(endTag), endTag);
    expect(extracted, isEmpty);
  });

  group('四域默会提取协议（2026-10-16 口径）', () {
    // 静态锚点：提示词文本保证四域白名单与 schema 关键字在位——
    // 模型行为不可单测，锚定协议文本即锚定少样本一致性。
    test('promptInstructions 含四域白名单与 schema 关键字', () {
      const p = WorkspaceStreamFilter.promptInstructions;
      expect(p, contains('facts'), reason: '示例 JSON 必须含 facts 包裹（解析器 schema）');
      expect(p, contains('task.goal'));
      expect(p, contains('decision.'), reason: '决策域（含理由原子记录）');
      expect(p, contains('constraint.avoid_'), reason: '废案禁令域');
      expect(p, contains('remove'), reason: 'action=remove 触发规则须显式给出');
      expect(p, contains('严禁输出本标签'), reason: '空态禁输出（省 token 防闲聊污染）');
      expect(p, contains('<主题>'), reason: '占位符禁用 <n>——防端侧小模型误解为数字编号');
    });

    // FSM 管道：新标准格式端到端——四域 facts 全量收集、remove 透传、
    // 正文标签干净剥离。
    test('新格式管道解析：四域 facts 收集 + remove 透传 + 标签剥离', () {
      final texts = <String>[];
      final extracted = <List<WorkspaceFactUpdate>>[];
      final f = WorkspaceStreamFilter(
        onText: texts.add,
        onExtracted: extracted.add,
      );
      final ui = f.feed('定了。$startTag${payload([
        {
          'key': 'decision.db',
          'value': '选 PostgreSQL；原因：团队已有运维经验',
          'scope': 'session',
          'action': 'upsert',
        },
        {
          'key': 'constraint.avoid_resident',
          'value': '严禁将业务服务设为全局公共常驻',
          'scope': 'session',
          'action': 'upsert',
        },
        {
          'key': 'constraint.avoid_inline_expand',
          'value': 'UI 禁止行内展开',
          'scope': 'session',
          'action': 'remove',
        },
      ])}$endTag');
      expect(ui, '定了。', reason: '正文与标签段干净分流');
      expect(texts.join(), '定了。');
      expect(extracted, hasLength(1));
      final facts = extracted.single;
      expect(facts.map((e) => e.key).toList(), [
        'decision.db',
        'constraint.avoid_resident',
        'constraint.avoid_inline_expand',
      ]);
      expect(
        facts.every((e) => e.normalizedScope == 'session'),
        isTrue,
        reason: '四域默认 session（G4 归一）',
      );
      expect(facts[2].action, 'remove', reason: 'remove 动作透传落盘层（解禁通路）');
    });
  });
}
