import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../devices/device_record.dart';

/// Raised when the platform vault cannot be read or written. The caller asks
/// the owner for the password again; it never falls back to plaintext and
/// never connects without a password (plan 13.5, SEC-18).
class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => 'VaultException: $message';
}

/// Minimal key/value secret store so tests can replace the platform plugin.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore-backed encrypted preferences, macOS Keychain (this device
/// only, no iCloud sync), Windows: AES key in the user's Credential Manager
/// (user scope) (plan 13.3, ADR 0004).
class PlatformSecretStore implements SecretStore {
  PlatformSecretStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
            resetOnError: false,
          ),
          // The login keychain: the data protection keychain needs a
          // provisioning entitlement that a personal, ad-hoc signed build
          // does not have.
          mOptions: MacOsOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
            synchronizable: false,
            useDataProtectionKeyChain: false,
          ),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
            synchronizable: false,
          ),
        );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Host passwords, stored only when the owner chose to, under the device's
/// `credentialRef` (keyed by the logical device id).
class CredentialVault {
  CredentialVault(this._store);

  final SecretStore _store;

  /// The stored password, or null if the owner did not store one.
  Future<String?> read(DeviceRecord device) async {
    final ref = device.credentialRef;
    if (ref == null) return null;
    try {
      final value = await _store.read(ref);
      return (value == null || value.isEmpty) ? null : value;
    } catch (e) {
      throw VaultException('read failed');
    }
  }

  Future<void> save(String deviceId, String password) async {
    if (password.isEmpty) throw VaultException('empty password');
    try {
      await _store.write(DeviceRecord.credentialRefFor(deviceId), password);
    } catch (e) {
      throw VaultException('write failed');
    }
  }

  Future<void> forget(String deviceId) async {
    try {
      await _store.delete(DeviceRecord.credentialRefFor(deviceId));
    } catch (e) {
      throw VaultException('delete failed');
    }
  }
}

const _passwordAlphabet =
    'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

/// 32 characters from a CSPRNG (plan 13.5), letters and digits only so the
/// engine accepts it and it can be typed on a phone keyboard.
String generateHostPassword({Random? random, int length = 32}) {
  final rng = random ?? Random.secure();
  return String.fromCharCodes(Iterable.generate(
      length,
      (_) =>
          _passwordAlphabet.codeUnitAt(rng.nextInt(_passwordAlphabet.length))));
}
