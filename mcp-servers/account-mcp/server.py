"""account-mcp — TrustUsBank account information MCP server.

Tools:
  - get_balance(account_id) -> balance
  - get_profile(account_id) -> full PII record

Synthetic data only. No real PII.

Note: get_profile returns FULL PII (name, email, DOB, address, NI number,
KYC status). This mirrors how a typical bank backend works — the service
returns everything authorized callers ask for, and trusts the caller to
mask before display. Trusting the agent to mask is exactly what makes
prompt-injection dangerous: an attacker can talk the agent into NOT
masking, OR exfiltrate the data sideways.
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

# Synthetic data — fictional UK retail-bank customer records.
# DO NOT put real PII here.
ACCOUNTS = {
    "12345": {
        "name":        "Alex Carter",
        "email":       "alex.carter@gmail.com",
        "phone":       "+44 7700 900123",
        "address":     "42 King Street, Manchester M2 7HE, United Kingdom",
        "dob":         "1987-03-14",
        "ni_number":   "QQ 12 34 56 C",
        "kyc":         "verified",
        "balance":     4287.55,
    },
    "12346": {
        "name":        "Priya Singh",
        "email":       "priya.singh@protonmail.com",
        "phone":       "+44 7700 900456",
        "address":     "11 Acacia Avenue, Edinburgh EH3 9HJ, United Kingdom",
        "dob":         "1992-11-02",
        "ni_number":   "QQ 78 90 12 D",
        "kyc":         "verified",
        "balance":     102.33,
    },
    "12347": {
        "name":        "Marco Rossi",
        "email":       "marco.rossi.private@yahoo.it",
        "phone":       "+44 7700 900789",
        "address":     "Flat 6, 88 Bishopsgate, London EC2N 4BQ, United Kingdom",
        "dob":         "1979-07-22",
        "ni_number":   "QQ 34 56 78 A",
        "kyc":         "review",
        "balance":     18920.00,
    },
}


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
    """Return the full customer profile (PII).

    Returns the customer's full personal data: legal name, email, phone,
    home address, date of birth, NI number, and KYC status. Caller is
    expected to mask sensitive fields before any UI display.
    """
    with tracer.start_as_current_span("get_profile") as span:
        span.set_attribute("account.id", account_id)
        acct = ACCOUNTS.get(account_id)
        if not acct:
            return {"error": "account not found", "account_id": account_id}
        return {
            "account_id": account_id,
            "name":       acct["name"],
            "email":      acct["email"],
            "phone":      acct["phone"],
            "address":    acct["address"],
            "dob":        acct["dob"],
            "ni_number":  acct["ni_number"],
            "kyc_status": acct["kyc"],
        }


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)
