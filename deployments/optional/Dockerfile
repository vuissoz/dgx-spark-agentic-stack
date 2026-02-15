FROM python:3.12-alpine

RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY deployments/optional/optional_service.py /app/optional_service.py
USER app
ENTRYPOINT ["python3", "/app/optional_service.py"]
