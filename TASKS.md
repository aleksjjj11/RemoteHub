# Remote Hub — backlog

Источник: раздел 22 плана. Каждая задача — отдельный небольшой набор commits; ID указывать в отчётах.
Фактический статус проверок — в [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).

Статусы: `TODO`, `IN_PROGRESS`, `PARTIAL` (часть scope написана и проверена unit-тестами),
`BLOCKED`, `DONE` (приёмка задачи выполнена).

| ID | Задача | Зависимость | Проверяемый результат | Статус |
|---|---|---|---|---|
| RH-001 | Инвентаризация пяти устройств | — | Реальные ОС/архитектуры или явные unknown | BLOCKED: отложено владельцем (раунд 2); шаблон `config/inventory.example.yaml` |
| RH-002 | Проверка upstream release/advisories | — | Выбран tag + полный SHA | DONE по решению владельца: `master` `a3b42dfb9…`, без tag (`config/build-lock.json`) |
| RH-003 | Baseline шести пар | RH-001/002 | Матрица реальных результатов | BLOCKED: отложено владельцем (раунд 2) |
| RH-004 | Сборка macOS baseline | RH-002 | Рабочий app bundle | PARTIAL: `Remote Hub.app` собран и проверен (`verify-release.py`, egress); неизменённый upstream отдельно не собирался |
| RH-005 | Сборка Android baseline | RH-002 | APK запускается на Pixel | PARTIAL: `tools/build-android.sh --debug` — BUILD_PASSED (debug APK, `verify-release.py apk` PASS); release-подпись у владельца; на Pixel NOT_RUN |
| RH-006 | Сборка Windows baseline | RH-002 | Хост запускается на Windows | TODO: `tools/build-windows.ps1` написан, не запускался (нет Windows-сборщика) |
| RH-007 | Build lock и clean-checkout recipe | RH-004/005/006 | Повторная сборка | PARTIAL: `config/build-lock.json`, `tools/doctor.py`, `tools/build-*.sh`; Windows-часть lock пустая |
| RH-008 | Карта upstream symbols | RH-002 | Paths, symbols, responsibilities | DONE: `docs/upstream-map.md` на закреплённом commit |
| RH-009 | Отдельные app identities | RH-007 | Нет конфликта с baseline app | PARTIAL: `APP_NAME=RemoteHub`, bundle/application id `app.personal.remotehub` в сборочных обёртках; Windows: `RemoteHub.exe` и version resource через `tools/windows_identity.py` (тесты), сборка Windows NOT_RUN |
| RH-010 | Controller/host role separation | RH-008/009 | Pixel не слушает входящий remote access | PARTIAL: роль в native (`remote_hub::role`), Android всегда controller, controller-only manifest; на Pixel NOT_RUN |
| RH-011 | Loopback-only host listener | RH-008 | Нет wildcard bind | PARTIAL: feature-gated listener, unit + e2e тест; на хосте с Serve NOT_RUN |
| RH-012 | TLS bridge | RH-007/008 | TLS positive/negative unit tests | DONE (unit): `libs/remote_hub/src/transport.rs` |
| RH-013 | Logical ID vs dial address | RH-012 | Пароли/настройки не привязаны к temporary port | DONE (код + тест): peer id `rh<uuid>`, upstream не сохраняет пароль |
| RH-014 | Serve setup/runbook | RH-011 | Точный endpoint, нет reset/Funnel | PARTIAL: runbook; автоматизации нет |
| RH-015 | End-to-end protected session | RH-011/012/013/014 | Экран + ввод + wrong-password denial | PARTIAL: loopback e2e протокола (TLS bridge → TLS terminator → host listener → вход); экран/ввод на устройствах NOT_RUN |
| RH-016 | Запрет public rendezvous/fallback | RH-015 | Runtime egress test | PARTIAL: native-хуки; egress-проверка собранного приложения — см. `docs/reports/M3-security-review.md` |
| RH-017 | Host capability allowlist | RH-015 | Запрещённые протокольные действия отклонены | PARTIAL: allowlist на приёме + тесты; на хосте NOT_RUN |
| RH-018 | Session state machine/reconnect | RH-015 | Cancel/race/retry tests | PARTIAL: upstream-сессия + `ReconnectWindow`, native `check_if_retry`; тесты на устройствах NOT_RUN |
| RH-019 | Vault и аудит upstream persistence | RH-009/013 | Нет plaintext/скрытого сохранения | PARTIAL: `flutter_secure_storage` (ADR-0004), upstream `remember` выключен; проверка на устройствах NOT_RUN |
| RH-020 | Device store/import/export | RH-019 | Schema/migration/invalid-input tests | DONE: store, UI добавления/редактирования, импорт (вставка или .json-файл ≤ 64 KiB, предпросмотр, без автоподключения, неподтверждённые, без замены существующих) и экспорт (копирование, без секретов); `flutter/test/remote_hub_device_transfer_test.dart` |
| RH-021 | Главный экран/ошибки | RH-018/020 | Нет mock-статусов в release | PARTIAL: `RemoteHubHome`; статусы только из фактических событий |
| RH-022 | Viewer/monitor switching | RH-015/018 | Реальная native video surface | PARTIAL: upstream viewer; на устройствах NOT_RUN |
| RH-023 | Pixel gestures/IME/lifecycle | RH-022 | Ручные и автоматические Android tests | PARTIAL: upstream mouse mode + IME, закрытие сессии в background; на Pixel NOT_RUN |
| RH-024 | macOS permissions/onboarding | RH-010/011 | Рабочий capture/input либо точная ошибка | PARTIAL: панель хоста; проверка на хостах NOT_RUN |
| RH-025 | Windows user host/onboarding | RH-010/011 | Работает без избыточных прав | TODO |
| RH-026 | Audit logs/diagnostics | RH-018 | Redaction и rotation tests | DONE (код + unit): экспорт с маскированием; локальная ротация нативного лога 5 × 5 MiB и удаление файлов старше 7 дней при запуске и каждые 6 ч (`libs/remote_hub/src/log_retention.rs`, `remote_hub::init_log`); на устройствах NOT_RUN |
| RH-027 | Control lease/input cleanup | RH-018 | Второй клиент отклонён, keys released | PARTIAL: `HOST_BUSY` (e2e), освобождение клавиш/кнопок при закрытии; на хосте NOT_RUN |
| RH-028 | Network policy/negative matrix | RH-016/017 | Все запреты подтверждены | TODO: нужны устройства |
| RH-029 | Performance/soak | RH-023/024/025/027 | Измерения на шести парах | BLOCKED: отложено владельцем |
| RH-030 | Packaging/signing/rollback | RH-007/009/019 | Update и rollback проверены | TODO: `tools/verify-release.py` есть; подписи и rollback нет |
| RH-031 | Final security review | RH-028/030 | Нет критических незакрытых findings | TODO |
| RH-032 | Personal release и runbooks | RH-029/031 | Раздел 28 выполнен | TODO |
| RH-033 | Clipboard vNext | RH-032 | Явное разрешение и лимиты | TODO (после v0.1) |
| RH-034 | File transfer vNext | RH-032 | Path/permission/integrity tests | TODO (после v0.1) |

## Следующая незаблокированная задача

1. Владелец: на одном Mac-хосте включить роль host, выдать права, настроить Serve по
   `docs/runbooks/host-serve-setup.md`; затем пройти M2-проверку с основного Mac и Pixel.
2. RH-006/RH-025: собрать Windows по `tools/build-windows.ps1` на Windows-машине и записать
   MSVC/SDK в build lock.
3. RH-030: личный ключ подписи Android у владельца, release-сборка, проверка обновления.

## Шаблон карточки

```text
ID:
Название:
Цель:
В scope:
Вне scope:
Зависимости:
Owner:
Разрешённые каталоги:
Ожидаемые изменения:
Автоматические тесты:
Ручные тесты:
Критерии приёмки:
Риски/откат:
Фактический результат:
Ссылки на evidence:
Статус:
```
