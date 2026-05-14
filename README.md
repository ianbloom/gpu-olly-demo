# GKE GPU AI Observability Demo

A self-contained demo that deploys a GPU-accelerated LLM inference service on GKE, drives load with Locust, and observes everything in Grafana Cloud via OpenLIT SDK instrumentation and DCGM GPU metrics.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  GKE Cluster                                                                 │
│                                                                               │
│  ┌────────────────────────┐    ┌─────────────────────────────────────────┐  │
│  │  ai-demo namespace      │    │  default namespace                       │  │
│  │                         │    │                                           │  │
│  │  ┌──────────────────┐  │    │  ┌───────────────────────────────────┐  │  │
│  │  │  gpu-inference   │  │    │  │  grafana/k8s-monitoring (Alloy)   │  │  │
│  │  │  FastAPI+PyTorch │  │    │  │  cluster metrics, logs, events    │  │  │
│  │  │  OpenLIT SDK     │  │    │  └──────────────┬────────────────────┘  │  │
│  │  └────────▲─────────┘  │    │                 │                         │  │
│  │           │ HTTP        │    │  ┌──────────────▼────────────────────┐  │  │
│  │  ┌────────┴─────────┐  │    │  │  DCGM Exporter (gpu-operator ns)  │  │  │
│  │  │  load-generator  │  │    │  │  GPU hardware metrics via prom    │  │  │
│  │  │  (Locust)        │  │    │  └───────────────────────────────────┘  │  │
│  │  └──────────────────┘  │    └─────────────────────────────────────────┘  │
│  └────────────────────────┘                                                   │
└───────────────┬─────────────────────────────────┬─────────────────────────┘
                │ OTLP HTTP (traces, metrics, logs) │ Prometheus remote_write
                │ direct to Grafana Cloud           │ (cluster + GPU metrics)
                ▼                                   ▼
        ┌───────────────────────────────────────────────────┐
        │  Grafana Cloud                                     │
        │  ├─ Tempo   (traces — OpenLIT spans)               │
        │  ├─ Mimir   (metrics — GenAI + GPU + cluster)      │
        │  └─ Loki    (logs)                                  │
        └───────────────────────────────────────────────────┘
```

**Telemetry flow**:
- **App → Grafana Cloud directly**: OpenLIT SDK emits traces, metrics (including GPU stats), and logs via OTLP HTTP straight to the Grafana Cloud OTLP gateway
- **DCGM → Grafana Cloud via Alloy**: DCGM Exporter serves GPU hardware metrics on `:9400`; Alloy scrapes and remote-writes to Mimir
- **Cluster telemetry via Alloy**: `grafana/k8s-monitoring` handles cluster metrics, pod logs, events, and profiling

## Prerequisites

| Tool | Version |
|------|---------|
| `gcloud` CLI | ≥ 450 |
| `kubectl` | ≥ 1.29 |
| `helm` | ≥ 3.14 |
| `docker` | ≥ 24 |
| GKE cluster with GPU node pool | see below |
| Grafana Cloud account | free tier works |

## Quick Start

### 1. Create a GKE cluster (if you don't have one)

```bash
gcloud container clusters create gpu-demo-cluster \
  --region us-central1 \
  --machine-type n1-standard-4 \
  --num-nodes 1
```

### 2. Add a GPU node pool

```bash
export GCP_PROJECT=my-project
export GKE_CLUSTER=gpu-demo-cluster
export GKE_REGION=us-central1
bash gke/node-pool.sh
```

GKE automatically installs the NVIDIA driver DaemonSet when you pass `--accelerator gpu-driver-version=latest`.

### 3. Create an Artifact Registry repository

```bash
gcloud artifacts repositories create ai-demo \
  --repository-format docker \
  --location us-central1
```

### 4. Set environment variables

Find Grafana Cloud values under **Home → My Account → Stack details**.

```bash
# GCP
export GCP_PROJECT=my-project
export GCP_REGION=us-central1
export GKE_CLUSTER=gpu-demo-cluster
export ARTIFACT_REGISTRY=us-central1-docker.pkg.dev/my-project/ai-demo

# Grafana Cloud — API token (MetricsPublisher + TracesPublisher + LogsPublisher scopes)
export GRAFANA_CLOUD_API_KEY="glc_eyJ..."

# Prometheus (Mimir)
export GRAFANA_CLOUD_PROM_URL="https://prometheus-prod-XX-prod-XX.grafana.net/api/prom/push"
export GRAFANA_CLOUD_PROM_USERNAME="123456"

# Loki
export GRAFANA_CLOUD_LOKI_URL="https://logs-prod-XXX.grafana.net/loki/api/v1/push"
export GRAFANA_CLOUD_LOKI_USERNAME="654321"

# OTLP gateway
export GRAFANA_CLOUD_OTLP_URL="https://otlp-gateway-prod-XX.grafana.net/otlp"
export GRAFANA_CLOUD_OTLP_USERNAME="123456"

# Pyroscope (profiling)
export GRAFANA_CLOUD_PYROSCOPE_URL="https://profiles-prod-XXX.grafana.net:443"
export GRAFANA_CLOUD_PYROSCOPE_USERNAME="123456"

# Fleet management (Alloy remote config)
export GRAFANA_FLEET_URL="https://fleet-management-prod-XXX.grafana.net"
export GRAFANA_FLEET_USERNAME="123456"

# Grafana Sigil SDK — structured LLM generation telemetry
# Token requires sigil:write scope in Grafana Cloud access policy
export SIGIL_ENDPOINT="https://sigil-prod-XXX.grafana.net"
export SIGIL_AUTH_TENANT_ID="123456"   # Grafana Cloud stack/instance ID
export SIGIL_AUTH_TOKEN="glc_eyJ..."   # API token with sigil:write scope
```

> **Tip**: save these to a `.env` file (already git-ignored) and `source .env` before running setup.

### 5. Run setup

```bash
chmod +x setup.sh
./setup.sh
```

The script:
1. Validates all required env vars are set
2. Builds and pushes the inference and load-generator Docker images
3. Fetches GKE cluster credentials
4. Deploys NVIDIA DCGM host engine and exporter DaemonSets (`gpu-operator` namespace)
5. Installs `grafana/k8s-monitoring` — deploys Alloy collectors for cluster metrics, logs, events, profiling, and DCGM scraping
6. Deploys the `ai-demo` namespace, GPU inference service, and Locust load generator

### 6. Access services

```bash
# Import the Grafana dashboard:
#   Dashboards → New → Import → upload monitoring/dashboards/ai-observability.json
#   Select your Prometheus (Mimir) data source and click Import.

# Inference API (local test)
kubectl port-forward svc/gpu-inference 8080:80 -n ai-demo
curl -X POST http://localhost:8080/generate \
     -H 'Content-Type: application/json' \
     -d '{"prompt": "Explain transformer attention", "max_tokens": 128}'

# Locust load generator UI
kubectl port-forward svc/load-generator 8089:8089 -n ai-demo
# Open http://localhost:8089
```

### 7. Tear everything down

```bash
# Remove all k8s resources and Helm releases (keeps cluster, node pool, and registry)
./teardown.sh

# Also delete the two container images from Artifact Registry
./teardown.sh --delete-images

# To additionally delete the GKE cluster:
gcloud container clusters delete "${GKE_CLUSTER}" --region "${GCP_REGION}" --project "${GCP_PROJECT}"
```

## File Structure

```
gke-gpu-ai-demo/
├── setup.sh                        # One-shot setup script
├── teardown.sh                     # Tears down all resources
├── namespace.yaml                  # ai-demo namespace
│
├── app/
│   ├── app.py                      # FastAPI inference service (PyTorch + OpenLIT SDK)
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── deployment.yaml             # Requests nvidia.com/gpu: 1
│   └── service.yaml
│
├── load-generator/
│   ├── locustfile.py               # Short / medium / long prompt mix
│   ├── requirements.txt
│   ├── Dockerfile
│   └── deployment.yaml
│
├── monitoring/
│   ├── dcgm-daemonsets.yaml        # NVIDIA DCGM host engine + exporter DaemonSets
│   ├── k8s-monitoring-values.yaml  # grafana/k8s-monitoring Helm values reference
│   └── dashboards/
│       └── ai-observability.json  # Grafana dashboard (importable)
│
└── gke/
    └── node-pool.sh                # GPU node pool creation script
```

## Grafana Dashboard Panels

| Panel | Metric source |
|-------|---------------|
| Request Rate | `gen_ai_requests_total` (OpenLIT) |
| P50/P95/P99 Latency | `gen_ai_request_duration` histogram (OpenLIT) |
| Token Throughput | `gen_ai_tokens_total` (OpenLIT) |
| GPU Utilization | `DCGM_FI_DEV_GPU_UTIL` (DCGM Exporter) |
| GPU Memory Used/Free | `DCGM_FI_DEV_FB_USED / FB_FREE` (DCGM Exporter) |
| GPU Power Draw | `DCGM_FI_DEV_POWER_USAGE` (DCGM Exporter) |
| GPU Temperature | `DCGM_FI_DEV_GPU_TEMP` (DCGM Exporter) |
| Error Rate | `gen_ai_requests_total{status!="success"}` (OpenLIT) |

## OpenLIT Instrumentation

The inference service initializes the [OpenLIT SDK](https://github.com/openlit/openlit) directly in `app.py`:

```python
openlit.init(
    collect_gpu_stats=True,
    environment="production",
    application_name=SERVICE_NAME,
)
```

OpenLIT reads `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_HEADERS` from the environment and exports traces, metrics, and logs directly to the Grafana Cloud OTLP gateway. GPU stats are collected via `pynvml` and emitted as OTEL metrics alongside the GenAI semantic-convention spans.

## DCGM GPU Metrics

GPU hardware metrics are collected by two DaemonSets in the `gpu-operator` namespace following [Google's official GKE DCGM guidance](https://cloud.google.com/stackdriver/docs/managed-prometheus/exporters/nvidia-dcgm):

- `nvidia-dcgm` — runs `nv-hostengine` on `hostPort 5555`
- `nvidia-dcgm-exporter` — connects to the host engine via `--remote-hostengine-info $(NODE_IP)` and exposes Prometheus metrics on `:9400`

The `grafana/k8s-monitoring` `dcgm-exporter` integration scrapes these metrics and remote-writes them to Grafana Cloud Mimir.

## GPU Node Pool Sizing Guide

| Workload | Recommended GPU | Machine type |
|----------|----------------|-------------|
| Demo / dev | NVIDIA T4 (1×) | n1-standard-8 |
| Mid-scale | NVIDIA L4 (1×) | g2-standard-8 |
| Production | NVIDIA A100 (1–8×) | a2-highgpu-1g |

## Troubleshooting

```bash
# Check GPU is visible on nodes
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'

# Check inference pod logs (OpenLIT init + GPU detection)
kubectl logs -l app=gpu-inference -n ai-demo | grep -iE "openlit|gpu|error"

# Verify OTLP env vars in the running deployment
kubectl get deploy gpu-inference -n ai-demo \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -i otlp

# Check DCGM pods are running
kubectl get pods -n gpu-operator

# Verify DCGM metrics are being served
kubectl port-forward -n gpu-operator \
  $(kubectl get pods -n gpu-operator -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].metadata.name}') \
  9400:9400 &
curl -s http://localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
kill %1

# Check Alloy metrics collector is running
kubectl get pods -n default -l app.kubernetes.io/name=alloy-metrics

# Verify data reached Grafana Cloud — query in Explore:
#   Tempo:      service.name = "gpu-inference-demo"
#   Prometheus: DCGM_FI_DEV_GPU_UTIL
#   Prometheus: gen_ai_requests_total
```
