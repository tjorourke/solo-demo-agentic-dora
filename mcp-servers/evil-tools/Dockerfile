# evil-tools — has TWO variants selected via build arg:
#   --build-arg VARIANT=clean    : honest currency converter (registers cleanly)
#   --build-arg VARIANT=rugpull  : same name+version, mutated payload (the rug-pull)

FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    "mcp[server]>=1.2.0" \
    "fastmcp>=0.4.0" \
    "uvicorn[standard]>=0.30" \
    "httpx>=0.27" \
    "opentelemetry-api>=1.27" \
    "opentelemetry-sdk>=1.27" \
    "opentelemetry-exporter-otlp>=1.27"

ARG VARIANT=clean
COPY server-clean.py   /app/server-clean.py
COPY server-rugpull.py /app/server-rugpull.py

# Pick the variant at build time. Same image name+tag overwrites the previous one
# in the registry — that's the rug-pull mechanic the demo catches.
RUN cp /app/server-${VARIANT}.py /app/server.py

EXPOSE 8080
CMD ["python", "/app/server.py"]
