# ADR-0005: как контроллер подключает движок к TLS bridge

- Статус: принято (2026-11-23)
- Задачи: RH-013, RH-015, RH-018, RH-022

## Решение

- Логический id устройства (UUID) превращается в engine peer id `rh` + 32 hex. Под ним upstream
  хранит настройки сессии (`PeerConfig`), поэтому ничего не привязано к временному
  `127.0.0.1:<port>`.
- Перед подключением UI вызывает FFI `remote_hub_register_device(id, ip, name)`. Native повторно
  валидирует endpoint (`RemoteEndpoint::new`).
- `Client::_start` при feature вызывает `remote_hub::dial(peer)`: проверка политики
  (`DialTarget::TlsBridge`), поиск зарегистрированного endpoint, `TlsBridge::open` (TLS и проверка
  сертификата до создания loopback-порта), затем движок подключается к `engine_dial_address()`.
  Незарегистрированный id → `INVALID_DEVICE_CONFIG`, никакой другой путь не пробуется.
- `LoginRequest.username` = `ip:21118` одобренного endpoint (как upstream direct IP), чтобы хост
  принял вход без RustDesk ID.
- Viewer, видеоповерхность, ввод, тачпад и IME — upstream (`connect()` → desktop окно или mobile
  `RemotePage`). Собственный viewer не пишется (план 2.2, 9.3).
- Переподключение: upstream-диалог «Reconnect» управляется `ReconnectWindow`
  (1/2/4/8/15 с, далее 15 с ±20 %, окно 90 с). Native `check_if_retry` запрещает повтор для кодов
  TLS, `HOST_*`, `AUTHENTICATION_*`, `INVALID_DEVICE_CONFIG`. Каждый повтор — новая сессия: ввод не
  буферизуется и не воспроизводится.
- Android lifecycle: уход приложения в background закрывает сессию (`closeConnection`), хост
  отпускает клавиши и кнопки.

## Отклонённые варианты

- Собственная state machine в Dart поверх upstream-модели: дублировала бы состояния upstream
  `FfiModel` и не была подключена к движку. Удалена.
