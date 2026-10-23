#!/usr/bin/env python3
"""NovaMac MCP server — exposes the NovaMac agent API (http://127.0.0.1:7801) as MCP tools.

No dependencies (Python 3.8+). Speaks MCP over stdio (JSON-RPC 2.0, one message per line).

Environment:
  NOVAMAC_TOKEN  token from NovaMac → Agent API (required)
  NOVAMAC_URL    default http://127.0.0.1:7801

Claude Desktop (~/Library/Application Support/Claude/claude_desktop_config.json):
  {"mcpServers": {"novamac": {"command": "python3",
      "args": ["/path/to/nova_mcp.py"], "env": {"NOVAMAC_TOKEN": "<token>"}}}}
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("NOVAMAC_URL", "http://127.0.0.1:7801").rstrip("/")
TOKEN = os.environ.get("NOVAMAC_TOKEN", "")

TARGETS = {
    "screens": {"type": "array", "items": {"type": "integer"},
                "description": "Screen numbers from list_screens. Omit (and omit controller) for all screens."},
    "controller": {"type": "string", "description": "ip:<address> or usb:<path> from list_controllers (instead of screens)."},
    "ports": {"type": "array", "items": {"type": "integer"},
              "description": "With controller: connector numbers as printed on the controller. Omit for all ports."},
}
WHERE = {
    "controller": {"type": "string", "description": "ip:<address> or usb:<path>; omit for the controller selected in NovaMac."},
    "port": {"type": "integer", "description": "Connector number as printed on the controller (default 1)."},
}

# name: (method, path, description, properties, required, query?)
TOOLS = {
    "list_controllers": ("GET", "/v1/controllers", "Controllers known to NovaMac: address, model, link type, port count.", {}, [], False),
    "rescan_controllers": ("POST", "/v1/controllers/rescan", "Rescan USB and read controller models.", {}, [], False),
    "list_screens": ("GET", "/v1/screens", "Screens known to NovaMac with their card layout (positions, sizes, ports).", {}, [], False),
    "read_screens": ("POST", "/v1/screens/read",
                     "Read all screens and card layouts from the controllers (like 'Read all from HW'). Read-only.", {}, [], False),
    "get_picture": ("GET", "/v1/picture",
                    "Brightness, gamma, RGB gains and calibration mode of the first receiving card on a port.", WHERE, [], True),
    "get_monitoring": ("GET", "/v1/monitor",
                       "Monitoring of one screen: input signal (VX), every cabinet's answer/temperature/voltage/position, port load.",
                       {"screen": {"type": "integer", "description": "Screen number from list_screens (default: first)."}}, [], True),
    "get_receiving_card": ("GET", "/v1/receiving-card",
                           "Size, firmware, cabinet description and raw parameter block of one receiving card.",
                           dict(WHERE, card={"type": "integer", "description": "Position in the cable chain, 1-based."}), [], True),
    "set_brightness": ("POST", "/v1/brightness", "Set LED screen brightness in percent (0-100). Changes the picture immediately.",
                       dict(TARGETS, percent={"type": "number", "minimum": 0, "maximum": 100}), ["percent"], False),
    "set_gamma": ("POST", "/v1/gamma", "Set gamma (1.0-4.0) using a standard curve scaled to the card's own table.",
                  dict(TARGETS, gamma={"type": "number", "minimum": 1, "maximum": 4}), ["gamma"], False),
    "set_color": ("POST", "/v1/color", "Set red/green/blue gains (0-255 each), e.g. for white balance.",
                  dict(TARGETS, red={"type": "integer"}, green={"type": "integer"}, blue={"type": "integer"}),
                  ["red", "green", "blue"], False),
    "set_calibration": ("POST", "/v1/calibration", "Switch calibration coefficients: off, brightness or chroma.",
                        dict(TARGETS, mode={"type": "string", "enum": ["off", "brightness", "chroma"]}), ["mode"], False),
    "send_layout": ("POST", "/v1/layout",
                    "Send a screen layout (card positions and sizes on one port), the same way as NovaMac's Screen Connection "
                    "'Send to HW' (VX Pro: sending-card registers + web model; MCTRL/MEE410: registers). ALWAYS call first "
                    "without confirm: it returns the plan and warnings and sends nothing. Show the plan to the user, then call "
                    "again with confirm=true. Not saved to flash.",
                    {"controller": {"type": "string", "description": "usb:<path> or ip:<address> from list_controllers."},
                     "port": {"type": "integer", "description": "Connector number as printed on the controller (default 1)."},
                     "cards": {"type": "array", "description": "Explicit layout, one entry per card in cable order.",
                               "items": {"type": "object", "properties": {
                                   "card": {"type": "integer", "description": "Position in the cable chain, 1-based."},
                                   "x": {"type": "integer"}, "y": {"type": "integer"},
                                   "width": {"type": "integer"}, "height": {"type": "integer"}},
                                   "required": ["card", "x", "y", "width", "height"]}},
                     "grid": {"type": "object", "description": "Regular grid instead of cards.",
                              "properties": {"columns": {"type": "integer"}, "rows": {"type": "integer"},
                                             "card_width": {"type": "integer"}, "card_height": {"type": "integer"},
                                             "path": {"type": "string", "enum": ["rows", "rows_snake", "columns", "columns_snake"],
                                                      "description": "Cable path; rows = left to right, row by row (default)."}},
                              "required": ["columns", "rows", "card_width", "card_height"]},
                     "confirm": {"type": "boolean", "description": "true = actually send. Omit to get the plan only."}},
                    [], False),
    "compare_receiving_cards": ("GET", "/v1/receiving-cards/compare",
                                "Compare the 512-byte parameter blocks (the RCFGX settings the cards run) of every card on one port. "
                                "Returns bytes where cards differ, the majority value, suspect cards (off the majority) and a reference card. "
                                "per_card offsets (size, card number) differ by design.", WHERE, [], True),
    "fix_receiving_card": ("POST", "/v1/receiving-card/fix",
                           "Copy the differing bytes of the 0x02000000 parameter block from a good card (from_card) to a bad one (card), "
                           "never size or card number. Only for single settings: a card loaded with another cabinet's configuration "
                           "also has wrong scan/mapping tables — use list_rcfgx + send_rcfgx for that. Optional offsets to copy only some bytes. Call without confirm first (plan only), then confirm=true. RAM only.",
                           dict(WHERE, card={"type": "integer", "description": "Card to fix, 1-based in the cable chain."},
                                from_card={"type": "integer", "description": "Good card to copy from, 1-based."},
                                offsets={"type": "array", "items": {"type": "string"},
                                         "description": "Optional: only these offsets, e.g. [\"0x1E3\", \"0x1E4\"]."},
                                confirm={"type": "boolean"}), ["card", "from_card"], False),
    "list_rcfgx": ("GET", "/v1/rcfgx",
                   "RCFGX files in NovaMac's library (files opened once on the Receiving Cards page). With controller+port: "
                   "for every file and card, how many parameter bytes differ (0 = the card runs that file) — use it to find "
                   "the right file for a card with a wrong configuration.", WHERE, [], True),
    "read_card_rcfgx": ("POST", "/v1/receiving-card/read-rcfgx",
                        "Read one receiving card's whole configuration into a new RCFGX file in NovaMac's library (about 30 s over "
                        "USB), for analysis and backup. Needs a template of the same cabinet type. DO NOT send the result to a "
                        "card to fix it: verified 23.10.2026 that a card does not work with data read back from another card. "
                        "To fix a card use send_rcfgx with the ORIGINAL file. Read-only on the card.",
                        dict(WHERE, card={"type": "integer", "description": "Card to read, 1-based."},
                             template={"type": "string", "description": "Library file of the same cabinet type (list_rcfgx)."},
                             name={"type": "string", "description": "Optional name for the new file."}), ["card", "template"], False),
    "send_rcfgx": ("POST", "/v1/receiving-card/rcfgx",
                   "THE way to fix a receiving card with a wrong configuration (verified 23.10.2026): write the ORIGINAL "
                   "library RCFGX file (the one the good cards match in list_rcfgx — not a read_card_rcfgx file) to one "
                   "receiving card (port + card) or, without card, to every card of the controller — the full configuration "
                   "(scan, mapping, gamma tables, parameters; it also sets its own brightness, so compare and set_brightness). Call without confirm "
                   "first (plan only), then confirm=true. RAM only; save_receiving_cards keeps it.",
                   dict(WHERE, file={"type": "string", "description": "Name from list_rcfgx."},
                        card={"type": "integer", "description": "1-based card on the port; omit for all cards."},
                        confirm={"type": "boolean"}), ["file"], False),
    "clone_receiving_card": ("POST", "/v1/receiving-card/clone",
                             "DO NOT use to fix a card (verified 23.10.2026: the card keeps showing wrong modules) — use "
                             "send_rcfgx with the original file. Diagnostic only: copy one card's whole configuration (everything an RCFGX writes: scan/data tables, pixel map, gamma, "
                             "cabinet description, parameters — never size or card number) to another card on the same port. "
                             "First call without confirm: compares both cards (regions sampled to 4 KB) and lists the regions that "
                             "differ. Then confirm=true starts the copy in the background (~1 min over USB); call again "
                             "without confirm for progress and the verified result. RAM only.",
                             dict(WHERE, from_card={"type": "integer", "description": "Good card, 1-based."},
                                  card={"type": "integer", "description": "Card to fix, 1-based."},
                                  regions={"type": "array", "items": {"type": "string"},
                                           "description": "Also write these regions in full, e.g. [\"0x04000000\"] (the 230 KB pixel map is compared by its first 4 KB only)."},
                                  confirm={"type": "boolean"}), ["from_card", "card"], False),
    "save_receiving_cards": ("POST", "/v1/receiving-cards/save",
                             "Save the receiving cards' current parameters to their flash (all cards of the controller), so a fix "
                             "survives power-off. Needs confirm=true; ask the user first.",
                             {"controller": WHERE["controller"], "confirm": {"type": "boolean"}}, [], False),
    "set_mapping": ("POST", "/v1/mapping", "Show (true) or hide (false) receiving-card numbers on the LED screen.",
                    {"controller": WHERE["controller"], "enabled": {"type": "boolean"}}, ["enabled"], False),
}


def call_api(method, path, args, as_query):
    url = URL + path
    data = None
    if as_query and args:
        url += "?" + urllib.parse.urlencode({k: v for k, v in args.items() if v is not None})
    elif method == "POST":
        data = json.dumps(args or {}).encode()
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=400) as r:
            return False, r.read().decode()
    except urllib.error.HTTPError as e:
        return True, "HTTP %d: %s" % (e.code, e.read().decode())
    except Exception as e:  # app not running, API off …
        return True, "NovaMac API not reachable at %s (%s). Is NovaMac running with Agent API enabled?" % (URL, e)


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        version = (msg.get("params") or {}).get("protocolVersion", "2025-06-18")
        return {"protocolVersion": version, "capabilities": {"tools": {}},
                "serverInfo": {"name": "novamac", "version": "1.0"},
                "instructions": "Controls NovaStar LED controllers through the NovaMac app. Read before changing; "
                                "changes take effect on the LED screen immediately and are not saved to flash. "
                                "Every tool with a confirm flag: call it without confirm first, show the plan to the user, "
                                "and only then call again with confirm=true after the user agrees. "
                                "FIXING A RECEIVING CARD WITH A WRONG CONFIGURATION (verified on hardware 23.10.2026): "
                                "1) compare_receiving_cards finds the odd card; set_mapping shows the card numbers on the "
                                "screen so the user can tell which cabinet is which (the cable may run right to left). "
                                "2) list_rcfgx with controller+port picks the ORIGINAL library file the good cards match "
                                "(bytes_differ 0 or near 0); if none is in the library, ask the user to open the right "
                                "RCFGX once on NovaMac's Receiving Cards page. "
                                "3) send_rcfgx that original file to the bad card only (port+card). "
                                "4) Ask the user to look at the screen; if it is right, check brightness against the other "
                                "cards (the file sets its own brightness) and set_brightness, then save_receiving_cards "
                                "with the user's agreement, and ask for a power cycle to verify. "
                                "Do NOT fix a card with clone_receiving_card, fix_receiving_card or a file made by "
                                "read_card_rcfgx: the card does not take data read back from another card "
                                "(the read-back is not what has to be written)."}
    if method == "ping":
        return {}
    if method == "tools/list":
        tools = []
        for name, (_, _, desc, props, req, _) in TOOLS.items():
            tools.append({"name": name, "description": desc,
                          "inputSchema": {"type": "object", "properties": props, "required": req}})
        return {"tools": tools}
    if method == "tools/call":
        params = msg.get("params") or {}
        name, args = params.get("name"), params.get("arguments") or {}
        if name not in TOOLS:
            raise ValueError("unknown tool " + str(name))
        http_method, path, _, _, _, as_query = TOOLS[name]
        is_error, text = call_api(http_method, path, args, as_query)
        return {"content": [{"type": "text", "text": text}], "isError": is_error}
    if mid is None:
        return None  # notification
    raise LookupError(method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        mid = msg.get("id")
        try:
            result = handle(msg)
            if mid is None:
                continue
            reply = {"jsonrpc": "2.0", "id": mid, "result": result}
        except LookupError as e:
            reply = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % e}}
        except Exception as e:
            reply = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": str(e)}}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
