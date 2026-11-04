// GenerationConfig 约束解码承载回归钉（task-capability W3 · S17b，D4 前提）。
//
// 红线：① 缺省 null = 无约束（存量调用零变化——Expand 加性字段）；②
// LlmResponseFormat 通道形状单源（type/value 键面与 Kotlin GenerationParams
// 键名同步，双端对齐钉在 SessionTicketWire.kt 注释 + SessionTicketWireTest）。
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/llm/on_device_engine.dart';

void main() {
  group('S17b GenerationConfig 约束解码承载', () {
    test('缺省 responseFormat = null（无约束，存量调用零变化）', () {
      const c = GenerationConfig();
      expect(c.responseFormat, isNull);
    });

    test('显式声明 json/regex 规格可承载（通道形状 = type/value 键面）', () {
      const js = LlmResponseFormat.jsonSchema('{"type":"object"}');
      expect(js.toChannelArgs(), {'type': 'json', 'value': '{"type":"object"}'});
      const re = LlmResponseFormat.regex(r'^[a-z]+$');
      expect(re.toChannelArgs(), {'type': 'regex', 'value': r'^[a-z]+$'});
      const c = GenerationConfig(responseFormat: js);
      expect(c.responseFormat, same(js));
    });

    test('GenerationConfig 等价性不被 responseFormat 缺席破坏（旧构造仍可用）',
        () {
      const a = GenerationConfig();
      const b = GenerationConfig();
      expect(a.maxTokens, b.maxTokens);
      expect(a.temperature, b.temperature);
      expect(a.topP, b.topP);
      expect(a.stopSequences, b.stopSequences);
    });
  });
}
