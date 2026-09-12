# Complete DevSecOps CI/CD Pipeline: implementation runbook

Prepared for Wilfred Okoro • 12 September 2026

This runbook turns the supplied article into a concrete, security-gated reference implementation. Start with the provided files, follow the steps in order, and verify each checkpoint. You will build a small Java service, scan it, publish an immutable container image, deploy staging, scan the running application, approve promotion, and observe the result in Grafana.

**Scope and verification:** The included source and configurations are a reference implementation for a dedicated Ubuntu lab. Syntax, configuration structure, and selected gate behavior were checked during preparation. Docker, Maven, Jenkins, and AWS deployment were not executed in the authoring environment. Your first real build is the integration test; this document specifies how to perform it and diagnose failures. A passing scan is a policy result, not proof that an application has no vulnerabilities.

**Production distinction:** “production” in the Compose files is a second lab environment. The single host, Docker-privileged build agent, and local HTTP registry are deliberate lab shortcuts. Do not expose this stack as a customer production platform. Section 22 explains the additional production controls and section 23 supplies an ECR/EKS extension. No AWS resources or paid services are created by the main path.

## 1. Final result and architecture

By the end, these components work together:

| Component | Responsibility | Local access through SSH tunnel |
|---|---|---|
| Git repository | Application, tests, pipeline, deployment definitions | Your Git provider |
| Jenkins controller | Orchestration, credentials, build history, approval | http://localhost:8080 |
| Dedicated host agent | Maven, Docker, scans and deployment execution | Jenkins node status |
| SonarQube + PostgreSQL | Static analysis and persistent quality results | http://localhost:9000 |
| Local registry | Candidate image storage for the lab | Host loopback port 5000 |
| TruffleHog | Git history secret detection | Sanitized Jenkins artifact |
| Dependency-Check | Maven dependency vulnerability gate | Jenkins report artifacts |
| Trivy | Image CVEs, image secrets, CycloneDX SBOM | Jenkins report artifacts |
| Staging application | Target for pre-promotion testing | http://localhost:8082 |
| Production lab application | Approved release | http://localhost:8083 |
| OWASP ZAP | Passive baseline scan of staging | Jenkins JSON/HTML artifacts |
| Custom metrics exporter | Actual pipeline counters and latest scan data | Internal port 9101 |
| Prometheus + Grafana | Metrics storage, dashboards, alert rules | Ports 9090 and 3000 |

The pipeline order is:

1. Checkout the protected `main` branch with history.
2. Scan Git history for secrets.
3. Compile, test, package and enforce coverage in one Maven lifecycle.
4. Gate third-party dependencies.
5. Run SonarQube analysis and wait for the quality result.
6. Build the container from the already-tested JAR.
7. Scan the image and produce an SBOM.
8. Push a candidate to the registry and record its digest.
9. Deploy that digest to staging and check readiness and the API.
10. Run ZAP against staging and evaluate its report.
11. Optionally request a release-manager approval.
12. Deploy the exact same digest to the production lab.
13. On failed production health verification, restore the previous digest.
14. Archive evidence and update metrics even when a gate fails.

Registry publication happens before DAST because staging needs a distributable artifact. **A registry candidate is not an approved release.** Only a digest that passes staging checks may be promoted. The starter does not rebuild an image during promotion.

## 2. Corrections to the supplied article

| Original problem | Implemented correction |
|---|---|
| A scan runs but has no failing policy | Explicit exit handling or JSON gate |
| Unit-test failures are ignored | `mvn clean verify`; failed tests stop the build |
| Sonar analysis finishes without checking its gate | `sonar.qualitygate.wait=true` |
| Dockerfile rebuilds an artifact separately | Copy the JAR already built and tested by CI |
| `latest` tags are deployed | Record and deploy `repository@sha256:...` |
| Scanner container uses `localhost` for another container | ZAP targets the staging container DNS name on a shared network |
| Secret scanner does not mount the repository | Read-only repository mount with `.git` history |
| Raw secret JSON is retained | Archive only an allowlist of nonsecret summary fields |
| DAST runs after the final release | Scan staging before promotion |
| Baseline ZAP is described as active injection testing | Label it passive baseline; active/API/authenticated testing is an extension |
| SonarQube is treated as a Prometheus exporter | Use a real metrics producer; do not invent metric names |
| Rollback restarts without selecting the old image | Capture and redeploy the previous digest |
| Controller and application compete for port 8080 | Separate host ports and internal service ports |
| Host services are public by default | Bind UI and application ports to loopback |

Current Jenkins releases require a supported JVM; this guide uses Java 21 for controller and agent. See the [Jenkins Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/). Scanner policies here are implementation choices, not vendor claims that these thresholds suit every organization.

## 3. Choose the machine

Use a **dedicated Ubuntu 24.04 LTS x86-64 host**, with:

- 8 vCPUs preferred; 4 for a slower lab.
- 32 GB RAM preferred; 16 GB may require lower concurrency and careful monitoring.
- 150 GB SSD preferred, including image layers, Maven cache and scan databases.
- A non-root sudo user.
- Outbound HTTPS and working DNS to GitHub, Maven Central, Docker registries, vulnerability feeds and update repositories.
- SSH restricted to your administration network.

These are sizing estimates, not measured capacity guarantees. No parallel Jenkins executors are needed for the first run.

If you administer it from a Mac, use Terminal, Git and SSH on the Mac and run the stack on this Linux host. The following installation commands are **Ubuntu commands**, not macOS commands. This avoids SonarQube kernel-limit and multi-architecture complications. A VM with the stated resources or a dedicated cloud VM works. If using AWS, provision the VM separately, use encrypted storage, restrict inbound SSH, and remember that compute and storage incur charges.

Check the host:

```bash
uname -m
cat /etc/os-release
free -h
df -h
nproc
```

Expected architecture: `x86_64`. Do not mix ARM runtime images with an x86 deployment target.

## 4. Unpack and install Docker, Java and Maven

If `unzip` is missing on a fresh host, install it with `sudo apt-get update` followed by `sudo apt-get install -y unzip`. Extract this package on the Ubuntu host:

```bash
unzip devsecops-pipeline.zip
cd devsecops-pipeline
```

All subsequent repository-relative commands assume this directory unless a step says otherwise.

On a fresh Ubuntu host, configure Docker's package repository:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git unzip jq python3 openssl openjdk-21-jdk maven
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and back in, then check:

```bash
docker version
docker compose version
java -version
mvn -version
docker run --rm hello-world
```

Java and Maven must report Java 21. If multiple JDKs exist, select Java 21 with `sudo update-alternatives --config java` and `sudo update-alternatives --config javac`, then recheck Maven.

If the host already has Docker packages, follow the conflict-handling instructions in [Docker's Ubuntu installation guide](https://docs.docker.com/engine/install/ubuntu/) before replacing packages. Do not remove a working Docker installation or its data as a troubleshooting shortcut.

**Checkpoint:** Your user can run Docker without sudo, and Maven starts with Java 21.

## 5. Configure host limits and the build identity

SonarQube's embedded search engine requires host resource limits. Apply them on this dedicated lab host:

```bash
sudo tee /etc/sysctl.d/99-devsecops-sonar.conf >/dev/null <<'EOF_SYSCTL'
vm.max_map_count=524288
fs.file-max=131072
EOF_SYSCTL
sudo sysctl --system
sysctl vm.max_map_count fs.file-max
```

The Compose file also sets container `nofile` and `nproc` limits. See [SonarSource's Linux prerequisites](https://docs.sonarsource.com/sonarqube-server/2026.1/server-installation/pre-installation/linux).

Create the host agent user and persistent cache paths:

```bash
sudo useradd --create-home --home-dir /var/lib/jenkins-agent --shell /bin/bash jenkins-agent
sudo usermod -aG docker jenkins-agent
sudo install -d -o jenkins-agent -g jenkins-agent -m 0750 /opt/devsecops/cache/odc /opt/devsecops/cache/trivy
sudo install -d -o jenkins-agent -g jenkins-agent -m 0755 /opt/devsecops/metrics
sudo install -d -o root -g root -m 0755 /opt/devsecops

docker network create devsecops-runtime
```

Skip `useradd` or network creation if the named resource already exists; inspect it first. The agent's Docker group access is effectively host-root access. This agent must run only trusted repository code. Although the controller has no Docker socket mount and has zero executors, a compromised agent on this same Docker host can still affect the controller. Separate hosts and short-lived agents are required for a stronger production boundary.

## 6. Resolve and lock the toolchain

Run:

```bash
bash scripts/lock-tools.sh
```

The script:

1. Pulls the explicitly listed upstream bootstrap image channels.
2. Captures each immutable registry digest.
3. Resolves a stable Spring Boot 3.5 patch, JaCoCo release, Dependency-Check plugin and Sonar Maven scanner from Maven Central metadata.
4. Writes `versions.env`.
5. Replaces the two template tokens in `pom.xml` with concrete versions.

The template `pom.xml` intentionally will not build until this step succeeds. The selected versions are a bootstrap starting point; they are not asserted to be mutually tested, vulnerability-free, or the latest supported product family. Version discovery uses current metadata on **your setup date**. Review the selected release notes and security advisories. If a tool's current stable release introduces an incompatible change, select a supported version deliberately and re-lock in a review branch.

Review and install the lock file:

```bash
cat versions.env
rg 'BOOT_VERSION|JACOCO_VERSION' pom.xml
sudo install -o root -g root -m 0644 versions.env /opt/devsecops/tools.env
```

The `rg` command should find no unresolved tokens; no output is expected. If `rg` is not installed, use `grep -E 'BOOT_VERSION|JACOCO_VERSION' pom.xml`.

The lock contains image references and version numbers, not credentials. Commit a reviewable copy:

```bash
cp versions.env toolchain.lock.env
```

CI loads `/opt/devsecops/tools.env`; it does not automatically refresh versions on every build. Review changes to both this file and `pom.xml` together. Image digest pinning is reproducibility, not vendor identity verification or image signing.

## 7. Generate local service passwords and start the tools

Generate local credentials without typing passwords into shell command arguments:

```bash
umask 077
python3 - <<'PY'
from pathlib import Path
import secrets
p=Path('.env')
if p.exists():
    raise SystemExit('.env already exists; preserve the existing database password')
p.write_text('SONAR_DB_PASSWORD='+secrets.token_hex(24)+'\nGRAFANA_PASSWORD='+secrets.token_hex(24)+'\n')
PY

docker compose --env-file versions.env --env-file .env -f infra/compose.yaml config --quiet
docker compose --env-file versions.env --env-file .env -f infra/compose.yaml up -d
docker compose --env-file versions.env --env-file .env -f infra/compose.yaml ps
```

Do not print the full rendered Compose configuration into shared logs: it contains environment credentials. The lab stores service passwords in a permission-restricted `.env` and container configuration. Use a managed secret integration for production.

Inspect startup failures:

```bash
docker compose --env-file versions.env --env-file .env -f infra/compose.yaml logs --tail=100 sonarqube db jenkins
curl -fsS http://127.0.0.1:9000/api/system/status
curl -fsS http://127.0.0.1:5000/v2/
```

SonarQube may take several minutes. Wait for status `UP`. The registry returns `{}`. Prometheus will show the application target DOWN until the production lab is deployed; this is expected.

**Checkpoint:** Jenkins setup page, SonarQube login page and Grafana login page load.

## 8. Access the UIs from your Mac

Run this on the **Mac**, replacing the SSH user and host:

```bash
ssh -N \
  -L 8080:127.0.0.1:8080 \
  -L 9000:127.0.0.1:9000 \
  -L 3000:127.0.0.1:3000 \
  -L 9090:127.0.0.1:9090 \
  -L 8082:127.0.0.1:8082 \
  -L 8083:127.0.0.1:8083 \
  ubuntu@YOUR_HOST
```

Keep that terminal open. Open the localhost links from section 1 in your Mac browser. If a local port is occupied, change only the left side of its tunnel mapping, for example `-L 18080:127.0.0.1:8080` for Jenkins; browse port 18080 on the Mac.

Do not open all these ports in a cloud security group. Loopback binding plus the SSH tunnel is sufficient for the lab.

## 9. Configure Jenkins

On Ubuntu, retrieve the bootstrap password:

```bash
docker compose --env-file versions.env --env-file .env -f infra/compose.yaml exec jenkins \
  cat /var/jenkins_home/secrets/initialAdminPassword
```

Treat this as a secret. In the browser:

1. Open Jenkins and paste the bootstrap password.
2. Install suggested plugins.
3. Create your named administrator with a strong password.
4. Set the lab Jenkins URL to `http://localhost:8080/`.
5. In **Manage Jenkins → Plugins**, verify these are installed: Pipeline, Git, Credentials Binding, JUnit, Timestamper, and Workspace Cleanup if desired. The included Jenkinsfile uses built-in workspace steps and does not require Docker Pipeline, SonarQube Scanner for Jenkins, or Dependency-Check plugins.
6. Restart Jenkins if plugin installation requests it.
7. Go to **Manage Jenkins → Nodes → Built-In Node → Configure** and set executors to **0**.
8. Keep authentication enabled and anonymous access disabled. Configure authorization so ordinary users cannot administer credentials, modify jobs, or approve releases.
9. Create a named user `release-manager` for the approval step. In a real team, map approval to your authorized release group. Jenkins administrators may still approve; do not mistake the `submitter` field for a full separation-of-duties control.

For reproducible infrastructure after the initial learning run, export and review your Jenkins Configuration as Code and exact installed plugin versions. The package does not automate identity/authorization provisioning or a plugin lock.

## 10. Connect the dedicated build agent

In Jenkins:

1. **Manage Jenkins → Nodes → New Node**.
2. Name: `devsecops-agent`.
3. Type: permanent agent.
4. Executors: **1**.
5. Remote root: `/var/lib/jenkins-agent`.
6. Label: `devsecops-agent`.
7. Usage: only jobs whose label expression matches this node.
8. Launch method: launch agent by connecting it to the controller.
9. Save and open the node page to obtain its agent secret and connection command.

On Ubuntu, install the controller's matching agent JAR:

```bash
sudo curl -fsS http://127.0.0.1:8080/jnlpJars/agent.jar -o /opt/devsecops/agent.jar
sudo chmod 0644 /opt/devsecops/agent.jar
sudo install -o jenkins-agent -g jenkins-agent -m 0600 /dev/null /opt/devsecops/agent.secret
sudo -u jenkins-agent nano /opt/devsecops/agent.secret
```

Paste **only** the secret shown for this node, save and close. If `nano` is unavailable, use an installed editor. Do not commit it or include it in a command-line literal.

Create the service:

```bash
sudo tee /etc/systemd/system/devsecops-agent.service >/dev/null <<'EOF_AGENT'
[Unit]
Description=Jenkins DevSecOps lab build agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=jenkins-agent
Group=jenkins-agent
SupplementaryGroups=docker
WorkingDirectory=/var/lib/jenkins-agent
ExecStart=/usr/bin/java -jar /opt/devsecops/agent.jar -url http://127.0.0.1:8080/ -secret @/opt/devsecops/agent.secret -name devsecops-agent -webSocket -workDir /var/lib/jenkins-agent
Restart=always
RestartSec=10
UMask=0022

[Install]
WantedBy=multi-user.target
EOF_AGENT

sudo systemctl daemon-reload
sudo systemctl enable --now devsecops-agent
sudo systemctl status devsecops-agent --no-pager
sudo -u jenkins-agent docker version
sudo -u jenkins-agent mvn -version
```

Use the connection syntax displayed by your installed Jenkins if it differs; the package assumes a current inbound agent with WebSocket and secret-file support. The controller and host agent communicate through host loopback, so no inbound TCP agent port 50000 is needed.

**Checkpoint:** Jenkins shows `devsecops-agent` online, with one executor; the built-in node has zero executors.

## 11. Configure SonarQube and its quality gate

1. Open SonarQube at port 9000.
2. Use the initial administrator login documented for the selected image and change the password immediately; typical fresh community images initialize `admin`/`admin`.
3. Create a local project with key **`devsecops-demo`**.
4. Create a project analysis token with an expiration, scoped to this project.
5. In Jenkins, add a **Secret text** credential with ID **`sonar-token`** and that token.
6. Assign a quality gate to the project. For this lab, require no new security issues, no new reliability issues at your chosen threshold, new-code coverage of at least 80%, and reviewed security hotspots according to your review process.
7. Define the new-code baseline intentionally, for example previous version or a reference period supported by your edition.
8. Keep the built-in overall JaCoCo 80% check as well: Sonar new-code rules can behave differently on a very small initial project.

The pipeline passes the token through the `SONAR_TOKEN` environment variable and waits for the gate. It does not require a Sonar webhook. See [SonarQube analysis parameters](https://docs.sonarsource.com/sonarqube-community-build/analyzing-source-code/analysis-parameters/parameters-not-settable-in-ui).

If you later switch to Jenkins `waitForQualityGate`, install/configure the Sonar Jenkins plugin and its webhook, including the trailing `/sonarqube-webhook/` path and webhook secret. Do not configure half of each mechanism.

Sonar features, security rules and branch/PR capabilities depend on edition and version. This starter uses a single protected main-branch project; do not assume free edition capabilities equal commercial SAST or PR analysis.

## 12. Obtain an NVD API key and configure Jenkins credentials

Request and activate a key through the [NVD API key page](https://nvd.nist.gov/developers/request-an-api-key). In Jenkins, add a Secret text credential:

| ID | Type | Value |
|---|---|---|
| `nvd-api-key` | Secret text | Activated NVD API key |
| `sonar-token` | Secret text | Project analysis token |
| `git-read` | Username/password or SSH key, only if private repository | Read-only repository credential |

Place credentials at the narrowest folder scope your Jenkins job uses. Restrict who can modify trusted pipeline code, because code executed in a credential binding can read that credential.

Dependency-Check runs with a CVSS threshold of 7 and fails on execution errors. It caches data under `/opt/devsecops/cache/odc`. The initial database synchronization may take significantly longer than subsequent scans. An NVD/feed outage is a scanner failure, not a clean scan. The environment-variable key mechanism is documented in [Dependency-Check Maven parameters](https://dependency-check.github.io/DependencyCheck/dependency-check-maven/check-mojo.html).

Do not disable NVD updates, hide execution failures, or increase the threshold merely to make the first run green. If a new plugin version requires a new database format, back up or replace that specific cache following its upgrade notes.

## 13. Put the starter in your Git repository

Create an empty private repository, for example `devsecops-pipeline`, in your account. Then, from the prepared Ubuntu checkout:

```bash
git init -b main
git add .
git status --short
git diff --cached --stat
```

Before committing, confirm that `.env`, `versions.env`, private keys, agent secrets and reports are absent from the staged list. `toolchain.lock.env` and the now-resolved `pom.xml` should be present.

```bash
git commit -m "Add security-gated Jenkins pipeline and demo application"
git remote add origin git@github.com:YOUR_ACCOUNT/devsecops-pipeline.git
git push -u origin main
```

Replace the remote with your actual repository URL. For a private repository, add the matching read credential to Jenkins. Use a read-only deploy key or minimally scoped token. Configure SSH host-key verification; do not disable it to suppress checkout errors.

Protect `main`: require reviewed pull requests, prevent force pushes, require your CI checks when you have integrated status reporting, and restrict direct pushes. Enforce signed commits if your organization requires them. Protect changes to `Jenkinsfile`, `scripts/`, deployment files and toolchain lock with designated reviewers.

This starter is a **trusted-main release pipeline**. It is not safe to execute arbitrary fork pull requests with its Docker permissions and release credentials. Production systems need a separate untrusted PR validation path without those permissions.

## 14. Create the pipeline job and its automatic trigger

1. Jenkins → **New Item** → name `devsecops-main` → **Pipeline**.
2. Definition: **Pipeline script from SCM**.
3. SCM: Git.
4. Repository: your actual URL.
5. Credentials: `git-read` if needed.
6. Branch specifier: `*/main`.
7. Script path: `Jenkinsfile`.
8. Do not enable shallow clone; the secret scan should see full available history.
9. For the loopback-only lab, enable **Poll SCM** with `H/2 * * * *`.
10. Save, then choose **Build Now**.

Polling makes this private lab automatic without exposing Jenkins to GitHub. It checks periodically and builds after a source change. Once Jenkins reads the Jenkinsfile, parameterized runs expose `PROMOTE_TO_PRODUCTION`.

For a public webhook deployment later:

1. Put Jenkins behind a properly authenticated/TLS-configured reverse proxy with a stable DNS name.
2. Configure the relevant GitHub integration plugin and minimum repository/app permissions.
3. Use the plugin's documented webhook URL, typically `https://jenkins.example.com/github-webhook/`.
4. Configure the webhook secret where supported and verify signatures; require only needed event types.
5. Enable the corresponding GitHub push trigger in the Jenkins job.
6. Use the provider's webhook delivery view to confirm a successful request, then make a harmless commit and verify exactly one expected build.

Do not point GitHub at `localhost`: from GitHub, that is not your Jenkins host. The package does not create an internet-facing endpoint or send notifications on your behalf.

## 15. Understand and verify every gate

The implementation lives in `Jenkinsfile` and `scripts/ci.sh`; edit those files through review, not by pasting a second pipeline into Jenkins.

| Gate | Concrete implementation | Promotion stops when |
|---|---|---|
| Git secrets | Official TruffleHog image scans `git file:///work` with history mounted | Selected verified, unknown or unverified finding; scan failure |
| Tests | `mvn -B -ntp clean verify` | Compile or test failure |
| Coverage | JaCoCo check in `pom.xml` | Overall line coverage below 80% |
| Dependencies | Dependency-Check Maven plugin | CVSS threshold violation or execution failure |
| SAST/quality | Maven Sonar scanner waits for result | Server gate failure, timeout or analysis error |
| Image vulnerabilities | Completed Trivy JSON report parsed by policy | HIGH or CRITICAL finding; invalid report |
| Image secrets | Trivy secret scanner with `--exit-code 1` | Secret finding or scan failure |
| Staging health | Readiness polling and `/api/hello` request | No readiness within timeout or request failure |
| ZAP | Validate report and severity policy | Medium/high alert type, missing report/site or tool execution error |
| Approval | Jenkins `input`, named submitter | Not approved within 15 minutes |
| Production health | Same checks after digest deployment | Failure initiates rollback and fails the build |

The policy intentionally does **not** auto-accept unfixed HIGH/CRITICAL vulnerabilities. If risk acceptance is justified, use a separately reviewed, narrow exception with owner, reason, affected version/CVE and expiry; add an auditable implementation of it rather than scattering `|| true` through scanner stages.

TruffleHog's JSON can contain actual credentials. This starter archives only detector name and verification status, then removes raw output. Review a positive finding using restricted security tooling, identify its commit/path, revoke or rotate the credential, assess use and exposure, and coordinate history cleanup if required. `.gitignore` does not erase a secret already committed. See the [official TruffleHog repository](https://github.com/trufflesecurity/trufflehog).

The container copies the JAR produced by Maven instead of compiling twice. Its runtime has numeric non-root UID 10001, a read-only filesystem, writable `/tmp`, dropped capabilities, resource limits and no service-account token. The demo is stateless and intentionally has no database or user authentication; its headers do not substitute for authorization in a real application.

Trivy defaults can report findings without failing. Here a completed vulnerability report is evaluated by a script and the separate secret scanner uses an explicit failing exit code. See [Trivy exit-code behavior](https://trivy.dev/docs/latest/guide/configuration/others/) and [image CLI options](https://trivy.dev/docs/latest/references/configuration/cli/trivy_image/).

**Checkpoint:** Any failed stage is red, later deployment stages are skipped, and available sanitized reports appear in that build's artifacts.

## 16. Run staging and inspect the evidence

First run with production promotion unchecked. The stages can take a while during first-time downloads and scan database initialization. The overall timeout is 150 minutes; use logs to distinguish real progress from a blocked dependency.

When all staging gates pass, on Ubuntu:

```bash
curl -fsS http://127.0.0.1:8082/
curl -fsS http://127.0.0.1:8082/api/hello
curl -fsS http://127.0.0.1:18082/actuator/health/readiness
docker inspect devsecops-staging --format '{{.Config.Image}}'
```

Expected application content includes:

```json
{"application":"Gavok DevSecOps Demo","status":"running"}
```

JSON property ordering may differ. Readiness returns `UP`. The image reference ends in a SHA-256 digest.

In Jenkins artifacts, inspect:

| File | Meaning |
|---|---|
| `trufflehog-summary.json` | Safe secret-scan finding summary |
| `dependency/dependency-check-report.*` | Dependency inventory and vulnerability evidence |
| `trivy.json` | Completed image vulnerability report |
| `sbom.cdx.json` | CycloneDX component inventory |
| `image-digest.txt` | Exact candidate that was deployed |
| `git-commit.txt` | Source revision |
| `tool-versions.txt` | Toolchain references used |
| `staging-smoke.json` | Staging API response |
| `zap/zap.html`, `zap/zap.json` | Passive DAST results |
| `zap-summary.json` | Alert-type counts used by the gate |
| `target/site/jacoco/` | Coverage report |

An early gate failure means later files do not exist. An absent report is not a report of zero findings. Scan findings and application behavior must be assessed on the actual selected versions; the package does not promise the first dependency set will pass all current CVEs.

## 17. What ZAP does, and how to expand DAST

The automated baseline scans staging through `http://devsecops-staging:8080/`. It does not use `localhost`, because the scanner is a different container. Its writable mount matches the agent UID.

The baseline spider and passive rules find issues such as insecure response headers and information disclosure. This is **not** comprehensive SQL injection, access-control or authenticated business-logic testing. The starter's small JSON-only surface also limits spider discovery. ZAP baseline exit codes distinguish findings from execution errors; the starter accepts only valid completion statuses for further JSON evaluation. See [ZAP baseline documentation](https://www.zaproxy.org/docs/docker/baseline-scan/).

For active testing, run only against an environment you own and explicitly authorize, using disposable data. On this lab, with staging running:

```bash
source /opt/devsecops/tools.env
mkdir -p reports/zap-active
set +e
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --network devsecops-runtime \
  -v "$PWD/reports/zap-active:/zap/wrk:rw" \
  "$ZAP_IMAGE" zap-full-scan.py \
  -t http://devsecops-staging:8080/ -m 2 \
  -J zap.json -r zap.html
zap_status=$?
set -e
if [ "$zap_status" -gt 2 ]; then
  echo 'Active scanner execution failed'
  exit "$zap_status"
fi
python3 scripts/zap-gate.py reports/zap-active/zap.json
```

Run this from the repo as a user with Docker access; it scans the lab target. The script has an active scan phase, so use a larger pipeline timeout when wiring it into CI. Its exit conventions are documented in [ZAP full scan](https://www.zaproxy.org/docs/docker/full-scan/).

For a real REST API, publish an OpenAPI definition and use ZAP API scanning so endpoints are explicitly enumerated. For authenticated applications, configure a ZAP context and test accounts for each role, seed state, validate session handling and verify that authenticated requests actually succeed. Create explicit tests for horizontal and vertical privilege escalation. Before claiming production DAST coverage, record which routes, methods and roles were exercised. Add the active/API stage before approval and gate its reports; the starter does not claim those extensions are already automated.

## 18. Promote and verify the final application

In Jenkins, choose **Build with Parameters**, check `PROMOTE_TO_PRODUCTION`, and start the build. It reruns the gates. When the approval stage appears:

1. Inspect the digest and reports for that build.
2. Sign in as the configured release approver.
3. Approve within 15 minutes.
4. Observe the production deployment and health verification stage.

On Ubuntu:

```bash
curl -fsS http://127.0.0.1:8083/
curl -fsS http://127.0.0.1:8083/api/hello
curl -fsS http://127.0.0.1:18083/actuator/health/readiness

docker inspect devsecops-staging --format '{{.Config.Image}}'
docker inspect devsecops-production --format '{{.Config.Image}}'
docker inspect devsecops-production --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}}'
```

The staging and production image references must be identical. Container settings should show user `10001:10001` and `true` for the read-only filesystem.

Open `http://localhost:8083` through the SSH tunnel. This is the user-visible final lab application.

The rollout in Compose is a single-instance replacement and may briefly interrupt service. It is not blue-green or canary deployment. The Kubernetes extension supports rolling updates but still needs production traffic and availability design.

## 19. Rollback and failure exercises

The production stage records the existing container's digest before deploying. If the new container fails readiness or the API request, it attempts to redeploy that previous digest and verify it. If rollback itself fails, the build prints a distinct incident message and remains failed. On the very first failed deployment, it removes the unsuccessful container because no previous release exists.

Do these controlled exercises in the lab before trusting the pipeline:

| Exercise | How | Expected result |
|---|---|---|
| Test gate | Change a test to expect an incorrect response | Test stage fails; no new staging or production release |
| Coverage gate | Add an untested nontrivial class | Coverage fails when it falls below 80% |
| Secret gate | Generate a throwaway test private key in an isolated disposable test repo; never use a real credential | Scanner blocks if its detector recognizes it; verify detector coverage explicitly |
| SAST gate | Add a rule violation known to your selected Sonar profile | Quality gate blocks; profile must contain the tested rule |
| Image policy | Exercise the JSON gate with a saved synthetic HIGH finding | Gate returns nonzero; no need to deploy a vulnerable image |
| ZAP gate | Remove a security header in a lab branch and verify the enabled rule's resulting severity | Medium/high findings block; lower findings remain visible |
| Scanner outage | Temporarily provide an invalid Sonar token to a disposable test job | Execution fails, with no promotion |
| Rollback | After one healthy release, temporarily occupy a production-only port before a new lab deployment, or use a reviewed fault-injection change limited to production health | Deployment fails; previous release is restored and checked |

For rollback, choose a fault that does not also make the **old** release unable to run. A blocked port affects both releases and therefore tests the rollback-failure path, not successful recovery. To test successful recovery, use an explicit lab-only new-image health failure triggered by a production environment setting, verify staging normally, then promote. Remove the fault after the exercise. Do not turn off the health gate to pass it.

An operator can redeploy a known-good digest manually if Jenkins is unavailable:

```bash
export DEPLOY_IMAGE='127.0.0.1:5000/devsecops-demo@sha256:REPLACE_WITH_PREVIOUS_DIGEST'
export APP_CONTAINER=devsecops-production APP_PORT=8083 HEALTH_PORT=18083
docker compose -p devsecops-production -f deploy/compose.yaml up -d --pull always
curl -fsS http://127.0.0.1:18083/actuator/health/readiness
```

The digest placeholder must be replaced from retained release evidence. Preserve rollback images in registry retention policies. Database migrations are not covered by this stateless demo: in a real application use backward-compatible expand/contract migrations and a separate data-recovery procedure.

## 20. Configure Grafana with real metrics

Find your local Grafana password in the protected `.env` using a trusted editor, and sign in as `admin`. The Prometheus datasource is provisioned automatically.

1. Open Prometheus → **Status → Targets**. The pipeline target must be UP.
2. After a production deployment, the application target must also be UP.
3. In Grafana → **Explore**, select Prometheus and query `devsecops_builds_total`.
4. Create a dashboard named **DevSecOps Delivery and Security**.
5. Add the panels below, set useful units, and save it.

| Panel | PromQL | Visualization |
|---|---|---|
| Last build passed | `devsecops_last_build_success` | Stat: 1 green, 0 red |
| Last build duration | `devsecops_last_build_duration_seconds` | Stat, seconds |
| Builds completed | `devsecops_builds_total` | Stat |
| Build success percentage, 7 days | `100 * increase(devsecops_build_successes_total[7d]) / clamp_min(increase(devsecops_builds_total[7d]), 1)` | Time series/Stat |
| Successful promotions, 24h | `increase(devsecops_deployments_total[24h])` | Stat |
| Latest HIGH image findings | `devsecops_image_high_findings` | Stat |
| Latest CRITICAL image findings | `devsecops_image_critical_findings` | Stat |
| Age of latest completed image scan | `time() - devsecops_last_image_scan_timestamp_seconds` | Stat, seconds |
| Application availability | `up{job="application"}` | Time series |
| HTTP requests/sec | `sum(rate(http_server_requests_seconds_count{job="application"}[5m]))` | Time series |
| HTTP 5xx ratio | `sum(rate(http_server_requests_seconds_count{job="application",status=~"5.."}[5m])) / clamp_min(sum(rate(http_server_requests_seconds_count{job="application"}[5m])), 0.001)` | Time series, percent 0–1 |
| p95 HTTP latency | `histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{job="application"}[5m])))` | Time series, seconds |

Make requests first so HTTP metrics exist. The starter enables an HTTP request histogram. Check actual metric names in Explore against your selected Micrometer version before using a panel. Spring exposes management endpoints on **8081**, separate from public application port 8080. Only health and Prometheus endpoints are enabled. See [Spring Boot actuator endpoints](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html).

The custom exporter reads `/opt/devsecops/metrics/state.json`, which the Jenkins post action updates atomically. No exporter token is needed on this isolated Docker network. It exposes build counters and latest image-scan gauges, not invented Sonar metrics. It is intentionally a single-job example: do not share the same state path among concurrent jobs without adding synchronization and job labels.

Interpretation matters:

- Latest image findings refer to the most recently completed image scan, which can be a failed candidate; they are not automatically findings in the deployed production image.
- If an earlier gate fails, image-scan metrics retain the previous scan and its old timestamp.
- Missing metrics on the first run mean no measurement, not zero vulnerabilities.
- Short-lived counters and a seven-day range need enough scrape history; early percentages may be empty or unrepresentative.
- The counters count this job's executions and successful promotions, including rebuilds of an unchanged commit.
- True remediation time, lead time, change failure rate and recovery time require incident/change timestamps and correlation. They are **not implemented** by these simple metrics. Do not label a percentile of a recovery histogram as mean recovery time.

Create Grafana alert rules after the first measured builds:

| Rule | Expression | Suggested pending period |
|---|---|---|
| Latest pipeline failed | `devsecops_last_build_success == 0` | 1 minute |
| Exporter unavailable | `up{job="pipeline"} == 0` | 2 minutes |
| Production app unavailable | `up{job="application"} == 0` | 2 minutes, after first deployment |
| Security scan stale | `time() - devsecops_last_image_scan_timestamp_seconds > 86400` | 10 minutes |

Also configure missing-data handling for the stale-scan rule; a never-created metric must not silently imply freshness. Set a contact point in Grafana to your approved email/webhook service, create a notification policy, and test delivery with a disposable alert. This package does not configure or send external messages. For rapid stage-specific notifications, integrate Jenkins with your approved notification plugin and include build URL, stage and sanitized severity summary, never raw secrets.

## 21. Routine operations, backup and cleanup

**Every change:** review source and pipeline changes, run gates, retain the digest and evidence, promote only after required approvals.

**Nightly:** use a Jenkins scheduled build (`H H * * *`) to rerun checks without automatic promotion. This detects newly published dependency issues in the current code/image build. For the exact already-deployed digest, add a separate scheduled registry scan rather than assuming a rebuild is identical.

**Weekly:** review blocked vulnerabilities, stale scanners, expiring credentials, tool release notes, cache growth and failed notifications. Re-lock version updates in a dedicated maintenance branch and test them before promotion.

**Backup:** preserve Jenkins home including its secret encryption material, PostgreSQL data through a consistent database backup, Grafana configuration/data, registry images required for rollback, release evidence and the reviewed tool lock. Encrypt backups and restrict access. A file copy of a running PostgreSQL data directory is not a reliable logical backup.

Example logical Sonar database backup on Ubuntu:

```bash
umask 077
mkdir -p backups
docker compose --env-file versions.env --env-file .env -f infra/compose.yaml exec -T db \
  pg_dump -U sonar -d sonar -Fc > "backups/sonar-$(date -u +%Y%m%dT%H%M%SZ).dump"
```

Move this backup to a protected backup destination outside the Git checkout. The included `.gitignore` excludes `backups/`. Stop Jenkins during a simple volume backup or use a consistent snapshot procedure. Test restore into a separate environment and record the recovery time; a backup that has never been restored is incomplete operational evidence.

Inspect storage before cleaning:

```bash
docker system df
docker image ls
docker volume ls
df -h
```

Remove specific obsolete images/build caches only after confirming they are not required for rollback. Do not run `docker volume prune` or `docker compose down -v` as routine troubleshooting; these can remove databases and build history.

To stop the tool stack while retaining named data volumes:

```bash
docker compose --env-file versions.env --env-file .env -f infra/compose.yaml stop
sudo systemctl stop devsecops-agent
```

The staging/production projects are separate and remain running until stopped separately. Cloud VMs and storage may still be billed after stopping containers; manage their lifecycle independently.

## 22. Production hardening roadmap

Before handling customer traffic, close these gaps:

| Area | Required production work |
|---|---|
| CI isolation | Separate controller, build and release trust boundaries; disposable agents; no unrestricted Docker socket for untrusted code |
| Identity | SSO/MFA, role-based authorization, controlled approval groups, short-lived cloud credentials |
| Supply chain | Approved tool versions, artifact provenance, SBOM retention, signing and deployment-time signature verification |
| Registry | Authenticated TLS registry, immutable tags, limited push/pull roles, lifecycle policies, encryption and audit logging |
| Application | Real authentication/authorization where needed, input validation, rate limits, data protection and business security tests |
| DAST | Active/API and authenticated role coverage using controlled staging data |
| Runtime | Separate staging/production accounts or strong boundaries, network policies, ingress TLS, resource policy and runtime detection |
| Availability | Multi-node/multi-zone design, disruption policy, tested rollout strategy and capacity testing |
| Observability | Central logs/traces, alert delivery, incident correlation and SLOs |
| Secrets | Vault or AWS Secrets Manager integration; avoid introducing Vault dev mode as production storage |
| Release controls | Separate signed promotion workflow; protect shared libraries and IaC plans; durable audit trail |
| Recovery | Tested backups, rollback images, backward-compatible migrations and disaster recovery |

The starter deliberately does not deploy Vault merely to display another UI. It uses scoped Jenkins credentials for CI. If you add Vault or External Secrets on EKS, grant workload-specific access and prevent long-lived secrets from entering Git, image layers, build arguments or logs.

To add image signing, use a supported signing tool and a documented key/KMS or workload-identity flow, sign the **digest**, and enforce verification in the release job or admission policy. Signing without enforcement is evidence, not a release barrier. Docker Content Trust should not be assumed to satisfy a modern supply-chain requirement without checking its registry/tool support and your policy.

For infrastructure code, run formatting/validation and a separate misconfiguration scan against `infra/` and `deploy/`, classify lab exceptions, and make that gate mandatory for production manifests. Do not simply enable a scanner on the lab controller stack and globally ignore its privileged-agent findings.

## 23. AWS ECR and EKS extension

This section is an **optional migration procedure**, not a provisioned EKS environment or a complete Terraform project. Finish the Compose pipeline first. The included Kubernetes manifest is an application deployment starter. You still need an existing supported cluster, networking, access configuration and image pull permissions.

### 23.1 Create a private ECR repository

Use an administrator/provisioning identity for one-time repository creation, then a narrower CI role for routine builds:

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
export ECR_REPOSITORY="$ECR_REGISTRY/devsecops-demo"

aws ecr create-repository \
  --region "$AWS_REGION" \
  --repository-name devsecops-demo \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true
```

If the repository exists, inspect it rather than treating an `AlreadyExists` result as a fresh creation. Choose and configure encryption, enhanced scanning and lifecycle policy according to your requirements. The Trivy pipeline gate remains separate from ECR background scan results.

For routine push, grant `ecr:GetAuthorizationToken` on `*` and restrict upload actions (`BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`) to this repository. Add read/describe actions only where needed. Use an EC2 instance role or another short-lived workload identity, not static access keys embedded in Jenkinsfiles.

### 23.2 Push the scanned candidate to ECR

In the release agent, authenticate without exposing the password:

```bash
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

Replace the registry-specific `IMAGE` assignment and digest validation in `scripts/ci.sh` when integrating ECR. An image tag should combine commit and build identity; do not overwrite an immutable tag on a retry. For a manual migration of an already-scanned local candidate:

```bash
export LOCAL_IMAGE='127.0.0.1:5000/devsecops-demo:REPLACE_WITH_BUILD_NUMBER'
export RELEASE_TAG='REPLACE_WITH_COMMIT_AND_BUILD'
docker tag "$LOCAL_IMAGE" "$ECR_REPOSITORY:$RELEASE_TAG"
docker push "$ECR_REPOSITORY:$RELEASE_TAG"
export IMAGE_DIGEST=$(aws ecr describe-images \
  --region "$AWS_REGION" --repository-name devsecops-demo \
  --image-ids imageTag="$RELEASE_TAG" --query 'imageDetails[0].imageDigest' --output text)
export RELEASE_IMAGE="$ECR_REPOSITORY@$IMAGE_DIGEST"
```

Retain the ECR digest as release evidence and use it for staging and production. See [AWS ECR push instructions](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html).

### 23.3 Configure cluster access and connectivity

```bash
aws eks update-kubeconfig --region us-east-1 --name YOUR_CLUSTER
kubectl config current-context
kubectl get nodes
```

Use the actual cluster name. For a private endpoint, the agent must have network/DNS access to the VPC through an approved path. A kubeconfig does not create connectivity or grant permissions.

Give the deployment IAM role an EKS access entry and namespace-scoped Kubernetes authorization. Separate one-time namespace/RBAC provisioning from routine deployment permissions. Do not grant cluster administrator to a general build role. See [EKS access entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html).

Workers need permission and connectivity to pull ECR images. For an isolated VPC, plan the required registry/API endpoints and S3 image-layer access; scanners and Maven also need their own approved outbound feeds or mirrors. ECR endpoints alone do not make the entire build process work without internet access.

### 23.4 Render and deploy the application manifest

After setting `RELEASE_IMAGE` above:

```bash
python3 - <<'PY'
import os
from pathlib import Path
image=os.environ['RELEASE_IMAGE']
if '@sha256:' not in image:
    raise SystemExit('An immutable image reference is required')
Path('/tmp/devsecops-release.yaml').write_text(
    Path('deploy/kubernetes.yaml').read_text().replace('IMAGE_DIGEST',image))
PY
kubectl apply -f /tmp/devsecops-release.yaml
kubectl -n devsecops rollout status deployment/devsecops-demo --timeout=300s
kubectl -n devsecops get pods,svc
kubectl -n devsecops port-forward svc/devsecops-demo 8090:80
```

Open port 8090 on the machine running the port-forward; if that is a remote host, add an SSH tunnel. In a second terminal:

```bash
curl -fsS http://127.0.0.1:8090/api/hello
```

The manifest includes a restricted namespace, non-root execution, startup/readiness/liveness probes, requests/limits, two replicas, a rolling update and a disruption budget. A cluster admin should provision the namespace before handing deploy permissions to CI. It does **not** include public ingress, TLS certificates, cross-zone spreading, default-deny policies, autoscaling, secrets, admission signature enforcement or a ServiceMonitor.

For EKS production, create separate staging and production namespaces/accounts, deploy and scan staging first, then promote the digest. Run ZAP as a controlled in-cluster job or from an agent that can reach staging. Move this release logic into a reviewed pipeline; the supplied Jenkinsfile continues to deploy Compose until you explicitly replace its deployment stages.

### 23.5 Rollback and GitOps ownership

For a direct Kubernetes deployment, a basic rollback is:

```bash
kubectl -n devsecops rollout undo deployment/devsecops-demo
kubectl -n devsecops rollout status deployment/devsecops-demo --timeout=300s
```

Record exact old and new digests in release evidence. If Argo CD manages the deployment, revert the desired image digest in its Git repository and let Argo synchronize. A manual `kubectl rollout undo` can be overwritten by GitOps reconciliation. Pick a single owner for runtime desired state; do not have Jenkins and Argo continuously overwrite each other.

Terraform should own infrastructure resources such as network, EKS, ECR, IAM, KMS and observability foundations. A release pipeline or GitOps should own the application's release digest. Keep their state/permissions separate. A complete Terraform platform would require explicit account, VPC, subnet, endpoint, access, cost and availability choices; none are assumed or provisioned here.

## 24. Troubleshooting reference

| Symptom | Likely cause | First useful action |
|---|---|---|
| Jenkins cannot schedule a build | Agent offline or wrong label | Check node label and `journalctl -u devsecops-agent --since '10 minutes ago'` |
| Agent gets Docker permission denied | Group membership not effective in running service | Check `id jenkins-agent`, restart the agent after group change |
| Sonar restarts repeatedly | Host limits, RAM pressure or database issue | Check Sonar/db logs, `sysctl`, `free -h`; do not remove volumes |
| Sonar unauthorized | Missing/expired token or wrong project permission | Validate credential ID, token scope and server URL |
| Quality gate timeout | Analysis queue/compute task slow or failed | Review project background task and server resources |
| Maven complains about BOOT_VERSION | Lock step did not complete | Resolve tools and verify the two POM template substitutions |
| Dependency-Check fails with 403/429 | Key activation, quota or feed throttling | Validate the key and cache; avoid repeated fresh database rebuilds |
| Trivy database download fails | Registry reachability, rate limits or proxy | Check documented feed access and cache ownership |
| Trivy reports HIGH/CRITICAL | Actual dependency/base-image finding | Read the CVE and fix/rebuild; do not hide the exit status |
| ZAP cannot reach app | Wrong network/DNS name or app not ready | Inspect `devsecops-runtime` and staging readiness |
| ZAP report permission denied | Mounted report path not writable | Confirm agent UID mapping and host directory permissions |
| App starts then exits | Memory pressure, missing `/tmp` or bad artifact | Read `docker logs devsecops-staging` and container exit state |
| Registry push fails | Registry not running or wrong address | Test `http://127.0.0.1:5000/v2/`; production needs proper TLS/auth |
| Grafana is empty | No completed build, no traffic or scrape failure | Check Prometheus targets, exporter state and metric names |
| Final rollout fails | Port conflict or unhealthy image | Inspect failed container logs and verify rollback outcome |
| EKS access denied | IAM authentication lacks Kubernetes authorization | Check access entry and scoped RoleBinding |
| EKS image pull fails | Repository permission, network or architecture issue | Inspect pod events, ECR access and node architecture |

Avoid `-DskipTests`, `maven.test.failure.ignore=true`, `--exit-code 0`, blanket suppression, `chmod 777` on the Docker socket, and volume deletion as fixes for failed security stages.

## 25. Completion checklist

You have achieved the intended **lab** result only when all of these are true:

- [ ] A source change triggers the trusted-main Jenkins job.
- [ ] The controller has no executors and the labeled agent performs the build.
- [ ] Secret, test, coverage, dependency, Sonar and image gates run and fail closed.
- [ ] The immutable image digest and source commit are retained together.
- [ ] Staging readiness/API checks pass.
- [ ] A valid ZAP baseline report is evaluated before approval.
- [ ] Authorized approval promotes the same digest to the production lab.
- [ ] The application responds on port 8083 through the SSH tunnel.
- [ ] Controlled gate-failure and rollback exercises behave as documented.
- [ ] Grafana shows measured build/security/application metrics.
- [ ] Alert routing is configured and its delivery test succeeds.
- [ ] Backup/restore and image retention are documented and exercised.
- [ ] Production limitations in section 22 are understood and tracked separately.

This gives you a working implementation target and an evidence-based demonstration: show a successful release, introduce a controlled failure, prove promotion stops, fix the issue, and demonstrate recovery with the recorded digest.
