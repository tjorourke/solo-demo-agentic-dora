"""transaction-mcp — TrustUsBank transactions MCP server.

Tools:
  - list_recent(account_id, days) -> [Transaction]
  - get_details(txn_id)            -> Transaction
  - flag_suspicious(txn_id)        -> ack

Synthetic data. fraud-bot is the canonical caller of flag_suspicious.
"""
from __future__ import annotations

import os
from datetime import datetime, timedelta

from fastmcp import FastMCP
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

resource = Resource.create({"service.name": os.getenv("OTEL_SERVICE_NAME", "transaction-mcp")})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("transaction-mcp")

mcp = FastMCP("transaction-mcp")

NOW = datetime.utcnow()
TRANSACTIONS = {
    "txn-001": {"account_id": "12345", "ts": NOW - timedelta(hours=2),  "amount": -22.10,   "merchant": "Pret a Manger",       "currency": "GBP", "country": "GB"},
    "txn-002": {"account_id": "12345", "ts": NOW - timedelta(hours=5),  "amount": -89.99,   "merchant": "Sainsbury's",         "currency": "GBP", "country": "GB"},
    "txn-003": {"account_id": "12345", "ts": NOW - timedelta(hours=14), "amount": -1499.00, "merchant": "GenericLuxuryGoods",  "currency": "USD", "country": "RU"},  # suspicious
    "txn-004": {"account_id": "12345", "ts": NOW - timedelta(days=1),   "amount":  2300.00, "merchant": "Salary",              "currency": "GBP", "country": "GB"},
    "txn-005": {"account_id": "12346", "ts": NOW - timedelta(hours=3),  "amount": -8.20,    "merchant": "Caffè Nero",          "currency": "GBP", "country": "GB"},
}
SUSPICIOUS_FLAGS: set[str] = set()


def _to_iso(t: datetime) -> str:
    return t.replace(microsecond=0).isoformat() + "Z"


@mcp.tool()
def list_recent(account_id: str, days: int = 7) -> list[dict]:
    """List recent transactions for an account within the given window."""
    with tracer.start_as_current_span("list_recent") as span:
        span.set_attribute("account.id", account_id)
        span.set_attribute("days", days)
        cutoff = NOW - timedelta(days=days)
        out = []
        for tid, t in TRANSACTIONS.items():
            if t["account_id"] == account_id and t["ts"] >= cutoff:
                out.append({
                    "txn_id": tid,
                    "ts": _to_iso(t["ts"]),
                    "amount": t["amount"],
                    "merchant": t["merchant"],
                    "currency": t["currency"],
                    "country": t["country"],
                    "flagged": tid in SUSPICIOUS_FLAGS,
                })
        return sorted(out, key=lambda r: r["ts"], reverse=True)


@mcp.tool()
def get_details(txn_id: str) -> dict:
    """Return full details for a transaction."""
    with tracer.start_as_current_span("get_details") as span:
        span.set_attribute("txn.id", txn_id)
        t = TRANSACTIONS.get(txn_id)
        if not t:
            return {"error": "transaction not found", "txn_id": txn_id}
        return {
            "txn_id": txn_id,
            "account_id": t["account_id"],
            "ts": _to_iso(t["ts"]),
            "amount": t["amount"],
            "merchant": t["merchant"],
            "currency": t["currency"],
            "country": t["country"],
            "flagged": txn_id in SUSPICIOUS_FLAGS,
        }


@mcp.tool()
def flag_suspicious(txn_id: str) -> dict:
    """Mark a transaction as suspicious (fraud-bot only via gateway allowlist)."""
    with tracer.start_as_current_span("flag_suspicious") as span:
        span.set_attribute("txn.id", txn_id)
        if txn_id not in TRANSACTIONS:
            return {"error": "transaction not found", "txn_id": txn_id}
        SUSPICIOUS_FLAGS.add(txn_id)
        return {"txn_id": txn_id, "flagged": True}


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
