# VX1000 Pro — Screen Connection, как это делает NovaLCT

Источник: захват Wireshark NovaLCT ↔ 192.168.0.10, 20.10.2026. Кадров: 665, все контрольные суммы сходятся.
Тестовый экран: 4 × XC160-1 (160×360), Ethernet-порт 1, итого 640×360.

## Транспорт
- TCP 5200, регистровый протокол NovaStar (`55 AA` запрос / `AA 55` ответ), сумма = Σ(байты 2..конец данных) + 0x5555.
- Байт 11 (reserved) у широковещательного `0x01000012` = `0x08`.
- REST Unico (19999) NovaLCT не использует; контроллер сам обновляет `ucenter/screen/topology` и рассылает WS-уведомление.

## Read from HW (что читает NovaLCT)
Приёмные карты: `0x02000000`(512), `0x03004000`(4096), `0x14000420`(8), `0x0A000000`(82), `0x03000780`(68),
`0x08000004`, `0x09000004`, `0x00000000`, `0x02000509` — по каждой карте цепочки.
Отправитель: `0x05000000…` (файл конфигурации экрана «NSSD», 4 + 512 + 7 + 145 + 315/317 байт).
NovaMac читает раскладку проще — через `GET /unico/v1/ucenter/screen/topology`.

## Send to HW — 39 команд (воспроизведено побайтно)
| # | dst/dev/card | Регистр | Данные |
|---|---|---|---|
| 1–10 | FF/0 | 0x02000018…1B, 0x02000098…9B, 0x02000100…101 | 00 |
| 11 | 00/0 | 0x0200004A | 00 |
| 12 | 00/0 | 0x020000F0 | 00 |
| 13–14 | 00/0 | 0x02000028, 0x0200002A | 0, 0 (начало экрана?) |
| 15–16 | 00/0 | 0x02000024, 0x02000026 | W, H |
| 17 | 00/0 | 0x0200002C | W |
| 18–19 | 00/0 | 0x02000055, 0x02000057 | 0, 0 |
| 20–21 | 00/0 | 0x02000051, 0x02000053 | W, H |
| 22 | 00/0 | 0x03100000 | число карт на порту (u16) |
| 23 | 00/0 | 0x02000050 | 00 |
| 24–25 | 00/0 | 0x03200000, 0x03200010 | `00 W16 H16` + 11×00 |
| 26 | 00/0 | 0x02030000 | 0x0002 |
| 27 | 00/0 | 0x03000000 | таблица 1024×u32: `x | y<<16` для карты i, заполнена циклически (i mod N) |
| 28 | 00/1/FFFF | 0x0200009A | 00 |
| 29… | 00/1/i | 0x02000017, 0x02000019 | ширина, высота карты i (по столбцам, сверху вниз) |
| … | FF/1/port FF/FFFF | 0x01000012 | AA (reserved = 08) |
| … | 00/0 | 0x020001EC | W16 H16 |
| … | FF/0 | 0x020000AE | 01 |

Проверено побайтно (39/39): 4×1 в обе стороны и 2×2 (W=320, H=720; таблица: карта1 (0,360), карта2 (0,0),
карта3 (160,0), карта4 (160,360)). Ограничения: порт 1, начало 0,0, карты одного размера.

NovaLCT перед отправкой спрашивает «Send configuration and save it to hardware automatically?»:
Cancel — ничего не отправляется, OK — отправка + Save. Отдельной отправки без сохранения в NovaLCT нет.

## Save (NovaLCT)
`0x0200009D` чтение → обнуление 0x02000018… (dst 00) → `0x05066000` (256 байт, «SSPE») → `0x05000000` (4 байта, broadcast)
→ `0x02100000 = 55 00` → файл «NSSD» в `0x05000000/0x05001000/0x05002000` (315 байт закодированы) →
`0x01000001 = 00` → dev3 `0x05000000 = 00` → dev4 `0x01000011 = 00`.
Блок 315 байт не расшифрован — в NovaMac Save пока не реализован.

## Адресация по портам (захват порт 7 = индекс 6, 2×2, 39/39 побайтно)
p — индекс порта с нуля. Глобальные регистры (0x02000018…, 0x0200004A, 0x020000F0, 0x02000024/26/28/2A/2C,
0x020001EC, 0x020000AE, 0x01000012) не зависят от порта.

| Регистр | Порт 1 (p=0) | Порт 7 (p=6) | Формула |
|---|---|---|---|
| блок (00, W, H, 0, 0) | 0x02000050 | 0x020000C2 | 0x02000050 + 0x13·p |
| число карт | 0x03100000 | 0x031000C0 | 0x03100000 + 0x20·p |
| запись порта ×2 | 0x03200000/10 | 0x03218000/10 | + 0x4000·p |
| 0x0002 | 0x02030000 | 0x0203000C | + 2·p |
| таблица координат | 0x03000000 | 0x03006000 | + 0x1000·p |
| приёмные карты | байт порта 00 | байт порта 06 | p |

В Save у порта 7 байт reserved у 0x01000001 и dev4 0x01000011 = 06 (индекс порта).
Порты 2–6 и 8–10 — по формуле, напрямую не записаны.

## Mapping (Enable/Disable Mapping в NovaLCT)
Одна широковещательная запись во все приёмные карты всех портов:
`dst FF, dev 1, port FF, card FFFF, 0x01000088 = 05` — маппинг включён, `= 01` — обычное изображение.
Состояние NovaMac читает тем же регистром у первой карты активного порта.

## Save в NovaMac (экспериментально)
Команды Save NovaLCT без файла NSSD (SSPE 0x05066000, стирание 0x05000000 и запись 0x05000000/1000/2000 пропущены):
R 0x0200009D (=5A) → W 0x02000018…0x02000101 = 00 → W FF 0x02100000 = 55 00 → W FF 0x01000001 = 00 (rsv 06)
→ W FF dev3 portFF cardFFFF 0x05000000 = 00 (rsv 06) → W FF dev4 portFF cardFFFF 0x01000011 = 00 (rsv 06).
NSSD: заголовок «NSSD», e903=1001, 07 00, 1c56, 0x91=145 (блок 0x05000400), 0xB2; полезная часть 315–321 байт
зашифрована/упакована (не XOR, не zlib), первые 123 байта одинаковы для разных раскладок.

## Unico REST (VX Pro, COEX) — штатная отправка и сохранение (проверено выключением питания)
Снято с веб-интерфейса VX1000 Pro (`http://<ip>:19999/web/unico/unicos/`).
- Вход: `POST /unico/v1/system/auth/login {"username","password": base64(пароль)}` → `data.token`.
- Заголовки записи: `ip: <ip>`, `port: 8088`, `protocol: http` (прокси), `Authorization: <token>`, `Source: <uuid клиента>`,
  `seq`, `ClientType: 0`. Без прокси-заголовков: `code 500 "请在headers中传入你要代理的IP"`; без токена: `code 8273 token is not correct`.
- Раскладка: `POST /unico/v1/screen/cabinets/topology`
  `[{"cabinetID","guid": <GUID экрана>,"canvasId":10000,"cabinetPosition":{"x","y"},"cabinetSize":{"width","height"}}]`
  — список заменяет раскладку экрана целиком; контроллер сам её хранит.
- `cabinetID = MAC[3..5] << 32 | slot << 24 | portIndex << 16 | cardIndex` (пример 0x25C055_01_09_0000: …25:C0:55, слот 1, порт 10, карта 1).
- Маппинг: `PUT /unico/v1/cabinet/device-mapping {"enable":0|1,"canvasIDs":[10000]}`;
  по порту: `PUT /unico/v1/cabinet/netport-mapping {"netportID":116,"enable":0}`.
- Прочее из клиента: `screen/quick-topology`, `ucenter/screen/delete-topology`, `screen/topology/send|export|import`,
  `screen/cabinets/topology/change-position`, `node/sender/capacity`.

## MCTRL300 по USB (захват 21.10.2026 через мост nova_bridge.py, Parallels COM ↔ /dev/cu.usbserial-140)
USB-UART CP210x, 115200 8N1, тот же кадр `55 AA`. ID модели (0x00000002) = 0x0001. NovaLCT читает и пишет кусками по 256 байт.
Send to HW (3 отправки, порты 1 и 2, NovaMac воспроизводит 38/38 побайтно):
- сброс только `0x02000018`, `0x02000019` (dst FF); нет `0x0200004A`;
- блок порта `0x02000050 + 9·p` (+1 W, +3 H, +5 X, +7 Y; сам блок = 00), число карт `0x03100000 + 0x20·p`;
- нет записи порта `0x03200000` и нет `0x02030000`;
- таблица координат `0x03000000 + 0x1000·p`, 16 записей по 256 байт (заполнение то же: `x | y<<16`, i mod N);
- далее как у VX: dev1 `0x0200009A`, размеры карт `0x02000017/19`, `0x01000012 = AA` (rsv 08), `0x020001EC`, `0x020000AE`.
- чтение `0x02020020` (64) перед таблицей — карта не отвечает (NovaLCT ждёт ~1 с), NovaMac его не шлёт.
Mapping: тот же `0x01000088 = 05/01`.
Save: SSPE `0x05066000` → `0x05000000` = 0 (FF/FF/FFFF) → `0x02100000 = 55 00` → NSSD `0x05000000…0x05002100`
→ `0x01000001 = 00` (rsv 06) → dev3 `0x05000000` (rsv 06) → **dev1 `0x01000011`** (rsv 06) → dev4 `0x01000011` (rsv 06).
reserved 06 — константа, не номер порта (последняя отправка была на порт 2).

## Sending card EDID (MCTRL300, USB capture 22.10.2026)
- Read/write dev 0, port 0, card 0, register `0x08000000`, 256 bytes: VESA EDID block (128 bytes) + 128 zero bytes.
- NovaLCT changes only Detailed Timing Descriptor #1 (bytes 54–71) and the checksum (byte 127), writes, then reads back. No apply command.
- Observed: 800×600@60 (pclk 3657) → 1920×1080@60 (13915) → 1280×720@60 (6523) → 1920×1080@50 (11596), units of 10 kHz.
- Blanking constant H 160 (fp 48, sync 32), V 35 (fp 3, sync 6). pclk = floor((W+160)·(H+35)·Hz / 10000).
- Range limits descriptor (0xFD): V 48–123 Hz, H 28–200 kHz, max pixel clock 170 MHz.
- Unrelated write seen in the same session: `0x02000011` = 26 10 22 15 44 14 (current date/time, BCD-like).

## Test patterns / black / freeze (MCTRL300, USB captures 23.10.2026, NovaLCT Screen Control)
- Receiving cards (dev 1), card FFFF, parameter block 0x02000000:
  - `0x02000100` black screen: FF = black, 00 = picture
  - `0x02000101` test pattern: 00 normal, 02 red, 03 green, 04 blue, 05 white, 06 horizontal, 07 vertical, 08 slash, 09 256 grayscale, 0A ageing
  - `0x02000102` freeze: FF = frozen, 00 = live
- Pattern: 0x101 = code, 0x102 = 00, 0x100 = 00. Normal: 0x102 = 00, 0x101 = 01, 0x101 = 00, 0x100 = 00.
- NovaLCT used port 01 (pattern, black) and FF (freeze); nothing appeared on the screen (cards are on port 00). NovaMac sends to the screens' ports or FF.

## VX Pro device settings — REST (Opera DevTools HAR, 23.10.2026: vx-settings.har, vx-load.har)
- Name: GET `/unico/v1/node/detail?nodeId=1` → data.general.name; PUT `/unico/v1/node/general` `{"nodeId":1,"general":{"name":"Office"}}`
- Network: GET `/unico/v1/node/ethernet?nodeId=1`; PUT `/unico/v1/node/ethernet` `{"nodeId":1,"ethernet":{"mode":0,"infos":[{"index":0,"dhcp":0,"netmask":"255.255.255.0","ip":"192.168.0.10","gateway":"192.168.0.1","autoDNS":0,"dns":[]}]}}`
- HDCP: GET `/unico/v1/interface/list-detail` → list[].hdcp {enable, preset, actual}; PUT `/unico/v1/interface/hdcp` `[{"interfaceId":2,"hdcp":{"enable":1,"preset":3}},{"interfaceId":3,…"preset":1},{"interfaceId":4,…"preset":1}]` (HDMI 1–3)
- `interface/list-detail` also carries `actualTiming` per input (horizontal/vertical addTime, refresh) — candidate for the VX input-signal indicator (task 3).
- Web UI: http://<ip>:19999/web/unico/unicos/index.html
