#!/usr/bin/env bash
# Full setup script for the GKE GPU AI Observability Demo.
# Prerequisites:
#   gcloud, kubectl, helm, docker
#   gcloud auth login && gcloud auth configure-docker
#
# Required environment variables:
#   GCP_PROJECT                   GCP project ID
#   GCP_REGION                    GCP region (e.g. us-central1)
#   GKE_CLUSTER                   GKE cluster name
#   ARTIFACT_REGISTRY             Artifact Registry repo (e.g. us-central1-docker.pkg.dev/PROJECT/repo)
#   GRAFANA_CLOUD_API_KEY         Grafana Cloud API token (used as password for all destinations)
#   GRAFANA_CLOUD_PROM_URL        Prometheus remote write URL
#   GRAFANA_CLOUD_PROM_USERNAME   Prometheus instance ID
#   GRAFANA_CLOUD_LOKI_URL        Loki push URL
#   GRAFANA_CLOUD_LOKI_USERNAME   Loki instance ID
#   GRAFANA_CLOUD_OTLP_URL        OTLP gateway URL
#   GRAFANA_CLOUD_OTLP_USERNAME   OTLP instance ID
#   GRAFANA_CLOUD_PYROSCOPE_URL   Pyroscope URL
#   GRAFANA_CLOUD_PYROSCOPE_USERNAME  Pyroscope instance ID
#   GRAFANA_FLEET_URL             Fleet management URL
#   GRAFANA_FLEET_USERNAME        Fleet management instance ID
set -euo pipefail

# ── Required env vars ──────────────────────────────────────────────────────────
REQUIRED_VARS=(
  GCP_PROJECT
  GCP_REGION
  GKE_CLUSTER
  ARTIFACT_REGISTRY
  GRAFANA_CLOUD_API_KEY
  GRAFANA_CLOUD_PROM_URL
  GRAFANA_CLOUD_PROM_USERNAME
  GRAFANA_CLOUD_LOKI_URL
  GRAFANA_CLOUD_LOKI_USERNAME
  GRAFANA_CLOUD_OTLP_URL
  GRAFANA_CLOUD_OTLP_USERNAME
  GRAFANA_CLOUD_PYROSCOPE_URL
  GRAFANA_CLOUD_PYROSCOPE_USERNAME
  GRAFANA_FLEET_URL
  GRAFANA_FLEET_USERNAME
  SIGIL_ENDPOINT
  SIGIL_AUTH_TENANT_ID
  SIGIL_AUTH_TOKEN
)
missing=()
for var in "${REQUIRED_VARS[@]}"; do
  [[ -z "${!var:-}" ]] && missing+=("${var}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: the following required env vars are not set:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

# ── Configuration ──────────────────────────────────────────────────────────────
PROJECT="${GCP_PROJECT}"
REGION="${GCP_REGION}"
REGISTRY="${ARTIFACT_REGISTRY}"
CLUSTER="${GKE_CLUSTER}"

K8S_MON_RELEASE="grafana-k8s-monitoring"
K8S_MON_NS="default"

DCGM_NS="gpu-operator"

echo "=== GKE GPU AI Observability Demo Setup ==="
echo "Project:         ${PROJECT}"
echo "Region:          ${REGION}"
echo "Registry:        ${REGISTRY}"
echo "Cluster:         ${CLUSTER}"
echo

# ── 1. Build & push images ─────────────────────────────────────────────────────
echo "--- Building inference app image ---"
docker build --platform linux/amd64 -t "${REGISTRY}/gpu-inference:latest" ./app
docker push "${REGISTRY}/gpu-inference:latest"

echo "--- Building load-generator image ---"
docker build --platform linux/amd64 -t "${REGISTRY}/load-generator:latest" ./load-generator
docker push "${REGISTRY}/load-generator:latest"

# Working copies so source YAML files are never mutated; safe to re-run.
cp app/deployment.yaml            app/deployment.yaml.deploy
cp load-generator/deployment.yaml load-generator/deployment.yaml.deploy

GRAFANA_CLOUD_OTLP_AUTH="Authorization=Basic $(printf '%s' "${GRAFANA_CLOUD_OTLP_USERNAME}:${GRAFANA_CLOUD_API_KEY}" | base64)"

sed -i.bak \
  -e "s|REGISTRY|${REGISTRY}|g" \
  -e "s|GRAFANA_CLOUD_OTLP_URL_PLACEHOLDER|${GRAFANA_CLOUD_OTLP_URL}|g" \
  -e "s|GRAFANA_CLOUD_OTLP_AUTH_PLACEHOLDER|${GRAFANA_CLOUD_OTLP_AUTH}|g" \
  -e "s|SIGIL_ENDPOINT_PLACEHOLDER|${SIGIL_ENDPOINT}|g" \
  -e "s|SIGIL_TENANT_ID_PLACEHOLDER|${SIGIL_AUTH_TENANT_ID}|g" \
  -e "s|SIGIL_TOKEN_PLACEHOLDER|${SIGIL_AUTH_TOKEN}|g" \
  app/deployment.yaml.deploy \
  load-generator/deployment.yaml.deploy
rm -f app/deployment.yaml.deploy.bak load-generator/deployment.yaml.deploy.bak

# ── 2. Get cluster credentials ─────────────────────────────────────────────────
echo "--- Fetching GKE credentials ---"
gcloud container clusters get-credentials "${CLUSTER}" \
  --region "${REGION}" --project "${PROJECT}"

# ── 3. Deploy NVIDIA DCGM (host engine + exporter) ────────────────────────────
# GKE requires two DaemonSets: nv-hostengine (port 5555) and dcgm-exporter
# (connects to host engine via NODE_IP). Standalone/embedded mode does not work
# on GKE. See:
# https://cloud.google.com/stackdriver/docs/managed-prometheus/exporters/nvidia-dcgm
echo "--- Deploying NVIDIA DCGM host engine and exporter ---"
kubectl create namespace "${DCGM_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f monitoring/dcgm-daemonsets.yaml
echo "  DCGM pods will schedule on GPU nodes; metrics available once Running."

# ── 4. Install grafana/k8s-monitoring ──────────────────────────────────────────
echo "--- Installing grafana/k8s-monitoring (Alloy) ---"
helm repo add grafana https://grafana.github.io/helm-charts &&
  helm repo update &&
  helm upgrade --install --atomic --timeout 300s grafana-k8s-monitoring grafana/k8s-monitoring \
    --version "^4" --namespace "default" --create-namespace --values - <<EOF
cluster:
  name: ${CLUSTER}
destinations:
  grafana-cloud-metrics:
    type: prometheus
    url: ${GRAFANA_CLOUD_PROM_URL}
    auth:
      type: basic
      username: "${GRAFANA_CLOUD_PROM_USERNAME}"
      password: "${GRAFANA_CLOUD_API_KEY}"
  grafana-cloud-logs:
    type: loki
    url: ${GRAFANA_CLOUD_LOKI_URL}
    auth:
      type: basic
      username: "${GRAFANA_CLOUD_LOKI_USERNAME}"
      password: "${GRAFANA_CLOUD_API_KEY}"
  gc-otlp-endpoint:
    type: otlp
    url: "${GRAFANA_CLOUD_OTLP_URL}"
    protocol: http
    auth:
      type: basic
      username: "${GRAFANA_CLOUD_OTLP_USERNAME}"
      password: "${GRAFANA_CLOUD_API_KEY}"
    metrics:
      enabled: true
    logs:
      enabled: true
    traces:
      enabled: true
  grafana-cloud-profiles:
    type: pyroscope
    url: ${GRAFANA_CLOUD_PYROSCOPE_URL}
    auth:
      type: basic
      username: "${GRAFANA_CLOUD_PYROSCOPE_USERNAME}"
      password: "${GRAFANA_CLOUD_API_KEY}"
clusterMetrics:
  enabled: true
  collector: alloy-metrics
hostMetrics:
  enabled: true
  collector: alloy-metrics
  linuxHosts:
    enabled: true
  windowsHosts:
    enabled: true
  energyMetrics:
    enabled: true
costMetrics:
  enabled: true
  collector: alloy-metrics
clusterEvents:
  enabled: true
  collector: alloy-singleton
podLogsViaLoki:
  enabled: true
  collector: alloy-logs
# In-cluster OTLP receiver — the demo app and OpenLIT SDK ship traces here;
# alloy-receiver forwards them to gc-otlp-endpoint (Grafana Cloud Tempo/Mimir).
applicationObservability:
  enabled: true
  collector: alloy-receiver
  receivers:
    otlp:
      grpc:
        enabled: true
        port: 4317
      http:
        enabled: true
        port: 4318
    zipkin:
      enabled: true
      port: 9411
autoInstrumentation:
  enabled: true
  collector: alloy-metrics
  beyla:
    deliverTracesToApplicationObservability: true
profiling:
  enabled: true
  collector: alloy-profiles
annotationAutodiscovery:
  enabled: true
  collector: alloy-metrics
prometheusOperatorObjects:
  enabled: false
integrations:
  collector: alloy-metrics
  dcgm-exporter:
    instances:
      - name: dcgm-exporter
        labelSelectors:
          app.kubernetes.io/name: dcgm-exporter
        namespaces:
          - ${DCGM_NS}
collectors:
  alloy-metrics:
    presets:
      - clustered
      - statefulset
  alloy-singleton:
    presets:
      - singleton
  alloy-logs:
    presets:
      - filesystem-log-reader
      - daemonset
  alloy-receiver:
    presets:
      - deployment
  alloy-profiles:
    presets:
      - privileged
      - daemonset
collectorCommon:
  alloy:
    remoteConfig:
      enabled: true
      url: ${GRAFANA_FLEET_URL}
      auth:
        type: basic
        username: "${GRAFANA_FLEET_USERNAME}"
        password: "${GRAFANA_CLOUD_API_KEY}"
telemetryServices:
  kube-state-metrics:
    deploy: true
  node-exporter:
    deploy: true
  windows-exporter:
    deploy: true
  opencost:
    deploy: true
    metricsSource: grafana-cloud-metrics
    opencost:
      exporter:
        defaultClusterId: ${CLUSTER}
      prometheus:
        existingSecretName: grafana-cloud-metrics-grafana-k8s-monitoring
        external:
          url: ${GRAFANA_CLOUD_PROM_URL%/push}
  kepler:
    deploy: true
EOF

# ── 5. Compute Grafana Cloud OTLP auth header ──────────────────────────────────
GRAFANA_CLOUD_OTLP_AUTH="Authorization=Basic $(printf '%s' "${GRAFANA_CLOUD_OTLP_USERNAME}:${GRAFANA_CLOUD_API_KEY}" | base64)"
echo "  OTLP endpoint: ${GRAFANA_CLOUD_OTLP_URL}"

# ── 6. Deploy ai-demo namespace and workloads ──────────────────────────────────
echo "--- Deploying ai-demo namespace and workloads ---"
kubectl apply -f namespace.yaml
kubectl apply -f app/deployment.yaml.deploy
kubectl apply -f app/service.yaml
kubectl apply -f load-generator/deployment.yaml.deploy

# ── 7. Cleanup working copies ─────────────────────────────────────────────────
rm -f \
  app/deployment.yaml.deploy \
  load-generator/deployment.yaml.deploy

# ── 8. Print access info ──────────────────────────────────────────────────────
echo
echo "=== Setup complete! ==="
echo
echo "Telemetry pipeline:"
echo "  App (OpenLIT) ──OTLP HTTP──▶ ${GRAFANA_CLOUD_OTLP_URL}"
echo "                               traces → Grafana Cloud Tempo"
echo "                               metrics → Grafana Cloud Mimir"
echo "                               logs   → Grafana Cloud Loki"
echo
echo "  DCGM Exporter (:9400) ──scrape──▶ alloy-metrics ──▶ grafana-cloud-metrics"
echo "  Check: kubectl get pods -n ${DCGM_NS}"
echo
echo "Grafana Cloud dashboard:"
echo "  1. Open https://your-org.grafana.net"
echo "  2. Go to Dashboards → New → Import"
echo "  3. Upload monitoring/dashboards/ai-observability.json"
echo "  4. Select your Prometheus data source and click Import"
echo
echo "Inference API (local test):"
echo "  kubectl port-forward svc/gpu-inference 8080:80 -n ai-demo"
echo "  curl -X POST http://localhost:8080/generate \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"prompt\": \"Explain attention mechanisms\", \"max_tokens\": 128}'"
echo
echo "Locust UI (local):"
echo "  kubectl port-forward svc/load-generator 8089:8089 -n ai-demo"
echo "  Then open http://localhost:8089"
echo
echo "Alloy receiver status:"
echo "  kubectl get pods -n ${K8S_MON_NS} -l app.kubernetes.io/name=alloy-receiver"
echo "  kubectl logs -n ${K8S_MON_NS} -l app.kubernetes.io/name=alloy-receiver -f"
