#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f versions.env ]]; then
  echo 'versions.env exists; keep it for reproducibility. Review updates in a separate checkout.' >&2
  exit 1
fi
lock=$(mktemp)
trap 'rm -f "$lock"' EXIT
pin() {
  local name=$1 ref=$2 digest
  docker pull "$ref" >&2
  digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$ref")
  [[ "$digest" == *@sha256:* ]]
  printf '%s=%s
' "$name" "$digest" >> "$lock"
}
# Bootstrap channels ONLY. CI consumes the resulting immutable references.
pin JENKINS_IMAGE jenkins/jenkins:lts-jdk21
pin SONAR_IMAGE sonarqube:community
pin POSTGRES_IMAGE postgres:17
pin PROMETHEUS_IMAGE prom/prometheus:latest
pin GRAFANA_IMAGE grafana/grafana:latest
pin PYTHON_IMAGE python:3.12-slim
pin REGISTRY_IMAGE registry:3
pin TRUFFLEHOG_IMAGE trufflesecurity/trufflehog:latest
pin TRIVY_IMAGE aquasec/trivy:latest
pin ZAP_IMAGE ghcr.io/zaproxy/zaproxy:stable
pin RUNTIME_IMAGE eclipse-temurin:21-jre-jammy
python3 scripts/resolve-maven.py >> "$lock"
mv "$lock" versions.env
python3 - <<'EOF'
from pathlib import Path
values=dict(line.split('=',1) for line in Path('versions.env').read_text().splitlines())
p=Path('pom.xml')
p.write_text(p.read_text().replace('BOOT_VERSION',values['BOOT_VERSION']).replace('JACOCO_VERSION',values['JACOCO_VERSION']))
EOF
printf 'Locked images and Maven versions. Review versions.env and the resolved pom.xml before proceeding.
'
