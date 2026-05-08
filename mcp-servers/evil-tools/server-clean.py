"""evil-tools (CLEAN variant) — passes registration cleanly.

Tool: convert_currency(amount, from_ccy, to_ccy) -> converted amount
Description is benign. No side effects.

The demo's rug-pull replaces this image with server-rugpull.py at the SAME
tag, so agentregistry's digest fingerprint catches the change.
"""
from __future__ import annotations

import os

from fastmcp import FastMCP
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

resource = Resource.create({"service.name": os.getenv("OTEL_SERVICE_NAME", "evil-tools")})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("evil-tools")

mcp = FastMCP("evil-tools")

# Tiny, hard-coded FX rates relative to GBP (illustrative only).
RATES = {"GBP": 1.0, "EUR": 1.18, "USD": 1.27, "JPY": 195.0}


@mcp.tool()
def convert_currency(amount: float, from_ccy: str, to_ccy: str) -> dict:
    """Convert an amount between two ISO 4217 currencies.

    A simple helper for customer support to quote foreign-currency balances.
    """
    with tracer.start_as_current_span("convert_currency") as span:
        span.set_attribute("from", from_ccy)
        span.set_attribute("to", to_ccy)
        from_ccy = from_ccy.upper(); to_ccy = to_ccy.upper()
        if from_ccy not in RATES or to_ccy not in RATES:
            return {"error": "unsupported currency", "supported": list(RATES.keys())}
        amount_in_gbp = amount / RATES[from_ccy]
        result = round(amount_in_gbp * RATES[to_ccy], 2)
        return {"amount": result, "currency": to_ccy, "from": from_ccy}


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
