/// 本地资源读取工具（resource-center M1-T3）：`read_local_resource`。
///
/// 规格 SSOT：docs/design/resource-center.md §2/§4。链路位置 = Gateway 内侧
/// （L2 裁决先于执行，对齐 `memory_tool_executor` 挂载位）；附件全文已在
/// run 级 `$ref` 池（`resource_attachment_binder`），本工具按 resource_id
/// 经 [ResourceStore.readContentWindow] 读——**不走句柄入参**：注水管线会把
/// 参数里的 `$ref` 句柄替换为全文（击穿 RC4 64KB 窗口）。
///
/// 防死循环契约（RC4，评审三补）：单次仅返回前 64KB，description 与截断宿主
/// 注双处明示「不支持分段/全文重试，严禁对同一 resource_id 重复调用」——
/// 一期无 offset/limit，模型见截断提示极易反复重调烧穿 max_turns。
///
/// 权限：annotations readOnlyHint=false → L2 首读确认卡（C7 会话豁免），
/// 拍板口径见设计稿 §4「出库读全文按 L2 确认类裁决」。
library;

import 'dart:convert';

import '../llm/cloud/cloud_llm.dart';
import '../resources/resource_store.dart';
import 'agent_loop.dart';

/// 本地资源读取工具执行器。
class LocalResourceToolExecutor implements ToolExecutor {
  LocalResourceToolExecutor({required this.inner, required this.store});

  final ToolExecutor inner;
  final ResourceStore store;

  static const toolName = 'read_local_resource';

  /// 单次返回窗口（RC4 拍板 64KB；窗口截断逻辑在内核 readContentWindow）。
  static const readWindowBytes = kResourceReadWindowBytes;

  /// 工具声明（随 AgentLoop tools 下发；PermissionGateway.loadCatalog 须含
  /// 本清单——readOnlyHint=false 是 L2 裁决的 hint 源，§8 裁决双源）。
  static List<CloudToolSchema> toolSchemas() => [
        CloudToolSchema(
          name: toolName,
          description: '读取用户在对话中附加的本地资源文件内容（只读）。'
              '怎么用才对：入参 resource_id 取「用户附加资源」块中标注的 id；'
              '本工具单次最多返回前 64KB 内容，暂不支持分段与全文重试——'
              '返回尾部带「已截断」宿主注时，请基于已返回的内容作答，'
              '或提示用户把文件拆小后重新附加；'
              '严禁对同一 resource_id 重复调用本工具（重复调用只会得到相同的'
              '前 64KB，不会给出更多内容）。',
          parametersSchema: {
            'type': 'object',
            'properties': {
              'resource_id': {
                'type': 'string',
                'description': '资源 id（「用户附加资源」块中 resource_id= 的值）',
              },
            },
            'required': ['resource_id'],
          },
          annotations: {'readOnlyHint': false},
        ),
      ];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    if (call.name != toolName) return inner.execute(call);
    final String? resourceId;
    try {
      final args =
          jsonDecode(call.argumentsJson.isEmpty ? '{}' : call.argumentsJson);
      resourceId = args is Map ? args['resource_id'] as String? : null;
    } on FormatException {
      return const ToolExecutionResult(
        content: '读取失败(bad_request)：参数不是合法 JSON 对象。'
            'hint: resource_id 取「用户附加资源」块中标注的 id',
        isError: true,
      );
    }
    if (resourceId == null || resourceId.isEmpty) {
      return const ToolExecutionResult(
        content: '读取失败(bad_request)：缺少必填参数 resource_id。'
            'hint: 从「用户附加资源」块取 resource_id= 的值',
        isError: true,
      );
    }
    try {
      final w = await store.readContentWindow(resourceId,
          maxBytes: readWindowBytes);
      final note = w.truncated
          ? '\n\n[宿主注：文件超单次直读窗口（64KB），已截断；当前不支持分段'
              '读取，严禁对同一 resource_id 重复调用本工具——请基于已返回内容'
              '作答，或提示用户拆分文件。]'
          : '';
      return ToolExecutionResult(content: '${w.text}$note');
    } on ResourceStoreException catch (e) {
      // C-2：立即 isError 回填，禁挂起等待；hint 告知模型下一步（§5.4）。
      return ToolExecutionResult(
        content: '读取失败(${e.code})：${e.message}'
            '${e.hint == null ? '' : ' hint: ${e.hint}'}',
        isError: true,
      );
    }
  }
}
