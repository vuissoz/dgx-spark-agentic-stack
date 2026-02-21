FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY deployments/gate_mcp/service.py /app/service.py

EXPOSE 8123

ENTRYPOINT ["python3", "/app/service.py"]
