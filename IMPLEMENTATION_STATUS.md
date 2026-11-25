# Remote Hub — статус реализации

План: `REMOTE_HUB_IMPLEMENTATION_PLAN_RU.md` (передан владельцем, в репозиторий не копируется).
Backlog и карточки задач: [`TASKS.md`](TASKS.md).

## Обозначения

```text
IMPLEMENTED     — код написан;
BUILD_PASSED    — конкретная сборка успешно выполнена;
TEST_PASSED     — конкретный тест реально выполнен;
NOT_RUN         — тест не запускался;
BLOCKED         — известная причина блокировки;
ACCEPTED        — выполнены критерии приёмки этапа.
```

Статус ставится только по факту: команда запущена, результат записан ниже. Отсутствие физического
устройства — это `NOT_RUN`/`BLOCKED`, а не `PASS`.

## Решения владельца (раунд 2, 2026-11-23)

1. Место на Mac освобождено — нативные сборки выполняются на основном Mac.
2. База — текущий `master` (`a3b42dfb90dc4742dfdf69b4281c1a73118eb8c0`), без release tag.
3. Проверки на устройствах владельца (инвентаризация, шесть пар, Serve на хостах, soak) отложены.

## Этапы

| Этап | Статус | Причина / следующий шаг |
|---|---|---|
| M0 — сценарий на реальных устройствах | BLOCKED | Отложено владельцем |
| M1 — воспроизводимые сборки | IMPLEMENTED; macOS — BUILD_PASSED, Android debug APK — BUILD_PASSED, см. журнал | Windows-сборка не запускалась (нет Windows-сборщика); release APK требует ключа владельца; rollback не проверен |
| M2 — первая защищённая сессия | IMPLEMENTED; loopback e2e протокола — см. журнал | Сессия с экраном и вводом через Serve на реальном хосте NOT_RUN |
| M3 — закрыть обходные пути | IMPLEMENTED; egress/listener собранного приложения — `docs/reports/M3-security-review.md` | Отрицательная сетевая матрица на устройствах NOT_RUN |
| M4 — UI и vault | IMPLEMENTED | Ручная проверка UI NOT_RUN |
| M5 — Pixel и ввод | IMPLEMENTED (upstream viewer) | На Pixel NOT_RUN |
| M6 — установка и onboarding | IMPLEMENTED (панель хоста, runbook) | На хостах NOT_RUN |
| M7 — приёмка и релиз | NOT_RUN | Отложено владельцем |
| M8 — дополнительные функции | NOT_RUN | Только после M7 |

Ни один этап не `ACCEPTED`: критерии приёмки требуют проверок на устройствах.

## Что реализовано

### Сборка Remote Hub = cargo feature `remote_hub` + `--dart-define=REMOTE_HUB=true`

Без feature выполняется прежний код upstream. С feature ограничения действуют всегда, а не по
опции (ADR-0003). Список хуков в upstream-файлах — `docs/upstream-map.md`.

### Контроллер (ADR-0005)

- `Client::_start` → `remote_hub::dial`: только зарегистрированный endpoint, TLS bridge с проверкой
  сертификата до создания loopback-порта, затем движок подключается к `engine_dial_address()`.
  Нет direct IP, rendezvous, relay, punch, WebRTC.
- Один bridge = одна сессия: когда первый сокет движка (сама сессия) закрывается с любой стороны,
  bridge закрывает loopback-порт и все дополнительные каналы; повторно использовать его нельзя.
  Переподключение идёт через новый `dial` и новый bridge.
- Engine peer id = `rh` + UUID устройства: настройки upstream не привязаны к временному порту.
- Upstream не сохраняет пароль (`remember=false`); пароль — только в vault по выбору (ADR-0004).
- Переподключение: upstream-диалог с задержками `ReconnectWindow` (1/2/4/8/15 с, окно 90 с), без
  повтора для TLS/HOST/AUTH ошибок (native `check_if_retry` + Dart).
- Android: background закрывает сессию; manifest controller-only (без MediaProjection,
  Accessibility, микрофона, overlay, автозапуска, `rustdesk://`); backup и перенос
  между устройствами отключены (`allowBackup=false`, `dataExtractionRules` исключают всё) —
  шифротекст vault без ключа Keystore исходного устройства бесполезен (13.7).
- Импорт/экспорт списка компьютеров (13.2, RH-020): экспорт — копирование текста без
  секретов; импорт — вставка или `.json` ≤ 64 KiB, предпросмотр всех имён и адресов,
  добавленные не подтверждены и не подключаются, существующие записи не заменяются.
- `APP_NAME=RemoteHub`: свой каталог конфигурации и IPC, нет конфликта с установленным RustDesk.

### Хост (ADR-0003)

- `start_all` заменён: нет NAT test, sync, updater, LAN, rendezvous. Listener только
  `127.0.0.1:22118`, только при `remote-hub-role=host` и `remote-hub-host-enabled=Y`.
- «Stop access» закрывает listener и все сессии; состояние сохраняется. Кнопка считается
  выполненной только после подтверждения процесса хоста по IPC (`Data::RemoteHubSetAccess`):
  listener закрыт и все принятые им сессии завершились. Нет связи с процессом хоста или нет
  подтверждения за 10 с — панель оставляет «ON» и показывает ошибку. Смена пароля хоста идёт
  так же: новый пароль задаётся и показывается только после подтверждённой остановки (вместо
  прежней фиксированной паузы 3 с); «Stop being a host» без подтверждения роль не снимает.
- «Allow access» по IPC действует только после того, как UI подтвердил получение успешного ответа
  (`Data::RemoteHubAccessCommit`). Нет подтверждения за 5 с (ответ потерян, UI не дождался,
  соединение закрыто) — процесс хоста сам снова закрывает доступ; второй IPC-запрос для отката не
  нужен. Панель показывает «Remote access: ON», пока listener хоста принимает или пытается
  принимать соединения, независимо от локальной копии настройки UI.
- Клиент Remote Hub не читает и не пишет хэш пароля в peer config и не берёт его из личной
  адресной книги: пароли только в хранилище ОС; старый хэш в peer config игнорируется и стирается
  при следующем входе.
- Показ нового пароля и разрешение доступа согласованы между всеми окнами приложения через
  native-аренду (`remote_hub::PasswordDisplay`): пароль меняется и показывается только под
  живой арендой, которую нельзя взять, пока доступ включён или включается; «Allow access» в любом
  окне отклоняется, пока аренда жива. Панель продлевает аренду каждые 2 с и сама скрывает пароль
  за 2 с до её истечения (10 с); «Hide password», «Allow access» в этом окне и закрытие панели
  снимают её сразу, более новый пароль заменяет прежнюю аренду.
- Аренды хранит процесс, в котором работает listener хоста (служба). Панели других процессов
  (каждый запущенный экземпляр приложения) берут, продлевают и снимают аренду по IPC
  (`Data::RemoteHubPasswordDisplay`), а служба отклоняет «Allow access», пришедший по IPC, пока
  аренда жива, и не выдаёт новую, пока allow выполняется. Поэтому пароль, показанный в одном
  экземпляре, блокирует разрешение доступа из любого другого. Служба недоступна или не ответила
  за 0,5 с — аренды нет, пароль не показывается (при продлении — скрывается).
- Неаутентифицированных входов хост держит не больше 4 (раздел 7.5): Serve подключается к
  loopback-listener с одного адреса `127.0.0.1`, поэтому при feature `remote_hub` лимит upstream
  на адрес (16) заменён на `remote_hub::policy::UNAUTHENTICATED_SESSION_CAP = 4`; пятый вход
  отклоняется, ожидающие не вытесняются.
- Панель хоста показывает собственное состояние listener-цикла (`listening`, `stopped`,
  `port_unavailable`, `not_running`), а не пробу порта: процесс хоста отвечает по IPC
  (`Data::RemoteHubListener`). Запрос идёт в уже существующем цикле IPC-статуса UI
  (`ui_interface::check_connect_status_`, раз в секунду); панель читает последний ответ и не
  создаёт ни runtime, ни соединения. Нет связи с процессом хоста — `not_running`. Если 22118 занят другой программой, панель пишет «Port 22118 is used
  by another program», а не «Accepting».
- Вход: только remote desktop, только постоянный пароль (без click approval и одноразового пароля,
  без скрытого CM), один контроллер (`HOST_BUSY`). Lease контроллера захватывается в том же
  синхронном шаге, что и авторизация, поэтому одновременные входы не получают управление вдвоём.
- После входа принимаются только мышь/указатель/клавиатура, выбор дисплея, качество, обновление
  видео; остальное отбрасывается на приёме. Опции сессии (и в `Misc`, и в `LoginRequest.option`)
  сужаются до качества изображения, FPS, кодеков и показа курсора: блокировка после сессии,
  privacy mode, block input, буфер обмена, файлы, звук и прочее до upstream не доходят. Выбор
  дисплея не может сменить разрешение (`width`/`height` обнуляются).
- При закрытии сессии хост отпускает удерживаемые клавиши и кнопки мыши.

### Flutter

`flutter/lib/remote_hub/`: главный экран «My computers» с реальными статусами, форма устройства
(IPv4 tailnet, полное MagicDNS-имя, порт 21118, пароль, явный выбор сохранения, подтверждение
владельцем; смена адреса или имени снимает и подтверждение, и сохранённый пароль — запись vault
удаляется, пароль нужно ввести заново; снятая галочка сохранения тоже удаляет запись; пароль,
введённый в форме, в vault не пишется — он хранится в памяти до следующего подключения и, если
выбрано сохранение, попадает в vault только после того, как хост принял вход с ним; до этого
прежний сохранённый пароль остаётся), запрос пароля, vault, панель «This computer» для хоста, диагностика с маскированием.
Если vault не смог удалить пароль, который должен исчезнуть, запись устройства не меняется:
удаление устройства (`removeDevice`) оставляет его в списке, а правка (`applyDeviceEdit` → `null`)
не применяется — владелец может повторить действие, и в системном vault не остаётся «осиротевшего»
пароля за записью, которая говорит «пароля нет».
Пароль, введённый при подключении с галочкой «Save», пишется в vault только после того, как хост
принял вход именно с этим паролем (`remote_hub_login_accepted`: native сравнивает salted hash
принятого входа); неверный пароль или пароль, введённый уже в окне viewer, не сохраняется.
Стадия подключения на карточке завершается по любому принятому входу (`remote_hub_login_done`),
в том числе когда владелец исправил пароль в окне viewer; сохранение по-прежнему требует, чтобы
хост принял именно пароль, отмеченный «Save».
Кнопка «Delete log» в диагностике очищает журнал в памяти и удаляет файлы нативного лога всех
процессов Remote Hub (`remote_hub_delete_logs`: ротированные `*.log` удаляются, текущий файл
логгера, открытый в режиме дозаписи, обнуляется).
Viewer открывается без пароля: UI передаёт пароль в память native-процесса
(`remote_hub_stage_password`), а `session_add` забирает его один раз (не дольше 60 с). Так пароль
не попадает в JSON аргументов окна desktop, который upstream печатает при старте окна.
Ошибки чтения локального хранилища списка устройств (нет каталога, нет прав, не файл) показываются
на экране с кнопкой «Try again»; хранилище при этом не открывается и ничего не перезаписывается.
Ошибка записи показывается сообщением, изменение не применяется. Карточка устройства после
проверки TLS пишет «Network path: not checked»: приложение не проверяет маршрут Tailscale.
Viewer, видео, ввод, тачпад (upstream mouse mode) и IME — upstream.
Стадия подключения следует за native dial (`remote_hub_dial_stage`), а не за открытием окна:
«Establishing a secure connection» держится, пока bridge не проверил сертификат и движок не
подключился; только затем «Checking the password». Ошибка TLS/конфигурации завершает попытку
(код показывается на карточке), сетевая ошибка показывается рядом со стадией, пока viewer
переподключается.
Сохранённые настройки устройства (качество, режим указателя, дисплей) перед каждым подключением
записываются в настройки peer, которые читает viewer (`remote_hub_apply_viewer_preferences`);
качество и режим указателя меняются в форме устройства. Дисплей выбирается по имени, которое
сообщает хост; если его нет — выбирается другой с сообщением. Выбор монитора в viewer пока не
сохраняется обратно в запись устройства.

Удалены несвязанные модели прошлого раунда: `sessions/session_state.dart`,
`input/pressed_input_tracker.dart` (состояния ведёт upstream-сессия, ввод отпускает хост).

### Сборка

`config/build-lock.json` (commit, submodule, toolchains, vcpkg, NASM, codegen, TLS-зависимости),
`tools/doctor.py`, `tools/build-macos.sh`, `tools/build-android.sh`, `tools/build-windows.ps1`,
`tools/verify-release.py`, `tools/android_controller_manifest.py`. Обёртки копируют исходники в
staging-каталог и не меняют репозиторий.

## Журнал проверок

| Дата | Проверка | Окружение | Результат |
|---|---|---|---|
| 2026-11-23 | `tools/doctor.py --target macos-arm64` | основной Mac, macOS 26.6.2 arm64, Xcode 27.0 | PASSED (все инструменты по lock) |
| 2026-11-23 | vcpkg `9e593bb` arm64-osx (aom, opus, libvpx, libyuv, libjpeg-turbo, ffmpeg) | то же, NASM 2.16.03 | BUILD_PASSED |
| 2026-11-23 | vcpkg `9e593bb` arm64-android | NDK r28c | BUILD_PASSED |
| 2026-11-23 | `flutter_rust_bridge_codegen` 1.80.1 на `src/flutter_ffi.rs` (staging, Flutter 3.44.9) | Rust 1.75 | PASSED; сигнатуры `remoteHub*` совпали с web-заглушками |
| 2026-11-23 | `cargo check --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub` (staging) | Rust 1.81 | PASSED (новых предупреждений нет после исправления `remember`) |
| 2026-11-23 | `cargo test --locked --lib --features …,remote_hub remote_hub` (staging, debug) | Rust 1.81 | TEST_PASSED: 11 passed, включая `remote_hub::e2e::tls_bridge_to_restricted_host_end_to_end` |
| 2026-11-23 | `cargo test -p remote_hub` | Rust 1.75 | TEST_PASSED: 13 passed |
| 2026-11-23 | `flutter test test/remote_hub_devices_test.dart test/remote_hub_session_test.dart` | Flutter 3.24.5 | TEST_PASSED: 16 passed |
| 2026-11-23 | `flutter test test/remote_hub_device_form_test.dart` (новый: смена адреса снимает подтверждение владельца) | Flutter 3.24.5 | TEST_PASSED: 2 passed; без исправления первый тест падал (`Expected: false, Actual: true`) |
| 2026-11-23 | `flutter analyze lib/remote_hub test/remote_hub_devices_test.dart test/remote_hub_session_test.dart` (с локально сгенерированным, не коммитимым bridge) | Flutter 3.24.5 | PASSED: «No issues found» |
| 2026-11-23 | `flutter analyze` тех же файлов вместе с `lib/main.dart`, `lib/models/model.dart`, `lib/web/bridge.dart` | Flutter 3.24.5 | 0 errors, 0 warnings; 22 info в этих upstream-файлах |
| 2026-11-23 | `rustfmt --check` новых файлов; хуки не добавляют rustfmt-расхождений в upstream-файлы | Rust 1.81 | PASSED |
| 2026-11-23 | `tools/build-macos.sh`: staging, Flutter 3.44 patch, codegen, `cargo build --locked --release --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub` | основной Mac, Rust 1.81 | BUILD_PASSED (cargo); шаг Xcode упал: Pods < macOS 12.0 под Xcode 27, затем upstream bundle id в pbxproj — скрипт исправлен |
| 2026-11-23 | Остаток шагов скрипта после исправления (flutter build macos --release --dart-define=REMOTE_HUB=true, `service`, ad-hoc codesign) в том же staging | Flutter 3.44.9, Xcode 27.0 | BUILD_PASSED: `Remote Hub.app` (arm64) |
| 2026-11-23 | `tools/verify-release.py macos "Remote Hub.app"` | — | PASSED: feature-маркер, `APP_NAME`, нет тестовой CA, bundle id `app.personal.remotehub`, нет URL-схемы, codesign; `liblibrustdesk.dylib` sha256 `09acd994dbee3fb93d8e6dfec6f1264354efd1f0ff75beaf8cd0bb5d027e2a51` |
| 2026-11-23 | `tools/check-egress-macos.sh` controller, 60 с | основной Mac | PASSED: ни одного inet-сокета |
| 2026-11-23 | `tools/check-egress-macos.sh --host`, 60 с | основной Mac | PASSED: только `127.0.0.1:22118 (LISTEN)` |
| 2026-11-24 | `tools/build-macos.sh` целиком из чистого staging (после исправлений: Pods ≥ 12.3, bundle id в pbxproj, без URL-схемы) | основной Mac, Rust 1.81, Flutter 3.44.9, Xcode 27.0 | BUILD_PASSED, exit 0; встроенный `verify-release.py` — все PASS; sha256 `liblibrustdesk.dylib` `17d78c8a…cfcd`, `Remote Hub` `1861625e…338c`, `service` `8b059008…22f2` |
| 2026-11-24 | `tools/check-egress-macos.sh` (controller и `--host`) на этом артефакте | основной Mac | PASSED: controller — ни одного inet-сокета; host — только `127.0.0.1:22118 (LISTEN)` |
| 2026-11-23 | `tools/doctor.py --target android-arm64` | основной Mac, NDK r28c, JDK 17, cargo-ndk 3.1.2 | PASSED |
| 2026-11-23 | `tools/build-android.sh --debug`: staging, vcpkg, codegen (Flutter 3.24.5), controller-only manifest | то же | PASSED до `cargo ndk`; первый прогон `cargo ndk` упал в bindgen (нет sysroot NDK для host libclang) — скрипт исправлен (`LIBCLANG_PATH`/`BINDGEN_EXTRA_CLANG_ARGS` из NDK), после этого зависимости и bindgen прошли |
| 2026-11-23 | Компиляция `librustdesk` для `aarch64-linux-android` (release, LTO) | то же | NOT_RUN до конца: остановлена через ~40 мин при ~2 % CPU (Mac одновременно занят другими сессиями, 6+ ГБ swap); APK не собран |
| 2026-11-24 | `tools/build-android.sh --debug` (debug-режим: без fat LTO, 16 codegen units) | основной Mac, Rust 1.75, NDK r28c, Flutter 3.24.5 | Первый прогон: движок собран, но бинарники не слинковались (`undefined symbol: sodium_init`): autotools libsodium взял macOS `ranlib` («not a mach-o file»), а `liblibrustdesk.so` слинковался с 18 неразрешёнными символами libsodium (упал бы на телефоне). Скрипт исправлен: `AR`/`RANLIB` из NDK и проверка `llvm-nm` на неразрешённые символы |
| 2026-11-24 | `tools/build-android.sh --debug` после исправления | то же | BUILD_PASSED; `verify-release.py apk` — все PASS; в merged manifest нашёлся `CAMERA` (QR-сканер upstream, `zxing-android-embedded`) — добавлены удаление через `tools:node="remove"` и проверка разрешений APK в `verify-release.py` |
| 2026-11-24 | `tools/build-android.sh --debug` целиком (повторный прогон в том же staging; исправлено: `touch build.rs`, иначе не создавался `src/version.rs`) | то же | BUILD_PASSED, exit 0; `verify-release.py apk` — 10/10 PASS: application id `app.personal.remotehub`, нет запрещённых разрешений (итог: INTERNET, POST_NOTIFICATIONS, ACCESS_NETWORK_STATE, WAKE_LOCK), только arm64, feature-маркер, нет тестовой CA. `RemoteHub-android-arm64-debug.apk` sha256 `ba7c55ee…51b3`, `librustdesk.so` `30903a4f…02dd`; `llvm-nm`: 0 неразрешённых символов libsodium, 18 экспортов `Java_ffi_FFI_*` |
| 2026-11-24 | Smoke-запуск этого APK: `adb install`, `am start` на эмуляторе Android 14 arm64 (AVD Pixel 6, google_apis, без окна) | основной Mac | PASSED: процесс жив, `MainActivity` на переднем плане, открылся главный экран Remote Hub «My computers»; в logcat нет `FATAL EXCEPTION`, `UnsatisfiedLinkError`, ANR приложения (был ANR системного процесса эмулятора под нагрузкой). Это не проверка на Pixel |
| 2026-11-24 | `cargo test --locked --lib --features …,remote_hub remote_hub::e2e` с новым сценарием 4 одновременных входов, **на коде хоста до исправления** | основной Mac, Rust 1.81 | FAILED (ожидаемо): `["HOST_BUSY: …", "accepted", "accepted", "accepted"]` — управление получили три контроллера |
| 2026-11-24 | `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` после исправления | то же | TEST_PASSED: 14 passed (новые: `options_are_narrowed_to_view_and_quality`, `switch_display_cannot_change_resolution`, `only_one_concurrent_login_claims_the_controller`; e2e — ровно один `accepted` из 4 одновременных); новых предупреждений нет |
| 2026-11-24 | `flutter test test/remote_hub_device_form_test.dart test/remote_hub_devices_test.dart test/remote_hub_session_test.dart` | Flutter 3.24.5 | TEST_PASSED: 22 passed; без исправления формы два новых теста падали (`Expected: null, Actual: 'remotehub/device/…'`) |
| 2026-11-24 | `flutter analyze lib/remote_hub` + три теста Remote Hub | Flutter 3.24.5 | PASSED: «No issues found» |
| 2026-11-24 | `rustfmt --check` `remote_hub_host.rs`, `remote_hub.rs`; `connection.rs` | Rust 1.81 | PASSED; в `connection.rs` те же 4 расхождения, что и в upstream без хуков |
| 2026-11-24 | Раунд 3, `cargo test -p remote_hub transport` с новыми тестами на прежнем коде bridge | основной Mac, Rust 1.75 | FAILED (ожидаемо): `session_end_closes_the_bridge_and_its_extra_channels` (bridge жил, пока был открыт дополнительный канал); `host_closing_the_session_closes_the_bridge` с прежним `copy_bidirectional` (bridge ждал закрытия сокета движка) |
| 2026-11-24 | `cargo test -p remote_hub` после исправления | то же | TEST_PASSED: 15 passed |
| 2026-11-24 | `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging) | основной Mac, Rust 1.81 | Первый прогон: e2e FAILED на финальной проверке — bridge ждал закрытия сокета движка после остановки хостом; исправлено (канал завершается по первому EOF). Повтор: TEST_PASSED, 15 passed, включая e2e (отдельный bridge на каждый вход; после отказа хоста bridge закрыт) и `only_the_password_the_host_accepted_counts_and_a_new_connect_resets` |
| 2026-11-24 | `flutter test` трёх тестов Remote Hub; новые тесты на прежнем коде формы и коннектора | Flutter 3.24.5 | На прежнем коде FAILED (ожидаемо): `replacing a stored password keeps the replacement` (`forgetStoredPassword` = true), `a typed password is saved only after the host accepted it` (в vault оказался `'wrong'`). После исправления TEST_PASSED: 28 passed |
| 2026-11-24 | `flutter analyze lib/remote_hub` + три теста (временный bridge с ручным `remoteHubLoginAccepted`, удалён) | Flutter 3.24.5 | PASSED: «No issues found» |
| 2026-11-24 | `python3 -I tools/test_windows_identity.py` | основной Mac, Python 3 | TEST_PASSED: 7 tests (переименование runner на копиях реальных файлов, CRLF, отказ при изменившемся upstream, `verify-release.py windows`) |
| 2026-11-24 | `rustfmt --check` `transport.rs`, `remote_hub.rs` | Rust 1.81 | PASSED |
| 2026-11-24 | Раунд 7, `flutter test test/remote_hub_device_form_test.dart` с новыми тестами отказа удаления в vault на прежнем поведении (`applyDeviceEdit` всегда возвращал запись, удаление устройства шло даже после ошибки vault) | основной Mac, Flutter 3.24.5 | FAILED (ожидаемо): 5 тестов — `Expected: null, Actual: <Instance of 'DeviceRecord'>` / `<Instance of 'DeviceCatalog'>` |
| 2026-11-24 | `flutter test` четырёх тестов Remote Hub (новый `remote_hub_host_status_test.dart`) после исправления | то же | TEST_PASSED: 38 passed |
| 2026-11-24 | `flutter analyze lib/remote_hub` + четыре теста Remote Hub | то же | PASSED: «No issues found» |
| 2026-11-24 | `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging) | основной Mac, Rust 1.81 | TEST_PASSED: 18 passed, новые `status_reports_the_listener_state_not_the_port`, `a_foreign_program_on_the_port_is_not_reported_as_listening` (порт занят чужим listener: проба порта проходит, состояние `port_unavailable`, `listening=false`; после освобождения — `listening`; после «Stop access» — `stopped`); e2e проверяет состояние через `listener_state_for_ipc`. Новых предупреждений в `remote_hub.rs`/`ipc.rs` нет |
| 2026-11-24 | `rustfmt --check` `remote_hub.rs`; `ipc.rs` | Rust 1.81 | PASSED; в `ipc.rs`/`ipc/drm.rs` те же 10 + 25 расхождений, что и в upstream без хука |
| 2026-11-24 | Раунд 8: лог недоступности IPC-запроса состояния listener (панель опрашивает каждые 3 с) переведён на `throttled_log!` (60 с); `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging) | основной Mac, Rust 1.81 | TEST_PASSED: 18 passed; предупреждений в `remote_hub.rs`/`ipc.rs` нет; `rustfmt --check remote_hub.rs` PASSED |
| 2026-11-24 | Раунд 8: `flutter test` четырёх тестов Remote Hub; `dart analyze lib/remote_hub` + тесты | основной Mac | TEST_PASSED: 38 passed; analyze — только info об устаревшем `material.dart`/`value` (как в upstream) |
| 2026-11-24 | Раунд 9, временный тест (в staging, удалён): прежний `listener_state_from_service` (`#[tokio::main]`) вызван внутри `#[tokio::test]`; `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub::tests::tmp_old` | основной Mac, Rust 1.81 | FAILED (ожидаемо): panic «Cannot start a runtime from within a runtime» |
| 2026-11-24 | Раунд 9, после исправления (состояние listener берётся из цикла IPC-статуса UI): `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging) | то же | TEST_PASSED: 19 passed, новый `panel_reads_the_service_listener_inside_a_runtime`, включая e2e; новых предупреждений в `remote_hub.rs`/`ui_interface.rs` нет; `rustfmt --check remote_hub.rs` PASSED |
| 2026-11-24 | Раунд 9, `flutter test test/remote_hub_device_form_test.dart` с новыми тестами на прежней логике формы (пароль из формы сразу в vault) | основной Mac, Flutter 3.24.5 | FAILED (ожидаемо): 3 теста — vault содержал `mistyped`/`typed` вместо прежнего или пустого |
| 2026-11-24 | Раунд 9, `flutter test` четырёх тестов Remote Hub после исправления; `flutter analyze lib/remote_hub test/remote_hub_device_form_test.dart` | то же | TEST_PASSED: 35 passed (удалены 5 тестов записи пароля из формы в vault, добавлены 2); analyze — «No issues found» |
| 2026-11-24 | Раунд 10: новые тесты `flutter test test/remote_hub_devices_test.dart test/remote_hub_session_test.dart` на прежнем поведении (пароль передаётся viewer, ловится только `DeviceConfigException`, `exists()` вместо типа пути, текст «Network: Tailscale») | основной Mac, Flutter 3.24.5 | FAILED (ожидаемо): 6 тестов — viewer без staged пароля (`Actual: <null>`), необработанный `FileSystemException`, `Network: Tailscale` в карточке |
| 2026-11-24 | Раунд 10, `flutter test` четырёх тестов Remote Hub после исправления | то же | TEST_PASSED: 39 passed |
| 2026-11-24 | Раунд 10, `flutter_rust_bridge_codegen` 1.80.1 (staging, Flutter 3.44.9) + `flutter analyze lib/remote_hub` и четыре теста Remote Hub со сгенерированным bridge (временно, удалён) | основной Mac, Flutter 3.24.5 | PASSED: codegen «Success», `remoteHubStagePassword` сгенерирован; analyze — «No issues found» |
| 2026-11-24 | Раунд 10, `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging) | основной Mac, Rust 1.81 | TEST_PASSED: 21 passed, новые `a_staged_password_reaches_only_the_next_session_of_its_peer`, `session_add_uses_the_staged_password_only_for_its_own_peer`, включая e2e; новых предупреждений в `remote_hub.rs`/`flutter.rs`/`flutter_ffi.rs` нет; `rustfmt --check remote_hub.rs` PASSED |
| 2026-11-24 | Раунд 11: `SelectedSid` убран из allowlist хоста (переключение пользовательских сессий Windows выходит за рамки экран/ввод/дисплей/качество); тест `only_v0_1_capabilities_pass_after_login` проверяет отказ; `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (VCPKG_ROOT `~/dev/vcpkg-rh-osx`, временно скопированный сгенерированный bridge) | основной Mac, Rust 1.81 | NOT_COMPLETED: сборка остановлена по лимиту 2 ч (Mac в свопе ~28 ГБ), до остановки ошибок компиляции нет, тесты не запускались; `rustfmt --check remote_hub_host.rs` PASSED |
| 2026-11-24 | Раунд 11: изменение/удаление устройства и сохранение пароля после входа согласованы между списком и хранилищем (`commitDeviceEdit`, `commitDeviceRemoval`, `commitAcceptedPassword`); новые тесты на прежнем порядке записи (временно возвращён) | основной Mac, Flutter 3.24.5 | FAILED (ожидаемо): `a list that cannot be written keeps the stored password` (удаление, снятие сохранения), `a list that cannot be written leaves no password in the vault` |
| 2026-11-24 | Раунд 11, `flutter test` четырёх тестов Remote Hub после исправления; `dart format --set-exit-if-changed`; `flutter analyze lib/remote_hub` + два теста | то же | TEST_PASSED: 43 passed; format — 0 changed; analyze — только info `deprecated_member_use` (как в прежних раундах) |
| 2026-11-24 | Раунд 12: новый тест `finished_extra_channels_free_their_slot` на прежнем счётчике `opened` bridge (staging, `cargo test transport`) | основной Mac, Rust 1.75 | FAILED (ожидаемо): `a finished channel must free its slot: Elapsed` — после второго дополнительного канала все новые сокеты отклонялись |
| 2026-11-24 | Раунд 12, `cargo test` в `libs/remote_hub` (staging) после исправления (лимит считает живые каналы; `extra_engine_sockets_get_own_channels_up_to_the_limit` держит второй канал открытым) | то же | TEST_PASSED: 16 passed |
| 2026-11-24 | Раунд 12, `CARGO_INCREMENTAL=0 cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging; первый прогон упал на кэше incremental: `dep-graph.part.bin` не найден) | основной Mac, Rust 1.81 | TEST_PASSED: 23 passed, новые `refused_login_warnings_are_throttled` (отказы во входе пишутся через общий `LogThrottle`, 60 с) и `verified_name_follows_the_current_endpoint` (bridge к прежнему endpoint не подтверждает изменённое устройство), включая e2e; новых предупреждений в `remote_hub.rs`/`remote_hub_host.rs` нет |
| 2026-11-24 | Раунд 12, `flutter test` четырёх тестов Remote Hub (новый `a verification only counts for the endpoint it was made for`); `dart analyze` изменённых файлов; `dart format --set-exit-if-changed`; `rustfmt --check` `remote_hub.rs`, `remote_hub_host.rs`, `transport.rs` | основной Mac, Flutter 3.44.9, Rust 1.81 | TEST_PASSED: 44 passed; analyze — «No issues found»; format — 0 changed после переноса одной строки в тесте; rustfmt PASSED |
| 2026-11-24 | Раунд 13: доступ перепроверяется при захвате контроллера (вход, прошедший раннюю проверку до «Stop access», получает `HOST_DISABLED`), авторизованная сессия закрывается секундным таймером соединения, если доступ выключен; `CARGO_INCREMENTAL=0 cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging, bridge перегенерирован) | основной Mac, Rust 1.81 | TEST_PASSED: 25 passed, новые `login_finishing_after_stop_access_gets_no_control`, `authorized_session_ends_once_access_is_stopped`, включая e2e; новых предупреждений в `remote_hub_host.rs`/`connection.rs` нет; `rustfmt --check remote_hub_host.rs` PASSED |
| 2026-11-24 | Раунд 13: логи bridge (`transport.rs`) — лимит сокетов, сбои каналов и accept через локальный `throttled_log!` (60 с), завершение канала — `trace`; `cargo test` и `cargo clippy --all-targets` в `libs/remote_hub` | основной Mac, Rust stable | TEST_PASSED: 17 passed (новый `a_burst_writes_one_line_with_its_count`); clippy без предупреждений |
| 2026-11-24 | Раунд 13: `tools/source_state.py` — релиз только из чистого checkout (`build-macos.sh`, `build-android.sh --release`, `build-windows.ps1`); `--allow-dirty`/`-AllowDirty`/`--debug` помечают артефакт `<commit>-dirty`, `verify-release.py --release`/`manifest` такую метку не принимают; `python3 -I tools/test_source_state.py`, `test_verify_release.py`, `test_windows_identity.py`; `tools/build-android.sh --release` на текущем грязном дереве | основной Mac, Python 3 | TEST_PASSED: 7 + 2 + 7; сборка остановилась с exit 1 до staging со списком изменений |
| 2026-11-25 | Раунд 14: стадии подключения и отмена на каждой (12.3): `ConnectAttempt`/`ConnectStage` в `remote_hub_connector.dart`, строка стадии с «Cancel» на карточке; `~/dev/flutter-3.24.5/bin/flutter test` четырёх тестов Remote Hub | основной Mac, Flutter 3.24.5 | TEST_PASSED: 54 passed (новые: порядок стадий, отмена до старта, во время чтения vault, во время открытия viewer, во время проверки пароля; виджет строки стадии). На прежнем коде новые тесты не компилируются (нет API отмены) |
| 2026-11-25 | Раунд 14: `flutter analyze` изменённых файлов | Flutter 3.24.5 и 3.44.9 | Новых замечаний в `lib/remote_hub` и тесте нет; 3.44.9 — прежнее info `deprecated_member_use` в `device_edit_page.dart:242`; остальные — прежние info upstream-файлов |
| 2026-11-25 | Раунд 14: `tools/doctor.py --target windows-x64` проверяет MSVC toolset (`VCToolsVersion`), Windows SDK (`WindowsSDKVersion`, `Include/<ver>/um/windows.h`, `Lib/<ver>/um/x64/kernel32.lib` в `WindowsSdkDir`) и версию LLVM; при заданных в lock `msvc`/`windowsSdk` — точное совпадение; `python3 -I tools/test_doctor.py`; запуск doctor на Mac | основной Mac, Python 3 | TEST_PASSED: 6; doctor на Mac exit 1 со списком отсутствующих Windows-инструментов (ожидаемо) |
| 2026-11-25 | Раунд 15: хост Remote Hub больше не принимает вход по учётным данным недавней сессии upstream (`is_recent_session`) — каждый вход проверяется текущим постоянным паролем, смена пароля отзывает прежний контроллер; `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (в рабочем каталоге, сгенерированный bridge удалён после прогона) | основной Mac, Rust 1.81 | TEST_PASSED: 26 passed, новый `rotated_password_is_not_bypassed_by_a_recent_session`, включая e2e; новых предупреждений в `connection.rs`/`remote_hub_host.rs` нет; `rustfmt --check remote_hub_host.rs` PASSED |
| 2026-11-25 | Раунд 15: отмена во время открытия viewer больше не ждёт окно — закрытие назначается на его появление (или ошибку); новые тесты на прежнем коде `connect` | основной Mac, Flutter 3.44.9 | FAILED (ожидаемо): `cancelled while the viewer window stalls: cancel still completes` (тайм-аут) |
| 2026-11-25 | Раунд 15: `flutter test test/remote_hub_session_test.dart` после исправления; `flutter analyze lib/remote_hub test/remote_hub_session_test.dart` | то же | TEST_PASSED: 24 passed (новые: зависшее окно, ошибка открытия после отмены); analyze — только прежние info `deprecated_member_use` |
| 2026-11-25 | Раунд 16: новые Dart-тесты стадии подключения и настроек viewer на прежнем поведении `connect` (стадия «Checking the password» сразу после открытия окна, настройки не применяются) | основной Mac, Flutter 3.50.1 | FAILED (ожидаемо): 5 тестов — `Expected: securingConnection, Actual: checkingPassword`; `appliedPrefs` пуст |
| 2026-11-25 | Раунд 16: `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging) | основной Mac, Rust 1.81 | Первый прогон: FAILED `stop_is_confirmed_only_after_listener_and_sessions_end` (тест не ждал запуска цикла), затем `dial_stage_reports_failures_and_resets_on_a_new_connect` (общий peer id с другим тестом) — исправлены тесты. Повтор: TEST_PASSED, 30 passed (новые: `stop_is_confirmed_only_after_listener_and_sessions_end`, `a_state_from_before_the_change_does_not_confirm_it`, `dial_stage_reports_failures_and_resets_on_a_new_connect`, `viewer_preferences_map_to_the_upstream_peer_settings`); `rustfmt --check remote_hub.rs` PASSED |
| 2026-11-25 | Раунд 16: `flutter test` четырёх тестов Remote Hub | основной Mac, Flutter 3.50.1 (и 3.24.5) | TEST_PASSED: 68 passed (новые: неподтверждённая остановка оставляет «ON» и не меняет пароль; «OFF» только после подтверждения; стадия следует за native dial; TLS-ошибка завершает попытку; настройки устройства применяются до открытия viewer; выбор дисплея по имени) |
| 2026-11-25 | Раунд 16: `tools/build-macos.sh --allow-dirty` (staging, codegen 1.80.1, `cargo build --release`, `flutter build macos`) | основной Mac, Rust 1.81, Flutter 3.44.9, Xcode 27.0 | BUILD_PASSED, exit 0; codegen дал `remoteHubSetHostAccess`/`remoteHubDialStage`/`remoteHubApplyViewerPreferences` с сигнатурами как в web-заглушках; `dart analyze` изменённых файлов против сгенерированного bridge — 0 ошибок; `verify-release.py` — 0 failed (метка `-dirty`, тестовая сборка); sha256 `liblibrustdesk.dylib` `e3ddc30a…4287`, `Remote Hub` `05c3861c…0a39` |
| 2026-11-25 | Раунд 16: `tools/check-egress-macos.sh` (controller и `--host`, по 30 с) на этом артефакте | основной Mac | PASSED: host — только `127.0.0.1:22118 (LISTEN)` |
| 2026-11-25 | Раунд 17: новый тест `another window cannot allow access while a password shows` (две панели на одном хосте) при отключённом отказе «Allow access» во время показа пароля (как в прежнем коде) | основной Mac, Flutter 3.24.5 | FAILED (ожидаемо): `Expected: false, Actual: <true>` — второе окно включило доступ, пока первое показывало пароль |
| 2026-11-25 | Раунд 17: `flutter test` четырёх тестов Remote Hub после исправления (аренда показа пароля, `make_displays_msg` без изменений в upstream-пути) | то же | TEST_PASSED: 72 passed (новые: второе окно не включает доступ, пока пароль на экране; потерянная аренда скрывает пароль; закрытие панели снимает аренду; ротация не идёт, пока другое окно включает доступ) |
| 2026-11-25 | Раунд 17: staging, `flutter_rust_bridge_codegen` 1.80.1 (Rust 1.75, Flutter 3.44.9), затем `CARGO_INCREMENTAL=0 cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` | основной Mac, Rust 1.81 | TEST_PASSED: 32 passed, новые `a_shown_password_and_allowed_access_exclude_each_other`, `displays_msg_keeps_upstream_fields_and_adds_names`, включая e2e; codegen дал `remoteHubBeginPasswordDisplay`/`RenewPasswordDisplay`/`EndPasswordDisplay` с сигнатурами как в web-заглушках; новых предупреждений в `remote_hub.rs`/`flutter.rs`/`flutter_ffi.rs` нет; `rustfmt --check remote_hub.rs` PASSED |
| 2026-11-25 | Раунд 17: `flutter analyze lib/remote_hub lib/web/bridge.dart` + два теста против сгенерированного bridge (staging, Flutter 3.44.9) | основной Mac | Новых замечаний нет; только прежние info `deprecated_member_use` в `device_edit_page.dart` и upstream-замечания `bridge.dart` |
| 2026-11-25 | Раунд 18: новый тест `only_a_permanent_password_login_claims_the_controller` на прежней логике захвата контроллера (проверка способа входа и режима «только пароль» временно убрана в staging); `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub_host` | основной Mac, Rust 1.81 | FAILED (ожидаемо): вход, принятый кликом в connection manager, получил управление (`left: Ok(())`, `right: Err(AuthenticationFailed)`) |
| 2026-11-25 | Раунд 18, после исправлений (захват контроллера требует `ConnAuditPrimaryAuth::PermanentPassword` и режим «только пароль»; `set_host_access` без `#[tokio::main]`, runtime строится на границе FFI в `remote_hub_set_host_access`): `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging, `~/dev/rh-r17-test.sh` с codegen) | то же | TEST_PASSED: 33 passed, включая e2e; `rustfmt --check` `remote_hub.rs`, `remote_hub_host.rs` PASSED |
| 2026-11-25 | Раунд 19: новые тесты `a throwing password setter releases the lease`, `panel recovers when the password setter throws` на прежнем коде (временно возвращён) | основной Mac, Flutter 3.24.5 | FAILED (ожидаемо): аренда показа пароля не снималась, панель оставалась в состоянии ротации |
| 2026-11-25 | Раунд 19: `flutter test test/remote_hub_host_status_test.dart` после исправления; `dart format --set-exit-if-changed`, `dart analyze` изменённых файлов | то же | TEST_PASSED: 15 passed; format — 0 changed; analyze — только прежние info `deprecated_member_use` |
| 2026-11-25 | Раунд 19: `remote_hub_set_host_access` больше не создаёт runtime — работа идёт на runtime существующего цикла IPC-статуса UI (`ui_interface::ui_runtime`, `remote_hub::complete_on`); staging, codegen 1.80.1, `CARGO_INCREMENTAL=0 cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub`; `rustfmt --check remote_hub.rs` | основной Mac, Rust 1.81 | TEST_PASSED: 35 passed, новые `complete_on_uses_the_existing_runtime_even_from_a_runtime_thread`, `complete_on_reports_a_stopped_runtime_instead_of_hanging`, включая e2e; новых предупреждений в `remote_hub.rs`/`ui_interface.rs`/`flutter_ffi.rs` нет; rustfmt PASSED |
| 2026-11-25 | Раунд 20: неудачное «Allow access» больше не оставляет доступ включённым — `apply_access` не сохраняет `Y`, если listener не запущен, а при неподтверждении возвращает `N` и ждёт остановки; UI при ошибке IPC сохраняет `N` и отправляет сервису отключение. Новый `a_failed_allow_leaves_access_off` на прежней логике | основной Mac, Rust 1.81 | FAILED (ожидаемо): `assertion failed: !stored.load(Ordering::SeqCst)` |
| 2026-11-25 | `cargo test --features remote_hub --lib remote_hub::tests` после исправления; `rustfmt --check src/remote_hub.rs` | то же | TEST_PASSED: 22 passed, новые `a_failed_allow_leaves_access_off`, `a_confirmed_allow_keeps_access_on`; rustfmt PASSED. Полный набор с feature `flutter` и e2e в этом раунде не запускался |
| 2026-11-25 | Раунд 21: новые `tools/test_windows_identity.py` (порядок шагов `build-windows.ps1`, проверка `dylib_virtual_display.dll` в `verify-release.py windows`) и `tools/test_android_controller_manifest.py` (backup отключён) на прежних скриптах | основной Mac, Python 3 | FAILED (ожидаемо): 2 и 2 теста |
| 2026-11-25 | Раунд 21 после исправлений: `build-windows.ps1` собирает `-p dylib_virtual_display` до упаковки; staged manifest Android — `allowBackup=false`, `fullBackupContent=false`, `dataExtractionRules`; все `python3 -I tools/test_*.py`; `cargo pkgid -p dylib_virtual_display` | то же | TEST_PASSED: все 5 наборов OK (windows_identity 10, android manifest 5); pkgid разрешается в workspace. Сам `build-windows.ps1` не запускался (Windows проверяет владелец) |
| 2026-11-25 | Раунд 21: импорт/экспорт списка компьютеров в UI (`device_transfer.dart`, кнопки Import/Export); `flutter test` пяти тестов Remote Hub; `flutter analyze lib/remote_hub` и нового теста | основной Mac, Flutter 3.50.1 | TEST_PASSED: 84 passed (новые 10 в `remote_hub_device_transfer_test.dart`); analyze — только прежние info `deprecated_member_use` |
| 2026-11-25 | Раунд 22: `UI_RUNTIME`, `ui_runtime()` и запись handle в `check_connect_status_` закрыты `#[cfg(feature = "remote_hub")]` — без feature цикл IPC-статуса как в upstream; `cargo check --locked --lib --features flutter` и `--features flutter,remote_hub` (VCPKG_ROOT `~/dev/vcpkg-rh-osx`, временно скопированный сгенерированный bridge), `rustfmt --check src/ui_interface.rs` | основной Mac, Rust 1.81 | PASSED: обе сборки без ошибок и без предупреждений о `ui_runtime`/`UI_RUNTIME`; rustfmt чисто |
| 2026-11-25 | Раунд 23: новые `an_allow_the_requester_did_not_confirm_is_taken_back` и `remote_hub_never_keeps_a_password_in_peer_config` на прежнем поведении (временно отключены откат неподтверждённого allow и очистка пароля для личной адресной книги); `cargo test --features remote_hub --lib -- an_allow_the_requester_did_not_confirm remote_hub_never_keeps` | основной Mac, Rust 1.81 | FAILED (ожидаемо): 2 failed |
| 2026-11-25 | Раунд 23 после исправлений: `cargo test --features remote_hub --lib -- remote_hub retry_tests`; `cargo check --locked --lib --features flutter,remote_hub` (временно скопированный сгенерированный bridge) и `cargo check --locked --lib`; `rustfmt --check src/remote_hub.rs` | то же | TEST_PASSED: 41 passed (новые также `a_confirmed_allow_over_ipc_stays_on`, `a_failed_allow_over_ipc_is_an_error`, `the_panel_shows_access_on_while_the_listener_accepts`), включая e2e; обе сборки без ошибок и без предупреждений в `remote_hub.rs`/`client.rs`/`ipc.rs`; rustfmt чисто |
| 2026-11-25 | Раунд 24: аренда показа пароля перенесена в процесс listener (IPC `RemoteHubPasswordDisplay`), allow по IPC проверяет её в службе; лимит неаутентифицированных входов 4. `cargo test --features remote_hub --lib -- remote_hub unauthorized retry_tests` | основной Mac, Rust 1.81 | TEST_PASSED: 47 passed (два прогона подряд), включая e2e и новые `an_allow_from_another_process_is_refused_while_a_password_is_shown`, `password_display_ops_answer_over_the_wire_shape`, `test_remote_hub_caps_unauthenticated_logins_at_four`, проверку пятого ожидающего входа в e2e. На прежнем поведении (без проверки аренды в службе, лимит 16) три новых теста FAILED (ожидаемо). e2e держит общий для тестов лимита `UNAUTHORIZED_TESTS`: upstream `test_unauthorized_limit_bounds_live_handshakes` заполняет общий реестр. Также `cargo test -p remote_hub` — 17 passed; `cargo check --locked --lib` и `--features flutter,remote_hub` (временно скопированный сгенерированный bridge) — без ошибок; `rustfmt --check` `remote_hub.rs`, `policy.rs` — PASSED, в `connection.rs` расхождения только в строках upstream |
| 2026-11-25 | Раунд 25: отмена подключения на desktop повторяет закрытие вкладки (каждые 200 мс, до 15 с), пока вкладка не появится; останавливается, если начато новое подключение того же устройства (`viewer_close.dart`, `ViewerGenerations`). `flutter test test/remote_hub_*_test.dart` (новый `remote_hub_viewer_close_test.dart`), `flutter analyze` изменённых файлов, `dart format` | основной Mac | TEST_PASSED: 92 passed; analyze без ошибок и предупреждений (только прежние info) |
| 2026-11-25 | Раунд 25: ротация нативного лога (план 18.3) — `remote_hub::init_log`: 5 MiB × 5 файлов, удаление файлов старше 7 дней при запуске и каждые 6 ч (`libs/remote_hub/src/log_retention.rs`). `cargo test -p remote_hub`; `cargo check --release --lib --features remote_hub` и `cargo check --lib --features remote_hub` (VCPKG_ROOT=~/dev/vcpkg-rh-osx); `rustfmt --check` | основной Mac, Rust stable | TEST_PASSED: 20 passed (новые 3 `log_retention`); обе проверки собираются, новых предупреждений нет; на устройствах NOT_RUN |
| 2026-11-25 | Раунд 25: прежний блок сохранения пароля в `LoginConfigHandler::handle_peer_info` возвращён на место без изменений (без feature — путь upstream); очистка пароля Remote Hub — отдельный `#[cfg(feature = "remote_hub")]` вызов `remote_hub_clear_peer_config_password` после него; в `initialize` строка `let config = self.load_config();` как в upstream, очистка — отдельная cfg-привязка. Staging (`~/dev/rh-r17-test.sh` с codegen), `CARGO_INCREMENTAL=0 cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub -- remote_hub retry_tests unauthorized` | основной Mac, Rust 1.81 | TEST_PASSED: 49 passed, включая `remote_hub_never_keeps_a_password_in_peer_config` и e2e |
| 2026-11-25 | Раунд 25: `cargo check --locked --lib --features flutter` (staging, без `remote_hub`) | то же | PASSED: без ошибок, предупреждения только upstream |
| 2026-11-25 | Раунд 25: `tools/build-macos.sh --allow-dirty` из итогового дерева кандидата (staging, codegen 1.80.1, `cargo build --locked --release` 52 мин, `flutter build macos --release`) | основной Mac, Rust 1.81, Flutter 3.44.9, Xcode 27.0 | BUILD_PASSED, exit 0; `verify-release.py macos` — 0 failed (feature-маркер, identity, нет тестовой CA, bundle id `app.personal.remotehub`, нет URL-схемы, `codesign --verify --deep --strict`); `src/client.rs`, `src/remote_hub.rs`, `src/ipc.rs`, `src/server/connection.rs`, `remote_hub_host.rs` в staging побайтно совпадают с деревом. Метка `a3b42dfb…-dirty`, `release: false`: коммит в этой задаче запрещён. sha256 `liblibrustdesk.dylib` `cae536fd…8ffd`, `Remote Hub` `878f1f1c…a7c4`, `service` `2a4355d9…906d` |
| 2026-11-25 | Раунд 29: `flutter test test/remote_hub_host_status_test.dart` с новым тестом `host setup that cannot be saved says so and stays a controller`, **до исправления** `_run` | основной Mac, Flutter | FAILED (ожидаемо): ошибка записи настроек не показана, сообщения нет |
| 2026-11-25 | Раунд 29: после исправления — `flutter test test/remote_hub_*.dart`; `flutter analyze lib/remote_hub test/remote_hub_host_status_test.dart` | то же | TEST_PASSED: 93 passed; analyze — только upstream-уровневые info `deprecated_member_use` |
| 2026-11-25 | Раунд 29: `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging, codegen 1.80.1) после переноса освобождения ввода в очередь `tx_input`; `rustfmt --check remote_hub_host.rs` | основной Mac, Rust 1.81 | TEST_PASSED: 48 passed (новые `held_keys_are_tracked_for_release`, `held_input_is_released_with_up_events`); rustfmt PASSED. Windows-путь (portable service) на хосте NOT_RUN |
| 2026-11-25 | Раунд 30: новый тест `common::tests::test_remote_hub_sends_no_audit_records` (`cargo test --lib --features remote_hub`) **до исправления** | основной Mac, Rust stable | FAILED (ожидаемо): `get_audit_server` вернул `http://127.0.0.1:…/api/audit/conn` — хост отправил бы аудит подключения (ID, UUID) мимо TLS bridge |
| 2026-11-25 | Раунд 30: в Remote Hub `get_audit_server` пуст, `post_request`/`post_request_with_status` отказывают с `NETWORK_DENIED` (план 6.3–6.4); тесты `host_listener_binds_loopback_only…` и e2e сериализованы по порту 22118. `cargo test --lib --features remote_hub remote_hub` (3 прогона), `cargo check --lib` без feature, `rustfmt --check src/common.rs src/remote_hub.rs` | то же | TEST_PASSED: 47 passed ×3; сборка без feature — без новых предупреждений; rustfmt PASSED |
| 2026-11-25 | Раунд 30: смена адреса устройства закрывает открытый viewer старого адреса (`RemoteHubConnector.endSession`, `closeOpenRemoteDesktopSession`), Connect ждёт закрытия. `flutter test test/remote_hub_*.dart`; `flutter analyze lib/remote_hub lib/utils/multi_window_manager.dart` | основной Mac, Flutter 3.44.9 | TEST_PASSED: 38 + 57 passed (новые 2 в группе `changing the address ends the session to the old host`); analyze — только существовавшие info |
| 2026-11-25 | Раунд 31: удаление устройства закрывает его сессию (SEC-19): `RemoteHubConnector.removeDevice` после успешного удаления записи и пароля отменяет текущее подключение, очищает переданный пароль и закрывает открытый viewer; неудачное удаление сессию не трогает. `flutter test test/remote_hub_*.dart` | основной Mac, Flutter | TEST_PASSED: 99 passed (новые `removing a device revokes its session (SEC-19)`; до исправления не компилировались — `removeDevice` отсутствовал) |
| 2026-11-25 | Раунд 31: `http_request_sync` (FFI `main_http_request`), `tcp_proxy_request`, strict-клиенты загрузок/обновлений отказывают с `NETWORK_DENIED` (`remote_hub::deny_network`), TLS-проба HEAD пропускается, загрузка записей выключена. Новый тест `common::tests::test_remote_hub_denies_every_http_entry_point` **без защиты `http_request_sync`** | основной Mac, Rust 1.81 | FAILED (ожидаемо): `GET: reqwest::Error { kind: Request, … source: TimedOut }` — запрос ушёл на локальный сервер |
| 2026-11-25 | Раунд 31: настройка хоста пишется через `remote_hub_set_host_options` (одна запись роли и ограничений в службу по IPC, затем чтение обратно; ошибка возвращается в панель) вместо `mainSetOption`, который терял ошибки IPC. `cargo test --locked --lib --features remote_hub remote_hub`; `cargo check --locked --lib` без feature; `rustfmt --check` изменённых файлов | основной Mac, Rust 1.81 | TEST_PASSED: 50 passed (новые `host_options_are_merged_and_read_back`, `host_options_the_service_did_not_store_are_reported`, `test_remote_hub_denies_every_http_entry_point`); check PASSED, предупреждения только upstream |
| 2026-11-25 | Раунд 31: staging — codegen 1.80.1 (`remoteHubSetHostOptions({required String optionsJson})` совпал с вызовом и web-заглушкой), `flutter analyze lib/remote_hub` с сгенерированным bridge | основной Mac, Flutter 3.44.9 | PASSED: только info `deprecated_member_use` |
| 2026-11-25 | Раунд 31: `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging, с новым bridge) | основной Mac, Rust 1.81 | TEST_PASSED: 52 passed |
| 2026-11-25 | Раунд 32: «Delete log» удаляет и нативные файлы лога (`log_retention::delete_logs`, логгер в режиме `append`); стадия карточки завершается по любому принятому входу (`remote_hub_login_done`). `cargo test --locked -p remote_hub`; `cargo test --locked --lib --features remote_hub remote_hub`; `cargo check --locked --lib --features flutter,remote_hub` и `--features flutter` (временно сгенерированный `src/bridge_generated.rs`, удалён); `rustfmt --check` изменённых файлов | основной Mac, Rust 1.81 | TEST_PASSED: 21 passed (новый `deleting_logs_removes_rotated_files_and_empties_the_current_one`); 50 passed (расширен `only_the_password_the_host_accepted_counts_and_a_new_connect_resets`); check PASSED |
| 2026-11-25 | Раунд 32: `flutter test test/remote_hub_*.dart`; `flutter analyze lib/remote_hub lib/web/bridge.dart` + изменённые тесты (временный `generated_bridge.dart` из codegen 1.80.1, удалён) | Flutter 3.50.1 | TEST_PASSED: 116 passed; новый тест «a password corrected in the viewer completes the connect but is not saved» падал до исправления (ожидание по `loginAccepted` с первым паролем); analyze — 0 errors |
| 2026-11-25 | Раунд 33: новые тесты `a_concurrent_allow_cannot_undo_a_confirmed_stop`, `a_later_confirmed_allow_is_not_taken_back` на прежней логике (временно в staging: без сериализации изменений доступа и без проверки номера изменения при откате) | основной Mac, Rust 1.81 | FAILED (ожидаемо): Stop подтверждён при сохранённом «on»; неподтверждённое allow откатило более позднее подтверждённое |
| 2026-11-25 | Раунд 33, после исправления (изменения доступа выполняются по одному: `ListenerStatus::changes` в процессе listener и `HOST_ACCESS_CHANGES` в процессе UI; откат неподтверждённого allow только если его не заменило более позднее изменение): `cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,remote_hub remote_hub` (staging, с новым bridge) | то же | TEST_PASSED: 54 passed |
| 2026-11-25 | Раунд 33: macOS `service` инициализирует лог через `common::init_executable_log` (ротация и очистка Remote Hub); `cargo check --locked [--release] --bin service --features …,remote_hub` (staging); `rustfmt --check remote_hub.rs service.rs` | то же | PASSED (debug и release); rustfmt PASSED |
| 2026-11-25 | Раунд 33: учёт открываемых viewer (`ViewerTracker`) только для Remote Hub-сборки (`kRemoteHub`) и peer id Remote Hub; `flutter test test/remote_hub_*_test.dart`; `flutter analyze` изменённых файлов | Flutter 3.50.1 | TEST_PASSED: 121 passed; analyze — только прежние info upstream (`constant_identifier_names`, `deprecated_member_use`) |
| 2026-11-24 | Windows-сборка | — | NOT_RUN по указанию владельца (раунд 6: Windows проверяет сам владелец; Windows-окружение на Mac не разворачивать). Код и `tools/build-windows.ps1` подготовлены |

## Матрица шести пар (раздел 24.1)

Отложено владельцем; все ячейки `NOT_RUN`. Раздел 28 плана требует эту матрицу, реальную
сессию через Tailscale Serve и негативные сетевые проверки до релиза: loopback-тесты их не
заменяют, поэтому кандидат не готов к релизу, пока владелец их не выполнит.

| Контроллер | Хост | Экран | Ввод | Reconnect | Длительная сессия |
|---|---|---|---|---|---|
| Pixel 6 | MacBook A | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Pixel 6 | MacBook B | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Pixel 6 | Windows | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Основной Mac | MacBook A | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Основной Mac | MacBook B | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Основной Mac | Windows | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |

## Security tests (раздел 24.3)

| ID | Статус | Чем покрыто |
|---|---|---|
| SEC-01 неправильный пароль | TEST_PASSED (loopback e2e) | `remote_hub::e2e`: `Wrong Password`, сессии нет |
| SEC-02 пароль отсутствует | TEST_PASSED (unit) | `login_denial`: без постоянного пароля и password-only режима вход отклоняется (`HOST_DISABLED`) |
| SEC-03 loopback без auth | TEST_PASSED (loopback e2e) | соединение через 127.0.0.1 требует пароль |
| SEC-04 неверное имя сертификата | TEST_PASSED (unit) | `transport::tests::tls_failures_are_typed_and_never_fall_back` |
| SEC-05 недоверенный/просроченный cert | TEST_PASSED (unit) | то же |
| SEC-06 Tailscale отключён | TEST_PASSED (unit, частично) | `dial_to_an_unreachable_endpoint_fails_typed_without_fallback`; на устройстве NOT_RUN |
| SEC-07 подмена endpoint | TEST_PASSED (unit) | `plain_tcp_endpoint_is_rejected_not_used_raw` |
| SEC-08 tailnet peer вне разрешений | NOT_RUN | нужна tailnet-политика и устройства |
| SEC-09 LAN-подключение | TEST_PASSED (runtime на Mac) | listener только `127.0.0.1:22118`; LAN-проверка с другого устройства NOT_RUN |
| SEC-10 порт занят | TEST_PASSED (unit) | `host_listener_binds_loopback_only_and_does_not_share_the_port` |
| SEC-11 file/terminal/clipboard | TEST_PASSED (unit + e2e) | `only_v0_1_capabilities_pass_after_login`, `options_are_narrowed_to_view_and_quality` (lock after session, privacy mode, block input, clipboard, files и пр. отбрасываются), `switch_display_cannot_change_resolution`, e2e `UNSUPPORTED_CAPABILITY` |
| SEC-12 второй контроллер | TEST_PASSED (loopback e2e) | `HOST_BUSY` последовательно и при 4 одновременных входах (ровно один `accepted`); `only_one_concurrent_login_claims_the_controller` |
| SEC-13 экспорт без секретов | TEST_PASSED (unit) | `remote_hub_devices_test.dart`, `redaction` |
| SEC-14 скрытые upstream defaults | TEST_PASSED (runtime на Mac, 60 с простоя) | `check-egress-macos.sh`; путь подключения к реальному хосту NOT_RUN |
| SEC-15 остановленный хост после рестарта | TEST_PASSED (частично) | e2e: «Stop access» закрывает сессию и порт; состояние хранится в опции; перезапуск хоста NOT_RUN |
| SEC-16 неизвестная schema / большой файл | TEST_PASSED (unit) | `remote_hub_devices_test.dart` |
| SEC-17 спецсимволы | TEST_PASSED (unit) | `endpoint.rs`, `remote_hub_devices_test.dart` |
| SEC-18 повреждённый vault | TEST_PASSED (unit) | `no stored password or a broken vault asks again and never connects` |
| SEC-19 отзыв устройства | TEST_PASSED (unit), на устройствах NOT_RUN | удаление устройства закрывает его viewer и отменяет подключение (`removing a device revokes its session`); отзыв в tailnet-политике на устройствах NOT_RUN |
| SEC-20 test-only bypass | TEST_PASSED (release artifact) | `verify-release.py`: маркера тестовой CA нет; `test-support` только dev-dependency |

## Известные ограничения

- Индикатор безопасности (проверенное имя сертификата) показан на карточке устройства, а не в окне
  viewer; upstream viewer может показывать собственный значок «соединение не зашифровано» для
  внутреннего loopback-канала.
- Жесты Pixel — upstream mouse mode: касание = клик, двойное касание = двойной клик, касание двумя
  пальцами = правый клик, прокрутка двумя пальцами, удержание + движение = drag, pinch = масштаб.
  Долгое касание тоже даёт правый клик.
- `HOST_BUSY` сохраняется, пока хост не заметит обрыв прежнего соединения.
- Ротация логов — только нативного файлового лога. Её используют основной процесс, `flutter_ffi` и отдельный macOS-сервис (`src/service.rs`, исполняемый файл только для macOS; инициализирует лог через `common::init_executable_log`). Android не проходит через изменённые точки инициализации лога и её не использует.
- Windows: сборка не выполнялась (по указанию владельца её выполняет и проверяет он сам), MSVC/SDK
  в lock не записаны; требование рабочего Windows-хоста остаётся открытым до его сборки. Идентичность (`RemoteHub.exe`,
  version resource, заголовок окна) задаётся в staging `tools/windows_identity.py` и проверяется
  `verify-release.py windows`; проверено только тестами на копиях файлов runner. Иконка
  приложения остаётся upstream (своей иконки в репозитории нет).
- macOS-артефакт (раунд 25) собран из итогового дерева кандидата, включая аренду показа пароля и
  сужение опций хоста, и прошёл `verify-release.py`. Он помечен `-dirty` (`release: false`), так как
  дерево не закоммичено; релизную сборку `tools/build-macos.sh` без `--allow-dirty` нужно повторить
  из чистого коммита.
- Android debug APK собран без fat LTO (только `--debug`); `--release` использует профиль upstream
  и требует ключа подписи владельца. Установка APK на Pixel NOT_RUN.
- Сборки не побитово воспроизводимы: upstream `gen_version()` вшивает `BUILD_DATE`, поэтому хэши
  меняются от сборки к сборке и движок всегда перекомпилируется.

## Откат

Без feature `remote_hub` и без `REMOTE_HUB=true` собирается прежний upstream: все хуки за
`#[cfg(feature = "remote_hub")]` / `kRemoteHub`. Полный откат: удалить `libs/remote_hub`,
`src/remote_hub.rs`, `src/server/connection/remote_hub_host.rs`, `flutter/lib/remote_hub`, тесты
`flutter/test/remote_hub_*`, `tools/`, `config/build-lock.json` и хуки из `docs/upstream-map.md`,
вернуть `flutter/pubspec.yaml`/`pubspec.lock`, `Cargo.toml`/`Cargo.lock`.
