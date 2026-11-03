// GGUF header 诊断探针（诊断面，元数据管线 S0 spike）：打印指定 GGUF 文件
// 头部可读元数据（零权重加载——只消费 KV 区字节）。真机/导入前人工排查用：
//   dart run tool/gguf_header_probe.dart <path.gguf>
library;

import 'dart:io';

import 'package:goodhub/llm/on_device_gguf_header.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/gguf_header_probe.dart <path.gguf>');
    exitCode = 2;
    return;
  }
  try {
    final h = readGgufHeader(File(args.first));
    stdout.writeln('version=v${h.version} tensors=${h.tensorCount} '
        'kv=${h.metadata.length}');
    stdout.writeln('contextLength=${h.contextLength ?? 'unknown'}');
    final tpl = h[GgufKeys.chatTemplate];
    stdout.writeln('chatTemplate=${tpl is String ? '${tpl.length} chars' : 'unknown'}');
    for (final key in [GgufKeys.architecture, GgufKeys.fileType,
      GgufKeys.quantizationVersion]) {
      stdout.writeln('$key=${h[key] ?? 'unknown'}');
    }
    for (final e in h.metadata.entries) {
      final v = e.value;
      final String shown;
      if (v is String && v.length > 80) {
        shown = '${v.substring(0, 80)}…';
      } else if (v is List) {
        shown = '[${v.length} items: ${v.take(3).join(', ')}…]';
      } else {
        shown = '$v';
      }
      stdout.writeln('  ${e.key} = $shown');
    }
  } on GgufParseException catch (e) {
    stderr.writeln('FAIL: $e');
    exitCode = 1;
  }
}
