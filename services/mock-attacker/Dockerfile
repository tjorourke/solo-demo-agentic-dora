FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir "aiohttp>=3.10"
COPY server.py /app/server.py
EXPOSE 8080
CMD ["python", "/app/server.py"]
