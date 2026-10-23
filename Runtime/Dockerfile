# syntax=docker/dockerfile:1
FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv git gh ripgrep ca-certificates curl build-essential unzip && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/zeus
COPY Runtime/requirements.txt .
RUN python3 -m venv /opt/venv
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then PIP_CERT=/run/secrets/proxy_ca /opt/venv/bin/pip install --no-cache-dir -r requirements.txt; else /opt/venv/bin/pip install --no-cache-dir -r requirements.txt; fi
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then NODE_EXTRA_CA_CERTS=/run/secrets/proxy_ca npm install -g @openai/codex@0.163.0; else npm install -g @openai/codex@0.163.0; fi
COPY Runtime/agent_service ./agent_service
ENV PATH="/opt/venv/bin:${PATH}" ZEUS_DATA_DIR=/data PORT=8080
RUN useradd --uid 10001 --create-home zeus && mkdir /data && chown zeus:zeus /data
USER zeus
VOLUME ["/data"]
EXPOSE 8080
CMD ["python", "-m", "agent_service"]
