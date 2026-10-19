/// elicitation 反向请求消费面（MCP 2025-06-18 `elicitation/create`）。
///
/// server 经反向请求向宿主收集结构化输入（如确认参数、补充信息），宿主以
/// 交互卡呈现 `requestedSchema` 表单，用户填写后回 `accept` + content，或
/// `decline`。client 能力声明见 [McpClient.elicitationEnabled]；未声明时
/// server 不应发起，发起则 client 优雅 decline（不悬挂）。
library;

import '../core/errors/mcp_error.dart';

/// elicitation 单字段描述（由 `requestedSchema.properties` 解析）。
class ElicitationField {
  const ElicitationField({
    required this.name,
    required this.type,
    this.title,
    this.description,
    this.enumValues,
  });

  final String name;

  /// JSON Schema 类型：string / number / integer / boolean（其余按 string 兜底）。
  final String type;
  final String? title;
  final String? description;

  /// 枚举约束（string + `enum` 列表）→ 下拉选择。
  final List<String>? enumValues;

  /// 是否数值型（number / integer）。
  bool get isNumeric => type == 'number' || type == 'integer';

  /// 是否布尔型。
  bool get isBoolean => type == 'boolean';
}

/// server 发起的 elicitation 请求。
class ElicitationRequest {
  ElicitationRequest({required this.message, required this.schema})
      : fields = _parseFields(schema);

  /// 提示语（server 想问用户什么）。
  final String message;

  /// 原始 requestedSchema（JSON Schema object）。
  final Map<String, Object?> schema;

  /// 解析出的可填字段（仅支持 string/number/integer/boolean + enum）。
  final List<ElicitationField> fields;

  /// 必填字段名集合（schema.required）。
  Set<String> get required => <String>{
        for (final r in (schema['required'] is List
            ? schema['required'] as List
            : const <Object>[]))
          if (r is String) r,
      };

  static List<ElicitationField> _parseFields(Map<String, Object?> schema) {
    final props = schema['properties'];
    if (props is! Map) return const [];
    final out = <ElicitationField>[];
    for (final entry in props.entries) {
      final def = entry.value;
      if (def is! Map) continue;
      final type = def['type'];
      final enumValues = def['enum'];
      out.add(ElicitationField(
        name: entry.key,
        type: type is String ? type : 'string',
        title: def['title'] is String ? def['title'] as String : null,
        description: def['description'] is String
            ? def['description'] as String
            : null,
        enumValues: enumValues is List
            ? enumValues.whereType<String>().toList()
            : null,
      ));
    }
    return out;
  }

  /// 从反向请求 params 构造（MCP `elicitation/create`）。
  factory ElicitationRequest.fromParams(Object? params) {
    final p = params is Map<String, Object?>
        ? params
        : const <String, Object?>{};
    final message = p['message'];
    final schema = p['requestedSchema'];
    if (message is! String || schema is! Map<String, Object?>) {
      throw const McpRpcException(
          -32602, 'elicitation/create 缺少 message/requestedSchema');
    }
    return ElicitationRequest(message: message, schema: schema);
  }
}

/// 宿主对 elicitation 的应答。
class ElicitationAnswer {
  const ElicitationAnswer(
      {required this.accepted, this.content, this.reason});

  final bool accepted;

  /// accepted 时匹配 schema 的输入内容（键 = 字段名）。
  final Map<String, Object?>? content;

  /// declined 时的可选理由。
  final String? reason;

  /// 序列化为 MCP `elicitation/create` result 形状。
  Map<String, Object?> toResult() => accepted
      ? {'action': 'accept', 'content': content ?? const <String, Object?>{}}
      : {'action': 'decline', if (reason != null) 'reason': reason};

  static ElicitationAnswer decline([String? reason]) =>
      ElicitationAnswer(accepted: false, reason: reason);

  static ElicitationAnswer accept(Map<String, Object?> content) =>
      ElicitationAnswer(accepted: true, content: content);
}

/// elicitation 委托（UI 实现；测试注入假件）。null = 无人值守，按 decline 处理。
abstract interface class ElicitationDelegate {
  /// 呈现表单并收集用户输入；返回 accept + content 或 decline。
  Future<ElicitationAnswer> request(ElicitationRequest req);
}

/// [McpClient.onElicitation] 适配器工厂：把 delegate 适配为 client 反向请求回调。
/// 入参为 server 反向请求的原始 params（[Object?]，由 [ElicitationRequest.fromParams] 解析）。
Future<Map<String, Object?>?> Function(Object? params)
    elicitationRequestHandler({required ElicitationDelegate delegate}) {
  return (params) async {
    final req = ElicitationRequest.fromParams(params);
    final ans = await delegate.request(req);
    return ans.toResult();
  };
}
