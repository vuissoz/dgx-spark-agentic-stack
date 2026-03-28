FROM nvcr.io/nvidia/tensorrt-llm/release:1.3.0rc5

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY deployments/trtllm/server.py /app/server.py

EXPOSE 11436

ENTRYPOINT ["python3", "/app/server.py"]
