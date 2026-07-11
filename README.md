# Orbit

Чистый iOS‑клиент TURN‑туннеля на базе [vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios).

Тот же рабочий стек (WireGuard + TURN relay + SRTP/WRAP режимы), но с другим интерфейсом: понятный главный экран, пошаговый чеклист настроек, нормальные статистики и настройки на русском.

## Что улучшено

- **Главный экран** — большая кнопка подключения, статус, чеклист «что ещё не заполнено»
- **Статистика** — скорость, RTT, каналы, пул кредов в карточках
- **Настройки** — сгруппированы: подключение → режим → WireGuard → аккаунт → бэкап
- **Скорость UX** — меньше визуального шума, мгновенная обратная связь при connect/disconnect
- **Совместимость** — те же режимы (Legacy / SRTP / SRTP+WRAP / WRAP‑A / WRAP‑S), те же ссылки `vkturnproxy://`, `wdtt://`, `freeturn://`, тот же формат бэкапа

## Требования

- Xcode 16+
- Go 1.22+ (для сборки `WireGuardBridge`)
- Apple Developer Team с entitlement **Network Extension** (packet tunnel) и App Group `group.com.vkturnproxy.app`

## Сборка

```bash
# 1. Go‑ядро (xcframework)
cd WireGuardBridge
make xcframework

# 2. Открыть проект
open VKTurnProxy/VKTurnProxy.xcodeproj

# 3. В Signing & Capabilities указать свой Team
# 4. Product → Run (на устройстве; симулятор VPN ограничен)
```

Серверная часть — как у upstream: [vk-turn-proxy](https://github.com/anton48/vk-turn-proxy) + WireGuard на VPS. Инструкции по режимам и ссылкам: `docs/setup.md`.

## Быстрый старт в приложении

1. Создайте VK‑звонок, скопируйте `https://vk.ru/call/join/…`
2. Укажите адрес прокси `IP:порт` (`-listen` на сервере)
3. Выберите **SRTP** (рекомендуется) или нужный режим совместимости
4. Введите ключи WireGuard (кроме WRAP‑A — там пароль сервера)
5. На главном экране — **Подключить**

Или: **Настройки → Импорт из ссылки** (clipboard / `vkturnproxy://`).

## Лицензия

GPL‑3.0 — как производная от [vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy) / [vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios).

## Credits

- [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios) — iOS‑клиент
- [cacggghp/vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy) — исходный протокол
