/// CoW 模板 → Skill 注入（逐 server 同步 + 重名跳过通告）。
///
/// **独立成件（架构债 #18 体量治理）**：该块原寄生在 `McpRuntime.assemble`
/// （该文件在「只减不增」超标清单内）→ 抽出后核心装配文件只留调用，CoW 注入
/// 语义（命名、撞名跳过、失败降级）有独立 owner 与独立单测面。
///
/// **语义（prompt-mgmt §3.3 / T6）**：逐 server 拉 `prompts/list`，按
/// `cow/<promptName>` 命名注册为 Skill；**撞名跳过并通告**（不覆盖既有）；
/// 同步失败按 Polyfill 降级（无模板注入），**不阻断装配**。
library;

import 'dart:io';

import '../core/errors/mcp_error.dart';
import '../mcp/mcp_client.dart';
import '../mcp/server_capabilities.dart';
import 'cow_sync.dart';
import 'skill_registry.dart';

/// 逐 server 同步 CoW 模板并注册进 [skills]（幂等：同 promptName 已存在则跳过）。
Future<void> syncCowSkillsIntoRegistry({
  required Map<String, McpClient> clients,
  required Map<String, ServerCapabilities> serverCaps,
  required SkillRegistry skills,
  required Future<Directory> Function() documentsDirResolver,
  CowMajorJumpDelegate? majorJumpDelegate,
  void Function(String message, {bool danger})? note,
}) async {
  for (final entry in clients.entries) {
    final caps = serverCaps[entry.key];
    if (caps == null || !caps.hasPrompts) continue;
    try {
      final cow = CowSyncService(
        store: CowOverridesStore(dir: await documentsDirResolver()),
        onMajorJump: majorJumpDelegate,
      );
      final items = await cow.sync(entry.value, serverId: entry.key);
      for (final i in items) {
        if (i.content == null) continue;
        try {
          skills.register(CowSyncService.toSkill(i, entry.key));
        } on ArgumentError catch (e) {
          note?.call('⚠ CoW Skill 注册跳过: $e', danger: true);
        }
      }
    } on McpException catch (e) {
      note?.call('CoW 同步失败（Polyfill 降级为无模板注入）: $e', danger: false);
    }
  }
}
