FROM python:3.13-slim
# Standard library only: nothing to install at runtime.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PORT=8080
WORKDIR /app
COPY src ./src
USER nobody
EXPOSE 8080
CMD ["python", "-m", "app"]
