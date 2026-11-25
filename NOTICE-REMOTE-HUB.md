# Remote Hub — уведомление о производной работе

Remote Hub — персональная производная работа на основе RustDesk
(`https://github.com/rustdesk/rustdesk`), © участники проекта RustDesk.

- Лицензия всего репозитория, включая изменения Remote Hub: GNU AGPL-3.0, см. `LICENCE`.
- Copyright-уведомления upstream сохраняются без изменений.
- Изменение названия продукта не отменяет обязательств лицензии.
- Если сборки передаются другим людям или кому-то предоставляется сетевой доступ к ним, отдельно
  проверьте требования к Corresponding Source, в том числе раздел 13 AGPL.
- RustDesk Server Pro не используется, его закрытые возможности не копируются.

Изменения Remote Hub собраны в:

- `libs/remote_hub/` — политика tailnet-only и TLS bridge;
- `src/remote_hub.rs`, `src/server/connection/remote_hub_host.rs` и тонкие хуки в существующих
  файлах за cargo feature `remote_hub` (перечислены в `docs/upstream-map.md`);
- `flutter/lib/remote_hub/` — экраны, устройства, vault, переподключение, панель хоста, диагностика;
  хуки в `flutter/lib/main.dart`, `flutter/lib/models/model.dart`, `flutter/lib/web/bridge.dart`;
- `tools/` — обёртки сборки и проверки релиза; `config/build-lock.json`;
- документы `TASKS.md`, `IMPLEMENTATION_STATUS.md`, `docs/decisions/`, `docs/runbooks/`,
  `docs/reports/`, `docs/upstream-map.md`.

Сторонняя зависимость, добавленная Remote Hub: `flutter_secure_storage` 9.2.4 (BSD-3-Clause).

Для каждого собственного релиза сохраняйте соответствующий исходный код, включая содержимое
submodules, изменения, сведения о зависимостях и инструкции сборки.
