# ADR-0004: хранилище паролей хостов на контроллере

- Статус: принято (2026-11-23)
- Задача: RH-019

## Решение

- Flutter plugin `flutter_secure_storage` 9.2.4 (lock: `flutter/pubspec.lock`), обёртка
  `flutter/lib/remote_hub/credentials/credential_vault.dart`.
  - Android: `encryptedSharedPreferences: true` (ключ в Android Keystore), `resetOnError: false` —
    повреждённое хранилище не стирается молча.
  - macOS: login keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, без iCloud
    (`synchronizable: false`). `useDataProtectionKeyChain: false`, потому что data protection
    keychain требует provisioning entitlement, которого нет у личной ad-hoc сборки.
  - Windows (`flutter_secure_storage_windows` 3.1.2): AES-ключ в Credential Manager пользователя
    (user scope), значения зашифрованы этим ключом.
- Ключ записи — `remotehub/device/<logicalDeviceId>`; в метаданных хранится только эта ссылка.
- Пароль сохраняется только при явной отметке владельца. Ошибка vault → повторный запрос пароля,
  подключение без пароля и plaintext fallback отсутствуют (SEC-18).
- Upstream-хранение отключено: при feature `remote_hub` `LoginConfigHandler` считает `remember=false`,
  поэтому `PeerConfig.password` никогда не пишется и при входе очищается.
- Пароль хоста генерируется на хосте: 32 символа из `Random.secure()` (буквы и цифры без похожих).

## Ограничения

- В Dart пароль — `String`; гарантированное обнуление всех копий не обещается (план 9.2).
- Пароль передаётся движку как preset текущей сессии (`session_add(password)`), в аргументы
  процесса и URL не попадает. На desktop окно viewer — тот же процесс (`desktop_multi_window`).
