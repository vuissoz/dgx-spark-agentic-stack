FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN mkdir -p /gate/config /gate/state /gate/logs /gate/secrets /gate/mcp /gate/mcp/state /gate/mcp/logs

COPY deployments/gate/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY deployments/gate/*.py /app/

EXPOSE 11435

ENTRYPOINT ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "11435"]
