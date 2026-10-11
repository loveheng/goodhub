/// activate_skill 元工具执行器（M2.5-T5）：ToolExecutor 装饰器——拦截
/// `activate_skill` 调用做宿主本地激活（§7 JIT 语义：L1 静默，药丸反馈由
/// 网关 onNotice 承担），其余工具原样透传 inner。
/// C-2 同轨：未知 Skill → isError 回填（不抛不挂起）。
/// M4-T2 审计：拦截分支落 ops.log（server='local'，N4 全链路）；审计失败
/// DEGRADE 留痕不阻断。透传调用不在此审计（remote 归 McpToolFace 自审计）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/cloud/cloud_llm.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';
import 'skill_registry.dart';

class SkillActivationExecutor implements ToolExecutor {
  SkillActivationExecutor({
    required this.inner,
    required this.registry,
    this.opsLog,
  });

  final ToolExecutor inner;
  final SkillRegistry registry;

  /// ops.log 审计汇（M4-T2）；null = 不审计（测试/无沙盒路径）。
  final MemoryStore? opsLog;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    if (call.name != 'activate_skill') return inner.execute(call);
    final Object? args;
    try {
      args =
          call.argumentsJson.trim().isEmpty ? const {} : jsonDecode(call.argumentsJson);
    } on FormatException catch (e) {
      await _audit(false, error: '入参 JSON 损坏: ${e.message}');
      return ToolExecutionResult(
        content: 'activate_skill 入参 JSON 损坏: ${e.message}',
        isError: true,
      );
    }
    final name =
        args is Map && args['name'] is String ? args['name'] as String : '';
    if (name.isEmpty) {
      await _audit(false, error: '缺少 name 参数');
      return const ToolExecutionResult(
        content: 'activate_skill 缺少 name 参数',
        isError: true,
      );
    }
    final ok = registry.activate(name);
    await _audit(ok, error: ok ? null : '未知或不可激活的 Skill: $name');
    if (!ok) {
      return ToolExecutionResult(
        content: '未知或不可激活的 Skill: $name（可激活项见系统提示「可激活」清单）',
        isError: true,
      );
    }
    return ToolExecutionResult(
        content: 'Skill「$name」已激活，本会话后续轮次生效。');
  }

  Future<void> _audit(bool ok, {String? error}) async {
    final log = opsLog;
    if (log == null) return;
    try {
      await log.audit(server: 'local', tool: 'activate_skill', ok: ok, error: error);
    } catch (e) {
      debugPrint('[DEGRADE] skill-activation: ops audit failed: $e');
    }
  }
}