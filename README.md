# Orbit

**iOS-клиент для WDTT-совместимого VPN-туннеля.**

`iOS 15+` · `SwiftUI` · `Go / WireGuard` · `GPL-3.0`

Orbit — самостоятельное развитие [vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios) с более понятным интерфейсом, профилями, подписками и совместимостью с форматами WDTT/qWDTT. Сетевое ядро остаётся прежним: WireGuard-трафик передаётся через TURN-совместимый транспорт к вашему серверу.

> В репозитории нет пользовательских ключей, подписок и доступа к чужим серверам. Для подключения нужен собственный сервер либо конфиг от его владельца.

## Что есть в Orbit

| Раздел | Что умеет |
| --- | --- |
| Подключение | Крупная кнопка VPN, понятный статус и журнал работы туннеля |
| Профили | Несколько конфигураций, папки, быстрый выбор активного сервера |
| Импорт | `wdtt://`, `qwdtt://`, JSON / `.qwdtt`, QR-код и HTTPS-подписка |
| Подписки | Один провайдер с регионами, сроком действия, расходом и лимитом трафика |
| Совместимость | WRAP-A, классические ссылки `vkturnproxy://` и `freeturn://` |
| Фон | Экономичный режим, ручная проверка регионов без постоянных сетевых опросов |
| APNs | Отдельный переключатель: отправлять push-уведомления через VPN или оставлять вне туннеля |

## Как это выглядит в работе

```text
iPhone с Orbit  ── TURN relay ──  совместимый WDTT-сервер  ── Интернет
      │                                      │
      └──────────── WireGuard внутри защищённого транспорта ─┘
```

Приложение не поднимает отдельный WireGuard-клиент в iOS: настройка VPN создаётся через системный Network Extension. В режиме WRAP-A сервер выдаёт необходимые параметры WireGuard автоматически после авторизации.

## Установка

Готовая сборка для iPhone лежит в [Releases](https://github.com/Lendic42/Orbit/releases/latest). IPA рассчитан на подпись через Feather, AltStore или Sideloadly.

1. Скачайте `Orbit-…-Feather.ipa` из последнего релиза.
2. Импортируйте его в ваш sideload-инструмент и подпишите своим сертификатом.
3. Откройте Orbit и подтвердите запрос iOS на добавление VPN-конфигурации.
4. Скопируйте конфиг, затем на главном экране нажмите **qWDTT**, **WDTT** или **Подписка**.

Подробности и типовые проблемы собраны в [инструкции по sideload](docs/sideload.md).

> Начиная с build 220 приложение использует Bundle ID `com.lendic.orbit`. Оно устанавливается отдельно от старых сборок с другим идентификатором; их локальные настройки не переносятся автоматически.

## Импорт конфигурации

### WDTT

Базовый формат одной ссылки. Импортируется из буфера обмена и QR-кода.

```text
wdtt://203.0.113.10:56000:56001:9000:ExamplePassword:vk_call_hash
```

Orbit использует адрес сервера и DTLS-порт, пароль и один или несколько хешей звонка. Поля WireGuard в WRAP-A вручную заполнять не нужно.

### qWDTT

Расширенный формат профиля: у него есть имя и число рабочих каналов.

```text
qwdtt://config?name=Дом&peer=203.0.113.10:56000&hashes=vk_call_hash&workers=16&port=9000&pass=ExamplePassword
```

Если сервер присылает `peer` без порта, Orbit подставляет стандартный DTLS-порт `56000`. Параметр `port=9000` — локальный порт формата qWDTT, а не адрес VPS. Также поддерживаются `dtls_port` и `server_port`.

### HTTPS-подписка

Подписка — это один URL, который создаёт в приложении отдельного провайдера. В нём может быть один сервер или несколько регионов, а сервер может передавать срок действия, статус и лимиты трафика.

```json
{
  "subscriptionName": "Orbit VPN",
  "profiles": [
    {
      "name": "Финляндия",
      "peer": "203.0.113.10:56000",
      "hashes": "vk_call_hash",
      "workers": 16,
      "password": "ExamplePassword"
    }
  ]
}
```

Подписки должны использовать HTTPS. Обновление выполняется по запросу пользователя и при обычном возврате в приложение, без агрессивного фонового опроса.

## Сборка из исходников

Нужны Xcode 16+, Go 1.22+ и Apple Developer Team с возможностью подписать Network Extension.

```bash
git clone https://github.com/Lendic42/Orbit.git
cd Orbit/WireGuardBridge
make xcframework
open ../VKTurnProxy/VKTurnProxy.xcodeproj
```

В Xcode выберите свою команду подписи для приложения и PacketTunnel, затем собирайте на реальном устройстве. VPN-расширение не проверяется в Simulator так же, как на iPhone.

Для unsigned arm64-архива:

```bash
xcodebuild archive \
  -project VKTurnProxy/VKTurnProxy.xcodeproj \
  -scheme VKTurnProxy \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath dist/Orbit.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## Структура

```text
VKTurnProxy/       SwiftUI-приложение и настройки профилей
PacketTunnel/       Network Extension для VPN
OrbitWidget/        исходники виджета статуса
WireGuardBridge/    Go → XCFramework для iOS
pkg/proxy/          транспорт и логика туннеля
docs/               дополнительная документация
```

## Происхождение и лицензия

Orbit основан на [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios) и сохраняет совместимость с экосистемой WDTT, включая [amurcanov/proxy-turn-vk-android](https://github.com/amurcanov/proxy-turn-vk-android) и [SpaceNeuroX/proxy-turn-vk-android](https://github.com/SpaceNeuroX/proxy-turn-vk-android).

Проект распространяется по [GPL-3.0](LICENSE). Если вы публикуете изменённую версию, сохраните лицензию и укажите исходный проект.

---

## ⭐ Stars

[![GitHub stars](https://img.shields.io/github/stars/Lendic42/Orbit?style=for-the-badge&logo=github&color=7c5cff)](https://github.com/Lendic42/Orbit/stargazers)

[Star history chart ↗](https://www.star-history.com/#Lendic42/Orbit&Date)

