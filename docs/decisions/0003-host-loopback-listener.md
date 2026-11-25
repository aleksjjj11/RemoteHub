# ADR-0003: сетевой режим Remote Hub и loopback-only listener хоста

- Статус: принято (2026-11-23, пересмотрено в раунде 2)
- Задачи: RH-010, RH-011, RH-016, RH-017

## Контекст

`direct_server` (`src/rendezvous_mediator.rs`) слушает через `hbb_common::tcp::listen_any`
(dual-stack wildcard, `SO_REUSEPORT`). `RendezvousMediator::start_all` дополнительно запускает NAT
test, sysinfo sync, updater, LAN-listener и регистрацию на rendezvous-серверах. План (3.3, 6.3,
6.4) требует: хост слушает только `127.0.0.1:22118`, контроллер не слушает ничего, нет public
rendezvous/relay/LAN discovery. Первая версия включала loopback через runtime-опцию; review
справедливо указал, что без опции оставался wildcard listener и все публичные пути.

## Решение

- Сборка Remote Hub — это cargo feature `remote_hub` корневого crate (плюс
  `--dart-define=REMOTE_HUB=true` для UI). Без feature выполняется прежний код upstream без
  изменений; с feature ограничения действуют всегда, а не по опции.
- `start_all` при feature сразу передаёт управление `src/remote_hub.rs` `start_all`: ни NAT test,
  ни sync, ни updater, ни LAN-listener, ни rendezvous не запускаются.
- Роль: на Android всегда controller. На desktop роль `host` включается только локальной опцией
  `remote-hub-role=host`; по умолчанию controller, у которого listener не создаётся.
- Хост слушает только адрес из `TailnetOnlyPolicy::host_listen_addr()` = `127.0.0.1:22118`,
  через `TcpListener::bind` без `SO_REUSEPORT`. Ошибка bind — запись в журнал и повтор каждые 5 с,
  wildcard fallback отсутствует.
- Локальная кнопка «Остановить доступ» хранит `remote-hub-host-enabled=N`. Цикл listener проверяет
  опцию раз в секунду: закрывает listener и все сессии (`Server::close_connections`). Состояние
  сохраняется после перезапуска (SEC-15).
- Остальные входы upstream в публичную сеть при feature завершаются ошибкой `NETWORK_DENIED`:
  `lan::discover`, `lan::send_wol`, `common::do_check_software_update` (ручная и авто-проверка),
  `common::test_nat_type`, `common::test_rendezvous_server`, `client::peer_online::query_online_states_`.
- Клиент: `Client::_start` при feature всегда идёт в `remote_hub::dial` (ADR-0005). Ветки direct IP,
  rendezvous, relay, punch и WebRTC недостижимы.

## Хост: пароль и возможности (RH-017)

`src/server/connection/remote_hub_host.rs`, хук в начале `Connection::on_message`:

- до авторизации `LoginRequest` отклоняется, если доступ остановлен (`HOST_DISABLED`), запрошен не
  remote desktop (file transfer, port forward, terminal, camera → `UNSUPPORTED_CAPABILITY`), не
  настроен только постоянный пароль (`approve-mode=password`, `verification-method=use-permanent-password`,
  есть permanent password, нет `allow-hide-cm`) → `HOST_DISABLED`, или уже есть авторизованный
  remote-контроллер (`HOST_BUSY`, control lease);
- после авторизации проходят только mouse/pointer/key events, test delay и Misc для выбора дисплея,
  опций качества и обновления видео. Clipboard, файлы, терминал, аудио, чат, перезапуск, privacy
  mode, смена разрешения, elevation и прочее отбрасываются на стороне приёма;
- поля `clipboard/audio/file/restart/recording/block_input/privacy_mode` соединения сбрасываются;
- при закрытии авторизованного соединения хост отпускает отслеженные клавиши и кнопки мыши, даже
  если контроллер упал: события key-up/mouse-up ставятся в очередь ввода этого же соединения
  (`tx_input`), то есть идут тем же путём, что и нажатия — после ещё не обработанного ввода и, на
  Windows, через portable service, если ввод выполняет он.

## Известные ограничения

- Upstream `is_recent_session` позволяет тому же клиенту переподключиться без пароля в течение
  короткого окна, зная 64-битный session id авторизованной сессии. Не изменено (Remote Hub всегда
  передаёт пароль заново, но host-ветка осталась upstream).
- Глобальный rate limit входа upstream (`check_failure`) считает все попытки с одного loopback-адреса.
- `HOST_BUSY` держится, пока хост не заметит обрыв старого соединения (upstream keepalive).
