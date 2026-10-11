/// 系统安全存储抽象（coding-standards §1 core/security）：
/// 密钥类数据（BYOK API Key、Bearer Token）的读写接口，平台实现经依赖注入装配。
///
/// Android 后端 = flutter_secure_storage（EncryptedSharedPreferences / Keystore，
/// architecture §1 密钥纪律）；测试与无安全存储环境用 [InMemorySecureKeyValue]。
library;

abstract interface class SecureKeyValue {
  /// 读键值；缺失返回 null。存储层异常向上抛（显式错误传递，禁吞）。
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 内存实现：单测注入与无安全存储环境的兜底位。
/// 不做持久化——生产环境严禁使用（密钥纪律）。
class InMemorySecureKeyValue implements SecureKeyValue {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}
