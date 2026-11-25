# ADR-0001: где живёт нативный код Remote Hub

- Статус: принято (2026-11-23)
- Задачи: RH-010, RH-011, RH-012

## Контекст

В разделе 5.1 плана предложен каталог `src/remote_hub/` с файлами `policy.rs`, `transport.rs` и
другими. Корневой crate `rustdesk` собирается только с vcpkg-зависимостями (libvpx, opus, aom и
др.), поэтому unit-тесты TLS bridge внутри него нельзя запустить без полной сборки. По `AGENTS.md`
`hbb_common` — общий с сервером submodule, его менять дорого.

## Решение

- Логика (политика, endpoint, TLS bridge, каталог ошибок) — в новом workspace crate
  `libs/remote_hub`. Зависимости: `tokio`, `tokio-rustls` (`ring`, `tls12`, без aws-lc),
  `webpki-roots`, `log`. Все они уже есть в `Cargo.lock` и в тех же версиях. В dev-зависимостях
  `rcgen` 0.13, он тоже уже есть в lock.
- В корневом crate — только `src/remote_hub.rs` с тонкими хуками и однострочные вызовы в
  существующих файлах.
- Тесты crate запускаются командой `cargo test -p remote_hub` и входят в CI-шаг
  `cargo test --workspace` (Linux).

## Последствия

- Отклонение от структуры раздела 5.1: `policy.rs`/`transport.rs` лежат в `libs/remote_hub/src/`,
  а не в `src/remote_hub/`.
- Политика не привязана к `hbb_common::config`. Чтение опций остаётся в хуках корневого crate.
