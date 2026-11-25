# Runbook: установка, удаление и откат Remote Hub (личные сборки)

Выполняет владелец. Не удаляйте рабочий способ доступа к хостам, пока новый путь не прошёл
приёмку (план 26.1).

## Сборка

```bash
export VCPKG_ROOT=~/dev/vcpkg-rh-osx        # отдельный root для macOS (vcpkgNote в build lock)
export RH_FLUTTER=~/dev/flutter-3.44.9/bin/flutter
export RH_TOOLS=~/dev/rh-tools               # flutter_rust_bridge_codegen 1.80.1 + cargo-expand
export PATH=~/dev/nasm-dl/nasm-2.16.03:$PATH
tools/build-macos.sh
```

```bash
export VCPKG_ROOT=~/dev/vcpkg-rh             # отдельный root для Android
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/28.2.13676358
export RH_FLUTTER=~/dev/flutter-3.24.5/bin/flutter RH_TOOLS=~/dev/rh-tools
export PATH=$RH_TOOLS/bin:$PATH
tools/build-android.sh --debug
```

Результат и SHA-256 — в `../remote-hub-build*/artifacts/` рядом с репозиторием. Каждая обёртка
сначала запускает `tools/doctor.py` и в конце `tools/verify-release.py`.

Релиз собирается только из чистого checkout (`tools/source_state.py`): при незакоммиченных или
неигнорируемых новых файлах `tools/build-macos.sh`, `tools/build-android.sh --release` и
`tools/build-windows.ps1` останавливаются, потому что такую сборку нельзя восстановить по commit.
Для проверки незакоммиченных изменений: `tools/build-macos.sh --allow-dirty`,
`tools/build-windows.ps1 -AllowDirty` или `tools/build-android.sh --debug` — артефакт получает метку
`<commit>-dirty`, и `verify-release.py --release`/`manifest` её не принимает.

## macOS

1. Скопируйте `Remote Hub.app` в `/Applications`. Сборка подписана ad-hoc: при первом запуске
   macOS может потребовать «Open» через контекстное меню. Не отключайте Gatekeeper.
2. Контроллер (основной MacBook): роль по умолчанию — controller, никаких прав Screen Recording
   не нужно.
3. Хост: см. `host-serve-setup.md`.
4. После пересборки с другой подписью macOS может заново запросить права хоста: это ожидаемо.

Удаление: «Stop access», затем удалить `/Applications/Remote Hub.app`. Настройки:
`~/Library/Preferences/com.carriez.RemoteHub/`, пароли контроллера — в Keychain записи
`remotehub/device/<id>` (удаляйте только их, не весь Keychain). Serve — отдельной командой `off`.

## Android (Pixel 6)

1. Установите APK средствами Android (разрешение источника даёт владелец).
2. Debug-сборка подписана debug-ключом. Для личного release нужен собственный ключ владельца:
   `key.properties` (с абсолютным путём `storeFile` к keystore) лежит вне репозитория и вне
   `src/` staging-каталога, который пересоздаётся при каждой сборке: по умолчанию
   `$RH_BUILD_DIR/signing/key.properties`, или путь в `RH_ANDROID_KEY_PROPERTIES`. Никогда в Git.
   `tools/build-android.sh --release` без него останавливается, сам копирует файл в staging, а
   `verify-release.py apk --release` отклоняет APK, подписанный debug-ключом.
3. Смена ключа подписи требует удаления приложения (данные и сохранённые пароли теряются).

## Откат

- macOS: сохраните предыдущий `Remote Hub.app` (и `build-info-macos.json`) перед установкой новой
  версии; откат — заменить bundle обратно. Метаданные устройств (schema v1) совместимы; при ошибке
  чтения файл не перезаписывается, рядом создаётся `*.bak`.
- Android: установка меньшего versionCode поверх не поддерживается; откат = удаление и установка
  предыдущего APK с потерей локальных данных (пароли вводятся заново).
