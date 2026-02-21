FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY deployments/trtllm/server.py /app/server.py

EXPOSE 11436

ENTRYPOINT ["python3", "/app/server.py"]
