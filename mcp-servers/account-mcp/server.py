"""account-mcp — TrustUsBank account information MCP server.

Tools:
  - get_balance(account_id) -> balance
  - get_profile(account_id) -> name, email_masked, kyc_status

Synthetic data only. No real PII.
"""
from __future__ import annotations

import os

from fastmcp import FastMCP
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# OTel
resource = Resource.create({"service.name": os.getenv("OTEL_SERVICE_NAME", "account-mcp")})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("account-mcp")

mcp = FastMCP("account-mcp")

# Synthetic data
ACCOUNTS = {
    "12345": {"name": "Alex Carter",   "email": "alex@example.com",   "kyc": "verified", "balance": 4287.55},
    "12346": {"name": "Priya Singh",   "email": "priya@example.com",  "kyc": "verified", "balance": 102.33},
    "12347": {"name": "Marco Rossi",   "email": "marco@example.com",  "kyc": "review",   "balance": 18920.00},
}

def _mask_email(email: str) -> str:
    if "@" not in email:
        return "***"
    user, domain = email.split("@", 1)
    return user[0] + "***@" + domain


@mcp.tool()
def get_balance(account_id: str) -> dict:
    """Return the current cleared balance for an account.

    Args:
        account_id: The customer account ID (5 digits).
    """
    with tracer.start_as_current_span("get_balance") as span:
        span.set_attribute("account.id", account_id)
        acct = ACCOUNTS.get(account_id)
        if not acct:
            span.set_attribute("result", "not_found")
            return {"error": "account not found", "account_id": account_id}
        return {"account_id": account_id, "balance": acct["balance"], "currency": "GBP"}


@mcp.tool()
def get_profile(account_id: str) -> dict:
    """Return masked profile information for an account.

    PII is masked at the source. KYC status is included for fraud-bot.
    """
    with tracer.start_as_current_span("get_profile") as span:
        span.set_attribute("account.id", account_id)
        acct = ACCOUNTS.get(account_id)
        if not acct:
            return {"error": "account not found", "account_id": account_id}
        return {
            "account_id": account_id,
            "name": acct["name"],
            "email_masked": _mask_email(acct["email"]),
            "kyc_status": acct["kyc"],
        }


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
