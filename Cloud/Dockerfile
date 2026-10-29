FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends bash git curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home zeus-tool
WORKDIR /opt/zeus
COPY Cloud/requirements.lock /opt/zeus/requirements.lock
RUN pip install --no-cache-dir -r requirements.lock
COPY Cloud/zeus_cloud /opt/zeus/zeus_cloud
COPY .openminis/ZEUSDefaultSkills /opt/zeus/builtin-skills
RUN chmod -R a+rX /opt/zeus/builtin-skills
# Only the API runs as root so commands can drop to UID 10001 with a scrubbed
# environment. No database key or auth token is inherited by a tool subprocess.
ENV PORT=8080 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["python", "-m", "zeus_cloud"]
