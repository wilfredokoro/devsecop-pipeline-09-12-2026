# Validation record

Validated during package preparation on 12 September 2026.

- Bash syntax passed for shell scripts.
- Python syntax passed for Python scripts.
- YAML parsing passed for Compose, Kubernetes and Prometheus/Grafana configuration.
- POM XML parsed; dependency versions resolve during bootstrap.
- ZAP valid clean report accepted.
- ZAP low alert accepted under documented policy.
- ZAP medium alert blocks promotion.
- ZAP high alert blocks promotion.
- ZAP no scanned sites blocks promotion.
- ZAP incomplete schema blocks promotion.
- ZAP malformed JSON blocks promotion.
- Image LOW policy verified.
- Image HIGH policy verified.
- Image CRITICAL policy verified.
- Image missing result schema blocks promotion.
- No completed scan produces no false zero-finding metric.
- Earlier-stage failure retains previous findings and scan timestamp.
- Build/promotion counters and exporter metric types verified.

Not executed here: Docker image pulls/builds, Maven compile/tests, Jenkinsfile validation against a running Jenkins controller, Sonar analysis, live scanners, Compose integration, live rollback, ECR or EKS deployment. Synthetic policy tests do not establish end-to-end readiness. Run the README checkpoints and fault exercises on the target host.
