# Runbook: loopback-listener и Tailscale Serve на хосте (RH-011, RH-014)

Выполняет владелец локально на каждом из трёх хостов. Агенты не применяют эти шаги на рабочих
машинах без одобрения. Синтаксис CLI перепроверьте через `tailscale serve --help` установленной
версии.

## 0. Предварительные условия

1. Хост находится в tailnet владельца, MagicDNS работает, выдача HTTPS-сертификатов включена.
2. Имя хоста не содержит чувствительных данных: сертификат попадает в Certificate Transparency.
3. На хосте задан отдельный постоянный пароль Remote Hub (32 случайных символа).
4. Сохранён резервный способ доступа к хосту, есть физический доступ.

## 1. Сохранить текущее состояние

```bash
tailscale version
tailscale status
tailscale serve status --json
```

Сохраните вывод локально. Не публикуйте его: в нём есть адреса и имена устройств.

## 2. Включить роль хоста в Remote Hub

В приложении Remote Hub на хосте: вкладка «This computer» →

1. «Make this computer a host». Приложение выставляет: `approve-mode=password`,
   `verification-method=use-permanent-password`, `allow-hide-cm=N`, выключает clipboard, файлы,
   аудио, туннели, терминал, перезапуск, запись, блокировку ввода, камеру и принтер. Доступ при этом
   остаётся **выключенным**.
2. «Set a new password»: 32 случайных символа показываются один раз. Перенесите их на контроллеры
   вручную (поле пароля или vault), не пересылайте через чат и не сохраняйте в заметках.
   Пока пароль на экране, «Allow access» не сработает ни в одном окне: сначала «Hide password»
   (или «Allow access» в том же окне, что скроет пароль).
3. Выдайте приложению Screen Recording и Accessibility (System Settings → Privacy & Security).
   Не редактируйте TCC database.
4. «Allow access». Статус «Listener: Accepting» означает, что сам listener Remote Hub занял
   `127.0.0.1:22118` и принимает соединения (состояние сообщает процесс хоста по IPC, а не проба
   порта). «Port 22118 is used by another program» — bind не удался, порт держит другой процесс;
   «Host service is not running» — процесс хоста не ответил.

Проверьте, что слушает только loopback:

```bash
# macOS
lsof -nP -iTCP:22118 -sTCP:LISTEN
```

```powershell
# Windows
Get-NetTCPConnection -LocalPort 22118 -State Listen
```

Ожидается только `127.0.0.1:22118`. Строки `*:22118`, `0.0.0.0:22118`, `[::]:22118` означают
ошибку: нажмите «Stop access» и не настраивайте Serve. Если порт занят другим процессом, хост
остаётся недоступным (повтор bind каждые 5 с, панель показывает «Port 22118 is used by another
program»), и это правильное поведение.

## 3. Настроить Serve

```bash
tailscale serve --bg --tls-terminated-tcp=21118 tcp://127.0.0.1:22118
tailscale serve status --json
```

ЗАПРЕЩЕНО: `tailscale serve reset` (удалит чужие сервисы), Funnel, `--proxy-protocol`.

## 4. Проверить TLS отдельно от движка

С контроллера:

```bash
openssl s_client \
  -connect <HOST_TAILSCALE_IP>:21118 \
  -servername <HOST_FULL_MAGICDNS_NAME> \
  -verify_hostname <HOST_FULL_MAGICDNS_NAME> \
  -verify_return_error </dev/null
```

Успешный handshake подтверждает только TLS endpoint, а не экран, пароль или ввод.

## 5. Откат только этой настройки

```bash
tailscale serve --bg --tls-terminated-tcp=21118 tcp://127.0.0.1:22118 off
```

Затем в Remote Hub: «Stop access», при необходимости «Stop being a host».

## Локальная остановка доступа

Кнопка «Stop access» на вкладке «This computer»: listener закрывается, все сессии завершаются,
хост отпускает удерживаемые клавиши и кнопки; выключенное состояние сохраняется после перезапуска.
Serve может оставаться настроенным: без backend он не даёт управления.
