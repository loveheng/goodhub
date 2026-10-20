/// `_meta.goodhub.visibility` 解析单测（SDK 0.2.0 线级口径）。
///
/// 锁住三条易踩坑约定：① 缺失 / 形状异常 / 未知取值一律 default-deny 归
/// private；② 标记收在 `_meta.goodhub` 子树下，`_meta` 顶层同名键不算；
/// ③ 解析只产出声明，**不做任何剔除或拦截**（那是聚合层的事）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/tool_visibility.dart';

void main() {
  group('parseToolVisibility', () {
    test('shared / private 短名（大小写与空白容忍）', () {
      expect(parseToolVisibility(const {
        'goodhub': {'visibility': 'shared'}
      }), ToolVisibility.shared);
      expect(parseToolVisibility(const {
        'goodhub': {'visibility': 'private'}
      }), ToolVisibility.private);
      expect(parseToolVisibility(const {
        'goodhub': {'visibility': ' Shared '}
      }), ToolVisibility.shared);
    });

    test('缺失 / 形状异常 / 未知取值一律 private（default-deny）', () {
      expect(parseToolVisibility(null), ToolVisibility.private);
      expect(parseToolVisibility(const {}), ToolVisibility.private);
      expect(parseToolVisibility(const {'goodhub': null}), ToolVisibility.private);
      expect(parseToolVisibility(const {
        'goodhub': {'visibility': null}
      }), ToolVisibility.private);
      expect(parseToolVisibility(const {
        'goodhub': {'visibility': 1}
      }), ToolVisibility.private);
      // 未知取值（未来正交维度如 hidden）不放大暴露面
      expect(parseToolVisibility(const {
        'goodhub': {'visibility': 'hidden'}
      }), ToolVisibility.private);
    });

    test('`_meta` 顶层 visibility 不生效（须在 goodhub 子树下）', () {
      expect(parseToolVisibility(const {'visibility': 'shared'}),
          ToolVisibility.private);
      expect(parseToolVisibility(const {
        'other': {'visibility': 'shared'}
      }), ToolVisibility.private);
    });

    test('goodhub 子树保留其他正交维度时不干扰解析', () {
      expect(parseToolVisibility(const {
        'goodhub': {
          'visibility': 'shared',
          'future': {'x': 1},
        },
        'vendor': {'y': 2},
      }), ToolVisibility.shared);
    });
  });
}
