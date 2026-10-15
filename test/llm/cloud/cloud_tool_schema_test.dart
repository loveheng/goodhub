import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

/// P1-2（G5 / SSOT §8.2）：CloudToolSchema 规范序列化——一级键序固定、
/// parametersSchema 递归字典序归一、annotations 不进云端序列化。
void main() {
  test('toJson 一级键序固定 name→description→input_schema', () {
    final t = CloudToolSchema(
      name: 'srv_x__query',
      description: '查询',
      parametersSchema: {'type': 'object', 'properties': <String, Object?>{}},
    );
    final keys = t.toJson().keys.toList();
    expect(keys, ['name', 'description', 'input_schema']);
    // jsonEncode 字节流键序一致（缓存命中前提）。
    expect(jsonEncode(t.toJson()),
        '{"name":"srv_x__query","description":"查询","input_schema":{"properties":{},"type":"object"}}');
  });

  test('parametersSchema 递归字典序归一：键序漂移不影响字节流', () {
    final a = CloudToolSchema(
      name: 't',
      description: '',
      parametersSchema: {
        'type': 'object',
        'properties': {
          'zeta': {'type': 'string', 'description': 'z'},
          'alpha': {'description': 'a', 'type': 'number'},
        },
        'required': ['zeta', 'alpha'],
      },
    );
    // 同一 schema 的另一种键序（上游 MCP 返回序不可控）。
    final b = CloudToolSchema(
      name: 't',
      description: '',
      parametersSchema: {
        'required': ['zeta', 'alpha'],
        'properties': {
          'alpha': {'type': 'number', 'description': 'a'},
          'zeta': {'description': 'z', 'type': 'string'},
        },
        'type': 'object',
      },
    );
    // 字节级恒等（含顶层与 properties 内各字段）。
    expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
  });

  test('List 保序不乱排（required / enum 语义有序）', () {
    final t = CloudToolSchema(
      name: 't',
      description: '',
      parametersSchema: {
        'properties': {
          'mood': {'type': 'string', 'enum': ['z', 'a', 'm']},
        },
        'required': ['mood'],
      },
    );
    final encoded = jsonEncode(t.toJson());
    expect(encoded, contains('"enum":["z","a","m"]'));
    expect(encoded, contains('"required":["mood"]'));
  });

  test('annotations 不进云端序列化', () {
    final t = CloudToolSchema(
      name: 't',
      description: '',
      parametersSchema: const {},
      annotations: {'readOnlyHint': true},
    );
    expect(jsonEncode(t.toJson()), isNot(contains('readOnlyHint')));
  });
}
