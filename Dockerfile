# Photobank server image. Used for the public demo on Railway (DEMO.md); works for
# any Linux host. Web UI is built in a node stage and served by FastAPI.
FROM node:22-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY server/requirements.txt server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt
COPY server/ server/
COPY --from=web /web/dist web/dist
WORKDIR /app/server
EXPOSE 8000
# $PORT is injected by Railway/Render/Fly; one worker keeps a 0.5 GB container comfortable
CMD ["sh", "-c", "python -m uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1"]
