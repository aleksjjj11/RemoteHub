# M3 — обходные сетевые пути и ограничения хоста

Сборка: Remote Hub на `master` `a3b42dfb90dc4742dfdf69b4281c1a73118eb8c0` + изменения рабочей копии
(раунд 2, 2026-11-23), cargo feature `remote_hub`. Устройства владельца и tailnet-политика **не**
проверялись (отложено владельцем): ниже только то, что выполнено на основном Mac.

## 1. Статический обзор путей (код)

| Путь upstream | В Remote Hub | Где |
|---|---|---|
| Регистрация на rendezvous (`RendezvousMediator::start`), NAT test, `hbbs_http::sync`, updater, LAN listener | не запускаются: `start_all` → `remote_hub::start_all` | `src/rendezvous_mediator.rs`, `src/remote_hub.rs` |
| Direct listener `listen_any` (wildcard, `SO_REUSEPORT`) | не запускается; host listener только `127.0.0.1:22118` | `src/remote_hub.rs` `host_listener` |
| Client: direct IP, `{domain}:{port}`, rendezvous punch, relay, WebRTC, IPv6 punch | недостижимы: `Client::_start` → `remote_hub::dial` | `src/client.rs` |
| Online query (rendezvous) | `NETWORK_DENIED` | `src/client.rs` `peer_online` |
| LAN discovery / WOL | `NETWORK_DENIED` / no-op | `src/lan.rs` |
| Проверка обновлений (ручная и авто) | `NETWORK_DENIED` | `src/common.rs` |
| Address book / группы / аккаунт (Dart HTTP) | не загружаются при старте; главный экран Remote Hub их не вызывает | `flutter/lib/main.dart` |
| Clipboard / файлы / терминал / туннель / аудио / камера / чат / перезапуск / privacy mode на хосте | отклоняются при входе или отбрасываются на приёме | `src/server/connection/remote_hub_host.rs` |

## 2. Runtime-проверки на основном Mac

Приложение: `Remote Hub.app` (arm64, release, ad-hoc подпись), 2026-11-23. Staging, codegen и
`cargo build --release` выполнил `tools/build-macos.sh`; шаг Xcode в первом прогоне упал (Pods ниже
macOS 12.0 под Xcode 27, затем upstream bundle id в проекте). После исправления скрипта оставшиеся
шаги (flutter build macos, копирование `service`, ad-hoc подпись) выполнены теми же командами в
том же staging-каталоге. `tools/verify-release.py macos` — все проверки PASS (feature `remote_hub` в
`liblibrustdesk.dylib` sha256 `09acd994…2a51`, bundle id `app.personal.remotehub`, нет URL-схемы,
нет маркера тестовой CA, `codesign --verify --deep --strict`).

Метод: `tools/check-egress-macos.sh` — запуск приложения, каждую секунду `lsof -nP -i` по всем
процессам bundle (главный процесс и порождённые им), 60 с, затем завершение. Нарушение — любой
listener, кроме `127.0.0.1:22118` в роли host, и любое соединение вне loopback и диапазонов
Tailscale. Трафик самого Tailscale daemon не учитывается.

| Сценарий | Наблюдаемые inet-сокеты процессов Remote Hub | Результат |
|---|---|---|
| Controller (конфигурация по умолчанию), 60 с простоя главного экрана | нет ни одного | PASS |
| Host (`remote-hub-role=host`, `remote-hub-host-enabled=Y`), 60 с | только `TCP 127.0.0.1:22118 (LISTEN)` | PASS |

Повтор 2026-11-24 на артефакте полного прогона `tools/build-macos.sh` (exit 0): те же результаты
(controller — нет сокетов; host — только `127.0.0.1:22118 (LISTEN)`).

Журнал приложения в этих запусках: IPC `/tmp/RemoteHub-501/ipc` (не пересекается с RustDesk),
`Remote Hub host listening on Ok(127.0.0.1:22118)` в роли host; записей rendezvous/relay нет.
Созданные запуском конфигурация, журналы и IPC-файлы удалены после проверки.

Протокольная проверка хоста за TLS (автотест `remote_hub::e2e::tls_bridge_to_restricted_host_end_to_end`,
loopback, тестовая CA вместо сертификата Tailscale): неверный пароль → `Wrong Password`; вход
file transfer → `UNSUPPORTED_CAPABILITY`; верный пароль → вход принят; второй контроллер →
`HOST_BUSY`; «Stop access» → сессия закрыта и порт 22118 больше не принимает соединения.

Не проверено в runtime: путь подключения контроллера к реальному хосту (нет хоста с Serve), экран
обновлений (в Remote Hub его нет), Android и Windows.

## 3. Не проверено

- Отрицательная сетевая матрица 8.6 (посторонний tailnet-узел, LAN, интернет) — нужны устройства.
- Tailscale grants/ACL — не менялись и не проверялись.
- Windows и Android runtime-сокеты.
