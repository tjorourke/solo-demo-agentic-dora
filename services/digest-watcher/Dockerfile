FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    "aiohttp>=3.10" \
    "httpx>=0.27" \
    "kubernetes>=30.1" \
    "prometheus-client>=0.20"

COPY server.py /app/server.py

EXPOSE 8080 9090
CMD ["python", "/app/server.py"]
