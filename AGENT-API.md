# NovaMac agent API

A local HTTP + JSON API, so AI agents and scripts can work with NovaMac. It drives the same code as the app's pages.

## Turning it on
1. NovaMac → **Agent API** (sidebar, SERVICE).
2. Switch on **Enable the local API**. The server listens on `http://127.0.0.1:7801`, on this Mac only, never on the network.
3. Copy the **token**. Every request needs `Authorization: Bearer <token>`.
4. **Allow changes** is off by default, so agents can only read. Switch it on to let them set brightness, gamma, colour, calibration and mapping.

Flash is written only by POST /v1/receiving-cards/save (needs confirm:true). Changes that need care (layout, card fix) return a plan first and act only with confirm:true. Save to HW (sending card) and RCFGX file sending are not exposed.

## Conventions
| | |
|---|---|
| controller | `ip:192.168.0.10` or `usb:/dev/cu.usbserial-140` (from `GET /v1/controllers`); omitted = the controller selected in the app |
| port | connector number as printed on the controller, 1-based (MEE410: 1–18 in order) |
| card | position in the cable chain, 1-based |
| targets | `{"screens":[1,2]}`, or `{"controller":"ip:…","ports":[1,2]}`, or nothing = all screens |

## Endpoints
| Request | Does |
|---|---|
| `GET /v1` | self-description (this list) |
| `GET /v1/controllers` | controllers: address, model, link, ports |
| `POST /v1/controllers/rescan` | rescan USB, read models |
| `GET /v1/screens` | screens with card layout (x, y, size, port, card) |
| `POST /v1/screens/read` | read screens from the controllers ("Read all from HW") |
| `GET /v1/picture?controller=&port=` | brightness %, gamma, RGB gains, calibration mode |
| `GET /v1/receiving-card?controller=&port=&card=` | size, firmware, cabinet description, raw parameter block |
| `POST /v1/brightness` `{"percent":60}` | brightness 0–100 % |
| `POST /v1/gamma` `{"gamma":2.8}` | gamma 1.0–4.0 |
| `POST /v1/color` `{"red":255,"green":240,"blue":230}` | RGB gains |
| `POST /v1/calibration` `{"mode":"chroma"}` | off / brightness / chroma |
| `POST /v1/mapping` `{"enabled":true}` | card numbers on the LED screen |
| `POST /v1/layout` `{"controller":"usb:…","port":1,"grid":{"columns":4,"rows":1,"card_width":160,"card_height":360}}` | screen layout on one port (MCTRL, MEE410). Without `"confirm":true` only the plan; with it the layout is sent (RAM, not saved). Also `"cards":[{card,x,y,width,height}]`. Sent like Screen Connection's Send to HW (VX: registers + web model). |
| `GET /v1/receiving-cards/compare?controller=&port=` | parameter blocks (RCFGX settings) of all cards on a port compared byte by byte: suspects, reference card |
| `POST /v1/receiving-card/fix` `{"controller":…,"port":1,"card":3,"from_card":1}` | copy differing bytes from a good card (never size/card number); plan first, then `"confirm":true`; RAM |
| `GET /v1/rcfgx?controller=&port=` | RCFGX files in NovaMac's library (every file opened once on the Receiving Cards page) and how each matches every card |
| `POST /v1/receiving-card/read-rcfgx` `{"controller":…,"port":1,"card":1,"template":"Koala.rcfgx"}` | read a card into a new library RCFGX (records and XML from a template of the same cabinet type) |
| `POST /v1/receiving-card/rcfgx` `{"file":"Koala.rcfgx","controller":…,"port":1,"card":3}` | write a library RCFGX to one card (or all without `card`); plan first, then `"confirm":true`; RAM |
| `POST /v1/receiving-card/clone` `{"controller":…,"port":1,"from_card":1,"card":3}` | copy a card's whole configuration (RCFGX regions + parameters, not size/card number) to another card; plan first, `"confirm":true` starts it in the background, call again for the result; RAM |
| `POST /v1/receiving-cards/save` `{"controller":…,"confirm":true}` | save receiving cards' parameters to flash |

Errors come back as `{"error": "…"}`:

| Code | Meaning |
|---|---|
| 401 | wrong or missing token |
| 403 | "Allow changes" is off |
| 409 | no screens read yet |
| 502 | the controller did not answer |

```sh
T=<token>
curl -H "Authorization: Bearer $T" http://127.0.0.1:7801/v1/screens
curl -H "Authorization: Bearer $T" -d '{"percent":50,"screens":[1]}' http://127.0.0.1:7801/v1/brightness
```

## MCP (Claude Desktop and other agents)
`nova_mcp.py` (no dependencies) exposes the API as MCP tools: `list_controllers`, `list_screens`, `read_screens`, `get_picture`, `get_receiving_card`, `set_brightness`, `set_gamma`, `set_color`, `set_calibration`, `set_mapping`.

```json
{"mcpServers": {"novamac": {"command": "python3",
  "args": ["/Users/<you>/novamac/nova_mcp.py"],
  "env": {"NOVAMAC_TOKEN": "<token>"}}}}
```
Put this in `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude Desktop. Copy `nova_mcp.py` out of `~/Documents` first (e.g. `mkdir -p ~/novamac && cp nova_mcp.py ~/novamac/`): macOS does not let the Python that Claude Desktop starts read files in Documents ("Operation not permitted"). NovaMac must be running with the API enabled.

## Extending
Add a `case "METHOD /v1/…"` to `AgentAPI.dispatch` (AgentAPI.swift). Call the same function the page uses, guard any change with `requireChanges()`, and add a line to `AgentAPI.index` and a tool to `TOOLS` in nova_mcp.py.

## Fixing a card with a wrong configuration (verified 23.10.2026, MCTRL300 + XC160-1)
Every agent must follow this; the same text is in nova_mcp.py (server instructions and tool descriptions).
1. `compare_receiving_cards` — the odd card is off the majority in many bytes. `set_mapping` shows card numbers on the screen; the cable may run right to left, so match numbers to cabinets with the user.
2. `list_rcfgx` with controller+port — pick the **original** file the good cards match. If none is in the library, ask the user to open the right RCFGX once on the Receiving Cards page.
3. `send_rcfgx` that original file to the bad card only (plan, user agrees, `confirm`).
4. User checks the screen. The file sets its own brightness: compare with the other cards and `set_brightness`. Then `save_receiving_cards` (user agrees, `confirm`) and a power cycle to verify.

What does **not** fix a card (tried on hardware): `fix_receiving_card` (only the 0x02000000 block), `clone_receiving_card` (region by region, even with the full pixel map, plus save and power cycle) and sending a file made by `read_card_rcfgx`. Data read back from a card is not what has to be written; use those tools for diagnosis and backup only.
