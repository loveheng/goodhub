/// [SecureKeyValue] 平台实现：flutter_secure_storage。
/// Android = EncryptedSharedPreferences（Android Keystore 体系，architecture §1）；
/// iOS = Keychain（双端纪律 N1：接口驱动，业务层只认 [SecureKeyValue] 抽象）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_key_value.dart';

class FlutterSecureKeyValue implements SecureKeyValue {
  FlutterSecureKeyValue({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
