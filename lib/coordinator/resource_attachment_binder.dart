/// 资源附件绑定（resource-center M1-T3）：把对话附件登记进 run 级 `$ref`
/// 池并产出注入上下文的元信息块。
///
/// 规格 SSOT：docs/design/resource-center.md §2。用法约定（评审四轮定稿）：
/// - **句柄只作上下文合流记账，不作工具入参**——HydratingExecutor 会把参数
///   里的 `$ref` 句柄整读替换为原文（击穿 RC4 64KB 窗口），故
///   `read_local_resource` 入参用 `resource_id`（uuid），句柄供人审计与
///   ref 管线合流；
/// - 全文经 [RefStore.put] payload 介质落池（run 级，Session 即焚）——资源
///   中心库是持久底座，池是会话期注水通道，合流不合并；
/// - 返回的 footer 文本由窗口拼进 userPrompt 前部（模型先见附件再见图）。
library;

import '../resources/resource_store.dart';
import 'ref_store.dart';

/// 附件元信息（窗口层只持此 record，不触 resources 域类型）。
typedef ResourceAttachment = ({String id, String name});

/// 绑定全部附件：读全文 → 落池 → 拼元信息块。
///
/// 单个附件读取失败（如运行中被删）：该条降级为「已失效」行，不阻断其余
/// 附件（非数据面：库才是事实源，会话期丢附件只损本轮可用性，明示即可）。
Future<String> bindResourceAttachments(
  ResourceStore store,
  RefStore refStore,
  List<ResourceAttachment> attachments, {
  String serverId = 'local',
}) async {
  if (attachments.isEmpty) return '';
  final lines = <String>[];
  for (final a in attachments) {
    final entry = store.byId(a.id);
    if (entry == null) {
      lines.add('- 附件《${a.name}》已失效（资源不存在或已删除）');
      continue;
    }
    try {
      final content = await store.readContent(a.id);
      final handle = await refStore.put(
        serverId: serverId,
        payload: content,
        resourceUri: entry.resourceUri,
      );
      lines.add(
        '- 附件《${entry.name}》（${_fmtBytes(entry.sizeBytes)}）：'
        'resource_id=${entry.id}，原文句柄 $handle。'
        '需要全文时调用 read_local_resource（入参 resource_id 取本值）',
      );
    } on Object {
      lines.add('- 附件《${a.name}》读取失败，本轮不可用');
    }
  }
  return '<用户附加资源>\n${lines.join('\n')}\n</用户附加资源>\n\n';
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
