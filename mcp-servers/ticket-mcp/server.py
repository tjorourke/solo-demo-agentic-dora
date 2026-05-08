"""ticket-mcp — TrustUsBank ticketing & human-escalation MCP server.

Tools:
  - create_ticket(customer_id, summary, severity)
  - notify_human(ticket_id, channel)

Every ticket is a DORA Art. 17 incident record.
"""
from __future__ import annotations

import os
import uuid
from datetime import datetime

from fastmcp import FastMCP
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

resource = Resource.create({"service.name": os.getenv("OTEL_SERVICE_NAME", "ticket-mcp")})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("ticket-mcp")

mcp = FastMCP("ticket-mcp")

TICKETS: dict[str, dict] = {}


@mcp.tool()
def create_ticket(customer_id: str, summary: str, severity: str = "medium") -> dict:
    """Create an incident ticket. severity ∈ {low, medium, high, critical}."""
    with tracer.start_as_current_span("create_ticket") as span:
        if severity not in {"low", "medium", "high", "critical"}:
            return {"error": "invalid severity", "got": severity}
        ticket_id = "TICK-" + uuid.uuid4().hex[:8].upper()
        TICKETS[ticket_id] = {
            "ticket_id": ticket_id,
            "customer_id": customer_id,
            "summary": summary,
            "severity": severity,
            "status": "open",
            "created_at": datetime.utcnow().isoformat() + "Z",
        }
        span.set_attribute("ticket.id", ticket_id)
        span.set_attribute("ticket.severity", severity)
        return TICKETS[ticket_id]


@mcp.tool()
def notify_human(ticket_id: str, channel: str = "slack") -> dict:
    """Notify a human operator about a ticket. channel ∈ {slack, email, pager}."""
    with tracer.start_as_current_span("notify_human") as span:
        t = TICKETS.get(ticket_id)
        if not t:
            return {"error": "ticket not found", "ticket_id": ticket_id}
        span.set_attribute("ticket.id", ticket_id)
        span.set_attribute("notify.channel", channel)
        # In a real demo this would webhook out; here we just record it.
        t.setdefault("notifications", []).append({
            "channel": channel,
            "at": datetime.utcnow().isoformat() + "Z",
        })
        return {"ticket_id": ticket_id, "notified": channel}


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
