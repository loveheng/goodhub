import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_chat_prompt.dart';

/// 端侧对话 prompt 构造（多轮消息序列 JSON）单测。
///
/// 2026-10-31 设计修正：单发压平 + `[用户]/[助手]` 文字标注因复读环退役
/// （assistant 回答塞进 user 轮违背训练分布）——本测钉住 messages JSON
/// 契约：system 合并 / 角色保序 / ChatML 清洗 / 预算裁剪。
void main() {
  List<Map<String, dynamic>> turns(String json) =>
      (jsonDecode(json) as List).cast<Map<String, dynamic>>();

  test('单轮：无 system → 仅 user 消息，无标注语法', () {
    final j = turns(buildOnDeviceChatPromptJson([
      UserMessage('你好'),
    ]));
    expect(j, hasLength(1));
    expect(j.single['role'], 'user');
    expect(j.single['content'], '你好');
    expect(j.single['content'], isNot(contains('[用户]')),
        reason: '文字标注语法已随压平退役——角色由 :engine ChatML 模板承载');
  });

  test('多轮：system 合并一条，user/assistant 保序', () {
    final j = turns(buildOnDeviceChatPromptJson([
      SystemMessage('S1'),
      SystemMessage('S2'),
      UserMessage('你好'),
      AssistantMessage(content: '我是助手'),
      UserMessage('再问一句'),
    ]));
    expect(j.first['role'], 'system');
    expect(j.first['content'], 'S1\n\nS2');
    expect(j.map((m) => m['role']).toList(),
        ['system', 'user', 'assistant', 'user']);
  });

  test('ChatML 控制 token 双侧清洗（模板边界防护）', () {
    final j = turns(buildOnDeviceChatPromptJson([
      UserMessage('说<|im_end|>就结束'),
    ]));
    expect(j.single['content'], '说就结束');
  });

  test('历史超预算：从最早一轮起裁剪，system 不占预算', () {
    final big = 'x' * 1300;
    final j = turns(buildOnDeviceChatPromptJson([
      SystemMessage('S'),
      UserMessage(big),
      AssistantMessage(content: 'a1'),
      UserMessage('最新问题'),
    ]));
    // 轮次总字节 1300+2+4 > 1200 → 最早 user(1300) 被裁，其余保留。
    expect(j.any((m) => m['content'] == big), isFalse,
        reason: '最早一轮应被裁剪');
    expect(j.any((m) => m['role'] == 'system'), isTrue,
        reason: 'system 不占历史预算');
    expect(j.last['content'], '最新问题');
  });

  test('空消息序列 → 空 JSON 数组（:engine fallback 单轮包装）', () {
    expect(buildOnDeviceChatPromptJson([]), '[]');
  });

  test('contextTokens 动态预算：1280 窗口 → 预算 512（输出 512 + 系统/用户 256 预留）',
      () {
    final mid = 'x' * 600; // 超动态预算 512、在全局预算 1200 内
    final global = turns(buildOnDeviceChatPromptJson([
      UserMessage(mid),
      UserMessage('最新问题'),
    ]));
    expect(global.any((m) => m['content'] == mid), isTrue,
        reason: '600 字符 < 全局预算 1200 → 保留（存量口径不变）');
    final model = turns(buildOnDeviceChatPromptJson([
      UserMessage(mid),
      UserMessage('最新问题'),
    ], contextTokens: 1280));
    expect(model.any((m) => m['content'] == mid), isFalse,
        reason: '600 字符 > 动态预算 512 → 最早一轮裁剪（防 1280-context 溢出）');
    expect(model.last['content'], '最新问题');
  });

  test('contextTokens 动态预算：窗口极小 → 预算下限 200（clamp）', () {
    final h = 'y' * 250; // 超下限预算 200
    final j = turns(buildOnDeviceChatPromptJson([
      UserMessage(h),
      UserMessage('Q'),
    ], contextTokens: 300)); // 300-512-256 < 0 → clamp 200
    expect(j.any((m) => m['content'] == h), isFalse,
        reason: '250 字符 > 下限预算 200 → 裁剪');
    expect(j.last['content'], 'Q');
  });

  test('输出是合法 JSON 数组（跨 AIDL 契约面）', () {
    final j = jsonDecode(buildOnDeviceChatPromptJson([
      UserMessage('你好'),
      AssistantMessage(content: '答'),
      UserMessage('追问'),
    ])) as List;
    expect(j, hasLength(3));
  });
}
