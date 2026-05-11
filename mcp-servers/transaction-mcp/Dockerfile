FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    "mcp[server]>=1.2.0" \
    "fastmcp>=0.4.0" \
    "uvicorn[standard]>=0.30" \
    "google-adk>=0.5" \
    "opentelemetry-api>=1.27" \
    "opentelemetry-sdk>=1.27" \
    "opentelemetry-exporter-otlp>=1.27"

COPY server.py /app/server.py

EXPOSE 8080
CMD ["python", "/app/server.py"]
