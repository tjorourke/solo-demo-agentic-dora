"""mock-attacker — pretends to be the attacker's exfiltration endpoint.

This is the demo's "attacker.com server" stand-in. Lives outside the
bank's namespaces (in `external-attacker`) so we can see what data the
bank's compromised tool sends out.

Logs every POST body verbatim, plus a separator line, so a `kubectl
logs` after the attack shows the stolen customer record. When Solo's
AuthZ is enforcing, the connection never makes it here — that's the
"silence is success" moment.

Endpoints:
  POST /exfil  — append body to log, return {"received": <bytes>}
  GET  /       — friendly index showing recent exfil count
  GET  /loot   — latest received bodies as JSON (for the demo's UI)
  GET  /healthz
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from threading import Lock

from aiohttp import web

PORT = int(os.getenv("PORT", "8080"))
LOOT_LOCK = Lock()
LOOT: list[dict] = []   # in-memory ring buffer of received exfil events
MAX_LOOT = 50


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


async def healthz(_req: web.Request) -> web.Response:
    return web.json_response({"status": "ok", "loot_count": len(LOOT)})


async def exfil(req: web.Request) -> web.Response:
    body_bytes = await req.read()
    body_text = body_bytes.decode("utf-8", errors="replace")
    src = req.headers.get("X-Forwarded-For") or req.remote or "unknown"

    try:
        body_json = json.loads(body_text)
    except Exception:
        body_json = {"raw": body_text[:2000]}

    event = {
        "received_at": _stamp(),
        "source_ip": src,
        "size_bytes": len(body_bytes),
        "body": body_json,
    }
    with LOOT_LOCK:
        LOOT.append(event)
        if len(LOOT) > MAX_LOOT:
            del LOOT[: len(LOOT) - MAX_LOOT]

    # Loud, regulator-bait log line. This is what the demo greps for.
    print(
        f"\n{'=' * 70}\n"
        f"🚨 EXFIL RECEIVED at {event['received_at']} from {src}\n"
        f"   size: {event['size_bytes']} bytes\n"
        f"   body: {json.dumps(body_json, indent=2)[:1500]}\n"
        f"{'=' * 70}\n",
        flush=True,
    )

    return web.json_response({"received": len(body_bytes), "stored": True})


async def loot(_req: web.Request) -> web.Response:
    with LOOT_LOCK:
        return web.json_response({"count": len(LOOT), "events": list(LOOT)})


INDEX_HTML = """<!doctype html><html><head><meta charset=utf-8>
<title>mock-attacker — exfiltration receiver</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; max-width: 760px; margin: 32px auto; padding: 0 16px; background: #1a1a1a; color: #e5e5e5; }
  h1 { font-size: 20px; margin-bottom: 6px; color: #f87171; }
  .sub { color: #888; font-size: 13px; margin-bottom: 18px; }
  section { background: #2a2a2a; border-radius: 10px; padding: 16px; margin-bottom: 14px; box-shadow: 0 1px 3px rgba(0,0,0,0.5); }
  h2 { font-size: 14px; margin-top: 0; color: #fbbf24; }
  .stat { font-size: 32px; font-weight: 700; color: #f87171; }
  code { background: #111; color: #fbbf24; padding: 2px 6px; border-radius: 3px; font-size: 12px; }
  a { color: #60a5fa; }
  .warn { color: #f87171; font-weight: 600; }
</style></head><body>
<h1>mock-attacker — exfiltration receiver</h1>
<div class=sub>Pretends to be the attacker's C2 server. If you're seeing data here, your customers' PII has just left your bank. Live count refreshes every 3s.</div>

<section>
  <h2>Total exfiltration events received</h2>
  <div class=stat id=count>0</div>
</section>

<section>
  <h2>Recent loot (last 10)</h2>
  <pre id=loot style="white-space:pre-wrap; word-break:break-all; max-height:380px; overflow:auto; background:#111; padding:10px; border-radius:6px; font-size:12px;"></pre>
</section>

<section>
  <h2>Operator queries</h2>
  <ul>
    <li><a href=/loot>/loot</a> — JSON of all stored events</li>
    <li><a href=/healthz>/healthz</a> — { status, loot_count }</li>
    <li>From the cluster: <code>kubectl -n external-attacker logs deploy/mock-attacker</code></li>
  </ul>
</section>

<script>
async function refresh() {
  try {
    const r = await fetch('/loot');
    const d = await r.json();
    document.getElementById('count').textContent = d.count;
    const ev = (d.events || []).slice(-10).reverse();
    document.getElementById('loot').textContent = ev.length
      ? ev.map(e => `[${e.received_at}] ${JSON.stringify(e.body, null, 2)}`).join('\\n\\n')
      : '(no exfil yet)';
  } catch (e) {}
}
refresh();
setInterval(refresh, 3000);
</script>
</body></html>
"""


async def index(_req: web.Request) -> web.Response:
    return web.Response(body=INDEX_HTML, content_type="text/html")


def main() -> None:
    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/healthz", healthz)
    app.router.add_get("/loot", loot)
    app.router.add_post("/exfil", exfil)
    print(f"mock-attacker listening on :{PORT}", flush=True)
    web.run_app(app, host="0.0.0.0", port=PORT, print=lambda *a, **k: None)


if __name__ == "__main__":
    main()
