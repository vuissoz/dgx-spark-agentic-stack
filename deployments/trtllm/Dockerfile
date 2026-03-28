FROM nvcr.io/nvidia/tensorrt-llm/release:1.2.0rc6

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY deployments/trtllm/server.py /app/server.py

EXPOSE 11436

ENTRYPOINT ["python3", "/app/server.py"]
