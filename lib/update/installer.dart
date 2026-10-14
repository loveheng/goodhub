import 'package:open_filex/open_filex.dart';

/// 拉起系统安装器（Android 8+ 首次会引导授权「安装未知应用」）。
/// open_filex 自带 FileProvider，无需本仓另配 provider/path。
Future<void> installApk(String path) async {
  final result = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
  if (result.type != ResultType.done) {
    throw Exception('无法拉起安装器：${result.message}');
  }
}
