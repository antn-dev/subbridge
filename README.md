# SubBridge

[![Release](https://img.shields.io/github/v/release/antn-dev/subbridge?display_name=tag)](https://github.com/antn-dev/subbridge/releases/latest)
[![License](https://img.shields.io/github/license/antn-dev/subbridge)](LICENSE)

Компактный проверщик подписок для OpenWrt: скачивает подписку провайдера,
разбирает профили и измеряет задержку каждого узла через уже установленный
`sing-box`. Один пакет `Architecture: all` для всех роутеров, интерфейс LuCI и
CLI с JSON.

## Возможности

- Скачивает подписку с заголовками клиента (`Happ on Linux` по умолчанию,
  `Incy` и `v2rayTun` как fallback) и постоянным псевдонимным `X-HWID`.
- Понимает переходные страницы провайдеров: `config.php?...&domen=...`,
  `happ://add/...`, `v2raytun://import/...`, `subLinkField`, meta refresh и
  `location.href`.
- Разбирает JSON-профили и списки `vless://`.
- Проверяет все узлы параллельно через установленный `sing-box`, показывает
  лучший узел, профили провайдера и кнопки копирования.
- Ничего не меняет в маршрутизации, DNS и `nftables`; не останавливает
  работающие Podkop, Forkop или Tachyon.
- Три вкладки в LuCI: проверка, настройки и User Agent.
- CLI с человекочитаемым отчётом и JSON для скриптов.
- Сохраняет настройки и `X-HWID` при обновлении и удалении пакета.

## Установка

### Одной командой

```sh
wget -qO- https://github.com/antn-dev/subbridge/releases/latest/download/install.sh | sh
```

Скрипт запускается от `root`, сам определяет `apk` или `opkg`, скачивает
подходящий пакет из последнего релиза, проверяет SHA-256 и устанавливает его.
Эту же команду можно использовать для обновления.

Готовые пакеты и контрольные суммы: [Releases](https://github.com/antn-dev/subbridge/releases/latest).

### Вручную

```sh
# OpenWrt 24.10 (opkg)
opkg install subbridge_latest_all.ipk

# OpenWrt 25.12+ (apk)
apk add --allow-untrusted subbridge_latest_all.apk
```

В релизе лежат версионированные файлы (`subbridge_0.4.14-r1_all.ipk` и
`.apk`), стабильные псевдонимы `subbridge_latest_all.*` и `SHA256SUMS`.

Если установлено старое приложение `luci-app-subbridge` на Go, сначала
удалите его: `opkg remove luci-app-subbridge`.

После установки откройте **Services → SubBridge**, вставьте ссылку на
подписку и нажмите **Проверить подписку**.

## Требования

- OpenWrt 24.10+ с LuCI.
- Установленный `sing-box`: подойдут `sing-box`, `podkop-engine` или
  `sing-box-forkop`. SubBridge не устанавливает движок и не требует его
  конкретной версии.
- `curl` или `uclient-fetch`, а также `ca-bundle` для HTTPS.

`ucode` и нужные модули устанавливаются как зависимости пакета.

## Как это работает

1. Загружает подписку с идентичностью клиента и постоянным `X-HWID`.
2. Разрешает переходные страницы и получает рабочий HTTP-адрес подписки.
3. Декодирует base64/текст и разбирает JSON или `vless://`.
4. Запускает временный `sing-box` только с outbounds и Clash API, проверяет
   каждый узел и удаляет временную конфигурацию.
5. Показывает результат в LuCI и отдаёт его в CLI.

Проверка запускается только из интерфейса или командной строки. Служба
`/etc/init.d/subbridge` нужна для кнопок включения и перезапуска и сама
проверки не инициирует.

## Интерфейс

- **Проверка** — ссылка на подписку, запуск, список узлов, лучший узел,
  профили и копирование.
- **Настройки** — URL подписки, `test_url`, таймаут, параллельность и путь к
  движку.
- **User Agent** — автоматическая идентичность Happ на Linux или свои
  значения, скопированные с телефона.

Изменения на вкладках **Настройки** и **User Agent** вступают в силу после
**Save & Apply**. Ссылка на вкладке проверки применяется сразу при нажатии
**Проверить подписку**.

## CLI

```sh
subbridge check                    # человекочитаемый отчёт
subbridge check --json             # JSON с отступами
subbridge check --json --compact   # одна строка JSON
subbridge status                   # текущий прогресс
subbridge info                     # настройки и найденный движок
subbridge version
```

Полезные опции: `--url`, `--engine`, `--test-url`, `--timeout`,
`--concurrency`, `--status-file`, `--result-file`.

## Настройки

Файл `/etc/config/subbridge` — conffile, сохраняется при обновлении и удалении.

| Параметр | По умолчанию | Назначение |
| --- | --- | --- |
| `enabled` | `1` | `0` запрещает запуск проверок |
| `subscription` | пусто | Ссылка на подписку |
| `engine` | пусто | Путь к `sing-box`; пусто — автопоиск |
| `test_url` | Cloudflare `generate_204` | URL, открываемый через узел |
| `timeout_ms` | `3000` | Таймаут одного узла |
| `concurrency` | `8` | Число параллельных проверок |
| `ua_mode` | `auto` | `auto` — Happ на Linux; `custom` — свои поля |
| `ua_hwid` | пусто | Свой `X-HWID`; пусто — постоянный случайный |

## Приватность

Пакет не содержит пользовательских данных: подписка и `X-HWID` пусты, файла
HWID в пакете нет. Всё создаётся при работе:

| Данные | Где | Режим | Хранение |
| --- | --- | --- | --- |
| Подписка и настройки | `/etc/config/subbridge` | `0600` | сохраняются |
| `X-HWID` | `/etc/subbridge/hwid` | `0600` | сохраняется при удалении |
| Прогресс и результат | `/tmp/subbridge/*.json` | `0600` | очищается |
| Временные конфиги движка | `/tmp/subbridge-*` | `0600` | удаляются после проверки |

## Обновление и удаление

Обновление — повторите команду установки или установите новый пакет.

```sh
opkg remove subbridge     # OpenWrt 24.10
apk del subbridge         # OpenWrt 25.12+
```

При удалении служба останавливается, ссылки `rc.d` и `/tmp` очищаются, а
конфигурация и `X-HWID` сохраняются. Для полной очистки:

```sh
rm -rf /etc/config/subbridge /etc/subbridge
```

## Сборка

```sh
make package                     # dist/subbridge_<version>-r<release>_all.ipk
APK_TOOL=/path/to/apk make apk   # .apk, нужен apk-tools 3 (OpenWrt 25.12)
make test                        # unit-тесты ucode
```

## Лицензия

[Apache-2.0](LICENSE).
