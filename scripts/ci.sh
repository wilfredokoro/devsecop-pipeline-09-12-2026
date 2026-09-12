#!/usr/bin/env bash
set -euo pipefail
source /opt/devsecops/tools.env
mkdir -p reports .work
export DOCKER_CONFIG="$PWD/.work/docker"
mkdir -p "$DOCKER_CONFIG"
IMAGE="127.0.0.1:5000/devsecops-demo:${BUILD_NUMBER:?}"
run_trivy() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -e TRIVY_CACHE_DIR=/cache -v /opt/devsecops/cache/trivy:/cache \
    -v "$PWD:/work" -w /work "$TRIVY_IMAGE" "$@"
}
deploy() {
  local environment=$1 digest=$2
  export DEPLOY_IMAGE="$digest"
  if [[ "$environment" == staging ]]; then
    export APP_CONTAINER=devsecops-staging APP_PORT=8082 HEALTH_PORT=18082
  else
    export APP_CONTAINER=devsecops-production APP_PORT=8083 HEALTH_PORT=18083
  fi
  docker compose -p "devsecops-$environment" -f deploy/compose.yaml up -d --pull always
}
health() {
  local port=$1
  for ((i=0; i<60; i++)); do
    if curl -fsS --max-time 3 "http://127.0.0.1:$port/actuator/health/readiness" | \
      python3 -c 'import json,sys; sys.exit(json.load(sys.stdin).get("status")!="UP")' 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}
case "${1:?Specify a stage}" in
  secrets)
    raw=$(mktemp)
    trap 'rm -f "$raw"' EXIT
    set +e
    docker run --rm -v "$PWD:/work:ro" "$TRUFFLEHOG_IMAGE" git file:///work \
      --results=verified,unknown,unverified --fail --json > "$raw" 2> .work/trufflehog.stderr
    rc=$?
    set -e
    # Whitelist fields. Do not archive raw secrets, verification details, or raw stderr.
    python3 - "$raw" <<'EOF'
import json,sys
from pathlib import Path
safe=[]
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.strip():
        item=json.loads(line)
        safe.append({'DetectorName':item.get('DetectorName'),'Verified':item.get('Verified')})
Path('reports/trufflehog-summary.json').write_text(json.dumps(safe,indent=2))
if safe: raise SystemExit('Secret findings present; pipeline blocked')
EOF
    if [[ "$rc" != 0 ]]; then echo "Secret scan blocked: status $rc. Check tool connectivity or repeat the scan in a restricted security workspace." >&2; exit "$rc"; fi
    ;;
  test) mvn -B -ntp clean verify ;;
  dependency)
    mvn -B -ntp "org.owasp:dependency-check-maven:$ODC_VERSION:check" \
      -DnvdApiKeyEnvironmentVariable=NVD_API_KEY -DfailBuildOnCVSS=7 \
      -DfailOnError=true -Dformats=HTML,JSON,XML \
      -Dodc.outputDirectory="$PWD/reports/dependency" -DdataDirectory=/opt/devsecops/cache/odc
    ;;
  sonar)
    mvn -B -ntp "org.sonarsource.scanner.maven:sonar-maven-plugin:$SONAR_SCANNER_VERSION:sonar" \
      -Dsonar.host.url=http://127.0.0.1:9000 -Dsonar.projectKey=devsecops-demo \
      -Dsonar.projectName=devsecops-demo -Dsonar.qualitygate.wait=true \
      -Dsonar.qualitygate.timeout=600 \
      -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
    ;;
  build)
    docker build --build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" \
      --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
      -t "$IMAGE" .
    docker save "$IMAGE" -o .work/image.tar
    ;;
  image)
    # Scanner writes JSON first. Gate from that same completed report below.
    run_trivy image --input /work/.work/image.tar --timeout 20m --scanners vuln \
      --format json --output /work/reports/trivy.json
    touch reports/trivy-complete
    python3 scripts/image-gate.py
    run_trivy image --input /work/.work/image.tar --timeout 20m --scanners secret \
      --exit-code 1 --format json --output /work/.work/image-secrets.json
    run_trivy image --input /work/.work/image.tar --format cyclonedx \
      --output /work/reports/sbom.cdx.json
    ;;
  push)
    docker push "$IMAGE"
    digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE")
    [[ "$digest" == 127.0.0.1:5000/devsecops-demo@sha256:* ]]
    printf '%s
' "$digest" > reports/image-digest.txt
    git rev-parse HEAD > reports/git-commit.txt
    cp /opt/devsecops/tools.env reports/tool-versions.txt
    ;;
  staging)
    deploy staging "$(cat reports/image-digest.txt)"
    health 18082
    curl -fsS http://127.0.0.1:8082/api/hello > reports/staging-smoke.json
    ;;
  dast)
    mkdir -p reports/zap
    # ZAP needs write access to its mounted report directory; match the host uid.
    set +e
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
      --network devsecops-runtime -v "$PWD/reports/zap:/zap/wrk:rw" \
      "$ZAP_IMAGE" zap-baseline.py -t http://devsecops-staging:8080/ \
      -J zap.json -r zap.html -m 1
    rc=$?
    set -e
    if [[ "$rc" -gt 2 ]]; then echo 'ZAP execution failed; promotion blocked'; exit "$rc"; fi
    python3 scripts/zap-gate.py reports/zap/zap.json
    ;;
  production)
    previous=$(docker inspect -f '{{.Config.Image}}' devsecops-production 2>/dev/null || true)
    printf '%s
' "$previous" > reports/previous-image.txt
    if deploy production "$(cat reports/image-digest.txt)" && health 18083 && \
      curl -fsS http://127.0.0.1:8083/api/hello > reports/production-smoke.json; then
      touch reports/promoted
    else
      echo 'Deployment failed; restoring previous image' >&2
      if [[ "$previous" == *@sha256:* ]]; then
        deploy production "$previous"
        health 18083 || { echo 'ROLLBACK ALSO FAILED; incident response required' >&2; exit 2; }
        echo 'Previous image restored' >&2
      else
        docker rm -f devsecops-production || true
        echo 'First deployment failed; no previous release exists' >&2
      fi
      exit 1
    fi
    ;;
  cleanup)
    rm -rf .work
    ;;
  *) echo 'Unknown stage' >&2; exit 2 ;;
esac
