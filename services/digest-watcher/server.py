"""digest-watcher — the demo's rug-pull detector.

Why this exists:
  The plan calls for agentregistry to compute SHA-256 fingerprints of every
  MCP tool definition and reject pulls when the digest changes. That's not a
  shipped feature in agentregistry v0.3.x, so we build it ourselves as a
  small audit service. Every Solo customer who wants this for real can
  productise the same loop.

What it does:
  1. Every POLL_SECONDS, calls tools/list on each registered MCP server
     directly (bypassing the data plane gateway, which would filter the
     poisoned descriptions before we could observe them).
  2. Canonically serialises the tool list (sorted by name, sorted keys) and
     hashes it with SHA-256.
  3. On first observation, writes the digest into ConfigMap digest-baselines.
  4. On subsequent observations, compares against the baseline:
       - Match: increment a check counter, record last_check timestamp.
       - Mismatch: increment digest_mismatch_total{mcp_server}, record the
         event in ConfigMap digest-mismatches with old/new digests + the new
         tool list, log a structured WARN line for Loki to pick up.
  5. Exposes Prometheus metrics on :9090/metrics and a /healthz on :8080.
  6. /trigger-check forces an immediate poll (used by test-malicious-actor.sh
     so the demo doesn't have to wait for the next 30s tick).

Idempotent: re-running with an existing baseline ConfigMap is fine — we read
it on every loop iteration. A human operator clears mismatches by editing
the ConfigMap or restarting the watcher (which re-establishes the baseline).
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from typing import Any

import httpx
from aiohttp import web
from kubernetes import client as k8s, config as k8s_config
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    generate_latest,
)

NAMESPACE = os.getenv("NAMESPACE", "trustusbank-platform")
BASELINE_CM = "digest-baselines"
MISMATCH_CM = "digest-mismatches"
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "30"))
HEALTHZ_PORT = int(os.getenv("HEALTHZ_PORT", "8080"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "9090"))

# We hit MCP servers directly (in-cluster service URLs), NOT via agentgateway.
# Going via the gateway would mean prompt-guard policies could filter the
# poisoned descriptions before we observe them — we want the raw truth.
MCP_TARGETS: dict[str, str] = {
    "account-mcp":     "http://account-mcp.trustusbank-bank-mcp.svc.cluster.local:8080/mcp/",
    "transaction-mcp": "http://transaction-mcp.trustusbank-bank-mcp.svc.cluster.local:8080/mcp/",
    "ticket-mcp":      "http://ticket-mcp.trustusbank-bank-mcp.svc.cluster.local:8080/mcp/",
    "evil-tools":      "http://evil-tools.trustusbank-bank-evil.svc.cluster.local:8080/mcp/",
}

# Prometheus metrics
mismatch_counter = Counter(
    "agentregistry_digest_mismatch_total",
    "Number of times an MCP server's tool-definition digest changed since baseline",
    ["mcp_server"],
)
checks_total = Counter(
    "agentregistry_checks_total",
    "Number of digest checks performed",
    ["mcp_server", "result"],
)
last_check_ts = Gauge(
    "agentregistry_last_check_timestamp_seconds",
    "Timestamp of the last successful digest check",
    ["mcp_server"],
)
current_digest = Gauge(
    "agentregistry_current_tool_digest_info",
    "Current observed tool-definition digest (label-only metric)",
    ["mcp_server", "digest"],
)

# Logging — JSON lines so Loki/Grafana parses them cleanly
logging.basicConfig(
    level=logging.INFO,
    format='%(message)s',
    stream=sys.stdout,
)
log = logging.getLogger("digest-watcher")


def _jlog(level: str, msg: str, **kw: Any) -> None:
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "service": "digest-watcher",
        "msg": msg,
        **kw,
    }
    print(json.dumps(rec), flush=True)


# ── Kubernetes API ─────────────────────────────────────────────────────────
def _load_kube() -> k8s.CoreV1Api:
    try:
        k8s_config.load_incluster_config()
    except k8s_config.ConfigException:
        k8s_config.load_kube_config()
    return k8s.CoreV1Api()


def _ensure_cm(api: k8s.CoreV1Api, name: str) -> dict[str, str]:
    try:
        cm = api.read_namespaced_config_map(name, NAMESPACE)
        return cm.data or {}
    except k8s.ApiException as e:
        if e.status == 404:
            api.create_namespaced_config_map(
                NAMESPACE,
                k8s.V1ConfigMap(metadata=k8s.V1ObjectMeta(name=name), data={}),
            )
            return {}
        raise


def _cm_set(api: k8s.CoreV1Api, name: str, key: str, value: str) -> None:
    api.patch_namespaced_config_map(name, NAMESPACE, {"data": {key: value}})


# ── MCP tools/list ─────────────────────────────────────────────────────────
async def _mcp_initialize(client: httpx.AsyncClient, url: str) -> dict[str, str]:
    """Run the MCP initialize handshake. Returns headers for follow-ups."""
    init_req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "digest-watcher", "version": "1.0.0"},
        },
    }
    r = await client.post(
        url,
        json=init_req,
        headers={"Accept": "application/json, text/event-stream"},
    )
    r.raise_for_status()
    sid = r.headers.get("mcp-session-id")
    headers = {"Accept": "application/json, text/event-stream"}
    if sid:
        headers["mcp-session-id"] = sid
    # Send initialized notification
    await client.post(
        url,
        json={"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        headers=headers,
    )
    return headers


def _parse_jsonrpc_response(body: str) -> dict:
    # Streamable-HTTP can return SSE-framed responses; pull out the data lines.
    if body.startswith("event:") or body.startswith("data:"):
        chunks = []
        for line in body.splitlines():
            if line.startswith("data:"):
                chunks.append(line[5:].strip())
        if chunks:
            return json.loads(chunks[-1])
    return json.loads(body)


async def fetch_tools(server: str, url: str) -> list[dict]:
    timeout = httpx.Timeout(10.0, read=20.0)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as c:
        try:
            headers = await _mcp_initialize(c, url)
        except Exception as e:
            _jlog("warn", "initialize failed; trying direct tools/list",
                  server=server, error=str(e))
            headers = {"Accept": "application/json, text/event-stream"}
        r = await c.post(
            url,
            json={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            headers=headers,
        )
        r.raise_for_status()
        data = _parse_jsonrpc_response(r.text)
        return data.get("result", {}).get("tools", []) or []


def canonicalise(tools: list[dict]) -> str:
    return json.dumps(sorted(tools, key=lambda t: t.get("name", "")), sort_keys=True)


def digest_of(tools: list[dict]) -> str:
    return hashlib.sha256(canonicalise(tools).encode("utf-8")).hexdigest()


# ── Main loop ──────────────────────────────────────────────────────────────
class Watcher:
    def __init__(self) -> None:
        self.api = _load_kube()
        self.last_results: dict[str, dict] = {}

    async def check_one(self, server: str, url: str) -> dict:
        try:
            tools = await fetch_tools(server, url)
        except Exception as e:
            checks_total.labels(server, "error").inc()
            _jlog("error", "fetch failed", server=server, url=url, error=str(e))
            return {"server": server, "status": "error", "error": str(e)}

        d = digest_of(tools)
        last_check_ts.labels(server).set(time.time())
        # Reset the gauge so only the current digest is exposed
        current_digest.clear()
        current_digest.labels(server, d).set(1)

        baselines = _ensure_cm(self.api, BASELINE_CM)
        baseline = baselines.get(server)

        if baseline is None:
            _cm_set(self.api, BASELINE_CM, server, d)
            checks_total.labels(server, "baseline").inc()
            _jlog("info", "baseline established", server=server, digest=d, tools=len(tools))
            result = {"server": server, "status": "baseline", "digest": d, "tools": len(tools)}
        elif baseline != d:
            mismatch_counter.labels(server).inc()
            checks_total.labels(server, "mismatch").inc()
            _jlog("warn", "DIGEST MISMATCH detected — possible rug-pull",
                  server=server, baseline=baseline, current=d,
                  tool_names=[t.get("name") for t in tools])
            event_key = f"{server}-{int(time.time())}"
            event_value = json.dumps({
                "server": server,
                "old_digest": baseline,
                "new_digest": d,
                "detected_at": datetime.now(timezone.utc).isoformat(),
                "tool_count": len(tools),
                "tool_names": [t.get("name") for t in tools],
                "tool_definitions": tools,
            })
            _ensure_cm(self.api, MISMATCH_CM)
            _cm_set(self.api, MISMATCH_CM, event_key, event_value)
            result = {"server": server, "status": "mismatch", "old": baseline, "new": d}
        else:
            checks_total.labels(server, "match").inc()
            result = {"server": server, "status": "match", "digest": d}

        self.last_results[server] = result
        return result

    async def check_all(self) -> list[dict]:
        return await asyncio.gather(*[self.check_one(s, u) for s, u in MCP_TARGETS.items()])

    async def run_forever(self) -> None:
        _jlog("info", "digest-watcher starting", targets=list(MCP_TARGETS.keys()), poll_seconds=POLL_SECONDS)
        # Small startup delay so MCP servers are ready
        await asyncio.sleep(5)
        while True:
            try:
                await self.check_all()
            except Exception as e:
                _jlog("error", "check loop iteration failed", error=str(e))
            await asyncio.sleep(POLL_SECONDS)


# ── HTTP control plane ─────────────────────────────────────────────────────
INDEX_HTML = """<!doctype html><html><head><meta charset=utf-8>
<title>digest-watcher — TrustUsBank rug-pull canary</title>
<style>
body{font:14px -apple-system,system-ui,sans-serif;max-width:780px;margin:32px auto;padding:0 16px;color:#111;background:#f8fafc}
h1{font-size:18px;margin:0 0 4px}
.sub{color:#64748b;font-size:13px;margin-bottom:18px}
section{background:#fff;border-radius:10px;padding:16px;margin:0 0 14px;box-shadow:0 1px 2px rgba(0,0,0,.05)}
h2{font-size:14px;margin:0 0 10px;color:#0a2540}
a{color:#2563eb;text-decoration:none}a:hover{text-decoration:underline}
code{background:#f3f4f6;padding:2px 6px;border-radius:4px;font-size:12px}
table{width:100%;border-collapse:collapse;font-size:13px}
td{padding:6px 8px;border-bottom:1px solid #e5e7eb}
td.tag{color:#64748b;width:160px}
.ok{color:#16a34a;font-weight:600}.bad{color:#dc2626;font-weight:600}
</style></head><body>
<h1>digest-watcher</h1>
<div class=sub>TrustUsBank rug-pull canary &mdash; SHA-256 over MCP tool definitions, every 30s. Mismatches = anomalous tool change since baseline (DORA Art. 10).</div>

<section><h2>State</h2>
<table>
<tr><td class=tag>baselines</td><td><a href=/baselines>/baselines</a> — current accepted digests</td></tr>
<tr><td class=tag>mismatches</td><td><a href=/mismatches>/mismatches</a> — recorded rug-pull events</td></tr>
<tr><td class=tag>metrics</td><td><a href=:9090/metrics>:9090/metrics</a> &mdash; Prometheus exposition</td></tr>
<tr><td class=tag>health</td><td><a href=/healthz>/healthz</a></td></tr>
</table>
</section>

<section><h2>Operator actions</h2>
<table>
<tr><td class=tag>force re-poll</td><td><code>curl -X POST localhost:18010/trigger-check</code></td></tr>
<tr><td class=tag>reset baseline</td><td><code>curl -X POST localhost:18010/baselines/&lt;mcp-server&gt;/reset</code></td></tr>
</table>
</section>

<section><h2>Targets being watched</h2>
<table>
<tr><td class=tag>account-mcp</td><td>http://account-mcp.trustusbank-bank-mcp:8080/mcp</td></tr>
<tr><td class=tag>transaction-mcp</td><td>http://transaction-mcp.trustusbank-bank-mcp:8080/mcp</td></tr>
<tr><td class=tag>ticket-mcp</td><td>http://ticket-mcp.trustusbank-bank-mcp:8080/mcp</td></tr>
<tr><td class=tag>evil-tools</td><td>http://evil-tools.trustusbank-bank-evil:8080/mcp</td></tr>
</table>
</section>
</body></html>
"""


async def index(_req: web.Request) -> web.Response:
    return web.Response(body=INDEX_HTML, content_type="text/html")


async def healthz(_req: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


async def metrics(_req: web.Request) -> web.Response:
    return web.Response(body=generate_latest(), headers={"Content-Type": CONTENT_TYPE_LATEST})


async def trigger_check(req: web.Request) -> web.Response:
    watcher: Watcher = req.app["watcher"]
    results = await watcher.check_all()
    return web.json_response({"checked": len(results), "results": results})


async def get_baselines(req: web.Request) -> web.Response:
    watcher: Watcher = req.app["watcher"]
    baselines = _ensure_cm(watcher.api, BASELINE_CM)
    return web.json_response(baselines)


async def get_mismatches(req: web.Request) -> web.Response:
    watcher: Watcher = req.app["watcher"]
    mm = _ensure_cm(watcher.api, MISMATCH_CM)
    return web.json_response({k: json.loads(v) for k, v in mm.items()})


async def reset_baseline(req: web.Request) -> web.Response:
    """Operator action: clear baselines (forces re-establish on next loop)."""
    watcher: Watcher = req.app["watcher"]
    server = req.match_info.get("server")
    body = {"data": {server: None}}
    watcher.api.patch_namespaced_config_map(BASELINE_CM, NAMESPACE, body)
    return web.json_response({"reset": server})


def make_app(watcher: Watcher) -> web.Application:
    app = web.Application()
    app["watcher"] = watcher
    app.router.add_get("/", index)
    app.router.add_get("/healthz", healthz)
    app.router.add_get("/metrics", metrics)
    app.router.add_post("/trigger-check", trigger_check)
    app.router.add_get("/baselines", get_baselines)
    app.router.add_get("/mismatches", get_mismatches)
    app.router.add_post("/baselines/{server}/reset", reset_baseline)
    return app


async def main() -> None:
    watcher = Watcher()
    app = make_app(watcher)

    runner = web.AppRunner(app)
    await runner.setup()

    healthz_site = web.TCPSite(runner, "0.0.0.0", HEALTHZ_PORT)
    metrics_site = web.TCPSite(runner, "0.0.0.0", METRICS_PORT)
    await healthz_site.start()
    await metrics_site.start()

    await watcher.run_forever()


if __name__ == "__main__":
    asyncio.run(main())
