/// 网关入站安全闭环（G3）单测：L1/L2 裁决放行与拒绝、45s 超时熔断（TC12）、
/// 会话豁免（C7）、PII 出站 fail-closed 遮蔽、ops.log 入站审计。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/gateway/gateway_security.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/sandbox/memory_store.dart';

class _FakeDelegate implements GateDelegate {
  _FakeDelegate(this.onConfirm);

  final Future<GateDecision> Function(ToolPendingConfirmation pending)
      onConfirm;
  var calls = 0;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async {
    calls++;
    return onConfirm(pending);
  }
}

MemoryStore _tempStore() {
  final dir = Directory.systemTemp.createTempSync('gw-sec-test');
  return MemoryStore(dir: dir);
}

void main() {
  test('L1（readOnlyHint）静默放行：不经确认卡直达执行', () async {
    final delegate = _FakeDelegate((_) async => const GateDecision(approved: true));
    var ran = 0;
    final sec = GatewaySecurity(delegate: delegate);
    final r = await sec.guard(
      serverId: 'demo',
      tool: 'demo__read',
      annotations: {'readOnlyHint': true},
      argumentsJson: '{}',
      run: () async {
        ran++;
        return const GatewayToolResult(content: 'ok', isError: false);
      },
    );
    expect(ran, 1);
    expect(delegate.calls, 0);
    expect(r.isError, false);
  });

  test('L2 无确认界面（无人值守）一律拒绝，且不执行', () async {
    var ran = 0;
    final sec = GatewaySecurity(delegate: null);
    final r = await sec.guard(
      serverId: 'demo',
      tool: 'demo__write',
      annotations: const {'readOnlyHint': false}, // 显式写 hint（未声明一律 L1）
      argumentsJson: '{}',
      run: () async {
        ran++;
        return const GatewayToolResult(content: 'ok', isError: false);
      },
    );
    expect(ran, 0);
    expect(r.isError, false); // 拒绝≠系统错误（§12 同口径）
    expect(r.content, contains('user_rejected'));
  });

  test('L2 批准并记住 → 同工具二次调用免确认（C7）', () async {
    final delegate = _FakeDelegate(
        (_) async => const GateDecision(approved: true, rememberSession: true));
    var ran = 0;
    final sec = GatewaySecurity(delegate: delegate);
    Future<GatewayToolResult> call() => sec.guard(
          serverId: 'demo',
          tool: 'demo__write',
          annotations: const {'readOnlyHint': false},
          argumentsJson: '{}',
          run: () async {
            ran++;
            return const GatewayToolResult(content: 'ok', isError: false);
          },
        );
    await call();
    await call();
    expect(delegate.calls, 1); // 第二次凭会话豁免
    expect(ran, 2);
    sec.resetSessionGrants();
    await call();
    expect(delegate.calls, 2); // 停服清豁免后重新确认
  });

  test('L2 确认超时（TC12）主动拒绝，不执行', () async {
    final delegate = _FakeDelegate((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return const GateDecision(approved: true);
    });
    var ran = 0;
    final sec = GatewaySecurity(
      delegate: delegate,
      consentTimeout: const Duration(milliseconds: 50),
    );
    final r = await sec.guard(
      serverId: 'demo',
      tool: 'demo__write',
      annotations: const {'readOnlyHint': false},
      argumentsJson: '{}',
      run: () async {
        ran++;
        return const GatewayToolResult(content: 'ok', isError: false);
      },
    );
    expect(ran, 0);
    expect(r.content, contains('user_rejected'));
    expect(r.content, contains('超时'));
  });

  test('PII 出站过滤：手机号遮蔽为占位符', () async {
    final sec = GatewaySecurity();
    final r = await sec.guard(
      serverId: 'demo',
      tool: 'demo__read',
      annotations: {'readOnlyHint': true},
      argumentsJson: '{}',
      run: () async => const GatewayToolResult(
        content: '联系人电话 13800138000，请查收',
        isError: false,
      ),
    );
    expect(r.content, isNot(contains('13800138000')));
    expect(r.content, contains('[手机号1]'));
  });

  test('ops.log 入站审计：拒绝与成功均落流水（server=gateway）', () async {
    final store = _tempStore();
    final delegate = _FakeDelegate(
        (_) async => const GateDecision(approved: false, reason: '不要'));
    final sec = GatewaySecurity(delegate: delegate, opsLog: store);
    await sec.guard(
      serverId: 'demo',
      tool: 'demo__write',
      annotations: const {'readOnlyHint': false},
      argumentsJson: '{}',
      run: () async => const GatewayToolResult(content: 'x', isError: false),
    );
    await sec.guard(
      serverId: 'demo',
      tool: 'demo__read',
      annotations: {'readOnlyHint': true},
      argumentsJson: '{}',
      run: () async => const GatewayToolResult(content: 'y', isError: false),
    );
    final line1 = await _lastLine(store);
    final line2 = await _lastLine(store, skip: 1);
    expect(line1, contains('"server":"gateway"'));
    expect(line1, contains('demo__read'));
    expect(line1, contains('"ok":true'));
    expect(line2, contains('demo__write'));
    expect(line2, contains('user_rejected'));
  });
}

Future<String> _lastLine(MemoryStore store, {int skip = 0}) async {
  final f = File('${store.dir.path}/ops.log');
  final lines = await f.readAsLines();
  return lines[lines.length - 1 - skip];
}
