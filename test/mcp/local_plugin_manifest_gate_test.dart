// §5 同签名门禁 · goodhub Manifest 前置断言（#9 §3-1 / §5 D.2 前置）。
//
// signature 权限（protectionLevel="signature"）语义下，缺 <uses-permission> 或
// <queries> 声明 → bindService 直接抛 SecurityException（无弹窗、无降级）。该失败
// 目前只有真机 e2e（goodshare_binder_e2e_test.dart）会晚失败；本测试把 #9 §3-1 与
// §5 D.2 的 Manifest 前置下沉到 flutter 快速门禁（CI），Manifest 一被误删/误改即刻红灯。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // goodhub 仅请求 goodshare 声明的 signature 权限（#9 §3：不自声明 <permission>）。
  const perm = 'com.zzh.goodhub.permission.MCP_SERVER';
  // 本地插件发现 / bind 的目标 Action（thirdconnect T-trans-4 §1.2.4）。
  const action = 'com.zzh.goodhub.action.MCP_SERVER';

  late String manifest;
  setUpAll(() {
    final f = File(
        '${Directory.current.path}/android/app/src/main/AndroidManifest.xml');
    expect(f.existsSync(), isTrue,
        reason: '应能在包根定位 main/AndroidManifest.xml（flutter test CWD=包根）');
    manifest = f.readAsStringSync();
  });

  group('goodhub Manifest §5 D.2 前置', () {
    test('声明 <uses-permission ...MCP_SERVER>（§3-1，否则 bind 抛 SecurityException）', () {
      expect(
        RegExp('<uses-permission[^>]*android:name="${RegExp.escape(perm)}"')
            .hasMatch(manifest),
        isTrue,
        reason: '缺 <uses-permission android:name="$perm"> → signature 权限拒绝 bind',
      );
    });

    test('<queries> 内声明 MCP_SERVER Action（包可见性，扫描/绑定目标前提）', () {
      final qStart = manifest.indexOf('<queries>');
      final qEnd = manifest.indexOf('</queries>');
      expect(qStart >= 0 && qEnd > qStart, isTrue, reason: '应存在 <queries> 块');
      final queries = manifest.substring(qStart, qEnd);
      expect(
        RegExp('<action[^>]*android:name="${RegExp.escape(action)}"')
            .hasMatch(queries),
        isTrue,
        reason: '<queries> 内缺 MCP_SERVER Action → 本地插件扫描/绑定目标不可见',
      );
    });

    test('goodhub 未自声明 <permission ...MCP_SERVER>（§3：仅请求，不声明）', () {
      // 注意：'<permission' 不匹配 '<uses-permission'（前者 '<' 紧邻 permission，
      // 后者 '<' 后为 uses-），故不会把 uses-permission 误判为自声明。
      expect(
        RegExp('<permission[^>]*android:name="${RegExp.escape(perm)}"')
            .hasMatch(manifest),
        isFalse,
        reason: '宿主不应自声明 <permission>（声明方是 goodshare），否则与 §3 约定相悖',
      );
    });
  });
}
