/// 宿主环境事实只读工具单测（host-tools-gateway-export · Allowlist 首项）。
///
/// 覆盖 coding-standards §5.7 自查清单中可机械化的部分：工具声明（§5.1 描述
/// 引导）、参数 Schema 强类型、写后/只读语义、错误契约带 hint（§5.4），
/// 以及「零隐私」选型约束（返回体内不得出现用户数据 / 服务清单 / 槽位态）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/host_status_tool.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

class _Fallback implements ToolExecutor {
  int calls = 0;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    calls++;
    return const ToolExecutionResult(content: 'inner');
  }
}

AssembledToolCall _call(String name, [String args = '{}']) =>
    AssembledToolCall(id: 'c1', name: name, argumentsJson: args);

void main() {
  group('工具声明（§5.1 描述引导）', () {
    test('readOnlyHint: true + 空参数 Schema（只读零参）', () {
      final s = HostStatusToolExecutor.toolSchemas().single;
      expect(s.name, 'get_host_status');
      expect(s.annotations, {'readOnlyHint': true},
          reason: '显式声明 → 网关 L1 静默放行（不进确认卡）');
      expect(s.parametersSchema, {'type': 'object'});
    });

    test('description 含「怎么用才对」（适用场景 + 反例），非空泛说明', () {
      final d = HostStatusToolExecutor.toolSchemas().single.description;
      expect(d, contains('时区'));
      expect(d, contains('怎么用才对'));
      expect(d.length, greaterThan(40), reason: '空泛描述（"查询状态"）不合格');
    });

    test('schemaOf：仅本工具返回 schema，他工具返空（owner 边界）', () {
      expect(HostStatusToolExecutor.schemaOf('get_host_status'),
          isNotEmpty);
      expect(HostStatusToolExecutor.schemaOf('other_tool'), isEmpty);
    });
  });

  group('执行语义', () {
    late _Fallback fallback;
    late HostStatusToolExecutor ex;

    setUp(() {
      fallback = _Fallback();
      ex = HostStatusToolExecutor(
        inner: fallback,
        appVersion: '1.1.0+2010',
        timezone: 'Asia/Shanghai',
        locale: 'zh_CN',
      );
    });

    test('返回宿主环境事实（版本/协议/平台/时区/语言）', () async {
      final r = await ex.execute(_call(HostStatusToolExecutor.toolName));
      expect(r.isError, isFalse);
      final out = jsonDecode(r.content) as Map<String, Object?>;
      expect(out['status'], 'ok');
      final host = out['host'] as Map<String, Object?>;
      expect(host['app'], 'goodhub');
      expect(host['version'], '1.1.0+2010', reason: '版本须真值，占位会误导兼容判断');
      expect(host['protocol'], '2025-06-18');
      expect(host['platform'], 'android');
      expect(host['timezone'], 'Asia/Shanghai');
      expect(host['locale'], 'zh_CN');
    });

    test('零隐私选型约束：返回体不含用户数据 / 服务清单 / 槽位态', () async {
      final r = await ex.execute(_call(HostStatusToolExecutor.toolName));
      for (final leak in ['memory', 'memories', 'servers', 'serverId',
        'activePrivate', 'token', 'ip', 'resource']) {
        expect(r.content.toLowerCase(), isNot(contains(leak.toLowerCase())),
            reason: '不得泄露 $leak（零隐私是本项登记的前提）');
      }
    });

    test('入参 JSON 损坏 → isError + hint（§5.4 可纠正分支）', () async {
      final r = await ex.execute(
          _call(HostStatusToolExecutor.toolName, '{broken'));
      expect(r.isError, isTrue);
      expect(r.content, contains('{}'), reason: '须告诉模型下一步怎么改');
    });

    test('多传参数 → 不报错，忽略并回 note（模型偶发多传不该整次失败）', () async {
      final r = await ex.execute(_call(
          HostStatusToolExecutor.toolName, '{"verbose":true}'));
      expect(r.isError, isFalse);
      expect(r.content, contains('note'));
      expect(r.content, contains('1.1.0+2010'), reason: '仍要给出有效事实');
    });

    test('非本工具名 → 透传 inner（执行链组合不吞工具）', () async {
      final r = await ex.execute(_call('query_memory'));
      expect(r.content, 'inner');
      expect(fallback.calls, 1);
    });

    test('时区/语言缺省走运行期真值（非硬编码占位）', () async {
      final bare = HostStatusToolExecutor(inner: fallback);
      final host =
          (jsonDecode((await bare.execute(_call(HostStatusToolExecutor.toolName))).content)
                  as Map<String, Object?>)['host']!
              as Map<String, Object?>;
      expect(host['timezone'], DateTime.now().timeZoneName);
      expect(host['locale'], Platform.localeName);
    });
  });
}
