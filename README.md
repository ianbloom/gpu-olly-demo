# GKE GPU AI Observability Demo

A self-contained demo that deploys a GPU-accelerated LLM inference service on GKE, drives load with Locust, and observes everything in Grafana via OpenLIT auto-instrumentation and DCGM GPU metrics.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  GKE Cluster                                                                 │
│                                                                               │
│  ┌────────────────────────┐    ┌─────────────────────────────────────────┐  │
│  │  ai-demo namespace      │    │  monitoring namespace                    │  │
│  │                         │    │                                           │  │
│  │  ┌──────────────────┐  │OTLP│  ┌───────────────────────────────────┐  │  │
│  │  │  gpu-inference   │──┼────┼─▶│  Alloy receiver                   │  │  │
│  │  │  FastAPI+PyTorch │  │:4317  │  (k8s-mon-alloy-receiver svc)     │  │  │
│  │  │  NVIDIA GPU      │  │    │  └──────────────┬────────────────────┘  │  │
│  │  └────────▲─────────┘  │    │                 │                         │  │
│  │           │ HTTP        │    │  ┌──────────────▼────────────────────┐  │  │
│  │  ┌────────┴─────────┐  │    │  │  Alloy metrics + events + logs     │  │  │
│  │  │  load-generator  │  │    │  │  (grafana/k8s-monitoring chart)    │  │  │
│  │  │  (Locust)        │  │    │  └──────────────┬────────────────────┘  │  │
│  │  └──────────────────┘  │    └─────────────────┼───────────────────────┘  │
│  │                         │                      │                            │
│  │  OpenLIT Operator       │          ┌───────────┴───────────┐               │
│  │  injects SDK via        │          │ OTLP gRPC             │ Prom          │
│  │  admission webhook      │          ▼ (traces + metrics)    ▼ remote_write  │
│  └────────────────────────┘                                                   │
└─────────────────────────────┬───────────────────────────────────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │  Grafana Cloud               │
                    │  ├─ Mimir  (metrics)         │
                    │  ├─ Tempo  (traces)           │
                    │  ├─ Loki   (logs, optional)   │
                    │  └─ Grafana (dashboards)      │
                    └─────────────────────────────┘
```

**Telemetry flow**: app → OTLP gRPC → Alloy receiver → Grafana Cloud (OTLP gateway → Tempo/Mimir; cluster metrics → Prometheus remote_write → Mimir)

## Prerequisites

| Tool | Version |
|------|---------|
| `gcloud` CLI | ≥ 450 |
| `kubectl` | ≥ 1.29 |
| `helm` | ≥ 3.14 |
| `docker` | ≥ 24 |
| `envsubst` | any (part of `gettext`: `brew install gettext`) |
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
export GCP_PROJECT=solutions-engineering-248511
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

### 4. Set Grafana Cloud environment variables

Find these values in your Grafana Cloud stack under **Home → My Account → Stack details**.

```bash
# Required
export GRAFANA_CLOUD_PROM_URL="https://prometheus-prod-XX-prod-XX.grafana.net/api/prom/push"
export GRAFANA_CLOUD_PROM_USERNAME="123456"          # Metrics instance ID
export GRAFANA_CLOUD_OTLP_URL="https://otlp-gateway-prod-XX.grafana.net/otlp"
export GRAFANA_CLOUD_OTLP_USERNAME="123456"          # OTLP instance ID (usually same as above)
export GRAFANA_CLOUD_API_KEY="glc_eyJ..."            # API token: MetricsPublisher + TracesPublisher scopes

# Optional — enables pod log forwarding to Loki
export GRAFANA_CLOUD_LOKI_URL="https://logs-prod-XX.grafana.net/loki/api/v1/push"
export GRAFANA_CLOUD_LOKI_USERNAME="654321"

# Optional — printed in setup output for convenience
export GRAFANA_CLOUD_STACK_URL="https://myorg.grafana.net"
```

> **Tip**: put these in a `.env` file (git-ignored) and `source .env` before running setup.

### 5. Run the full setup

```bash
export GCP_PROJECT=my-project
export GCP_REGION=us-central1
export GKE_CLUSTER=gpu-demo-cluster
# Artifact Registry path (no trailing slash)
export ARTIFACT_REGISTRY=us-central1-docker.pkg.dev/my-project/ai-demo
# Optional: override the k8s-monitoring Helm release name (default: k8s-mon)
# export K8S_MON_RELEASE=k8s-mon

chmod +x setup.sh
./setup.sh
```

The script:
1. Validates all required `GRAFANA_CLOUD_*` env vars are set
2. Builds and pushes both Docker images
3. Fetches GKE cluster credentials
4. Runs `envsubst` on `k8s-monitoring-values.yaml` to a tempfile, resolving all `${VAR}` credential placeholders (file is never committed with real credentials)
5. Installs `grafana/k8s-monitoring` — deploys Alloy receiver, metrics, log, and events collectors; Alloy ships telemetry directly to Grafana Cloud over OTLP and Prometheus remote_write
6. **Discovers the Alloy receiver Service name** via label selector (falls back to the `<release>-alloy-receiver` convention) and constructs the in-cluster OTLP gRPC endpoint
7. Installs the **OpenLIT Operator** via Helm
8. Applies all manifests with `ALLOY_OTLP_ENDPOINT` substituted into working copies — the operator's webhook injects the OpenLIT SDK into inference pods automatically
9. Deploys the GPU inference service and Locust load generator

### 6. Access services

```bash
# Grafana Cloud — open your stack URL, import the dashboard:
#   Dashboards → New → Import → upload monitoring/dashboards/ai-observability.json
#   Select your Prometheus (Mimir) data source and click Import.
open "${GRAFANA_CLOUD_STACK_URL:-https://your-org.grafana.net}"

# Inference API (local test)
kubectl port-forward svc/gpu-inference 8080:80 -n ai-demo
curl -X POST http://localhost:8080/generate \
     -H 'Content-Type: application/json' \
     -d '{"prompt": "Explain transformer attention", "max_tokens": 128}'

# Locust UI (local)
kubectl port-forward svc/load-generator 8089:8089 -n ai-demo
```

### 7. Tear everything down

```bash
# Remove all k8s resources and Helm releases (keeps cluster, node pool, and registry)
./teardown.sh

# Also delete the two container images from Artifact Registry
./teardown.sh --delete-images

# To additionally delete the GKE cluster itself:
gcloud container clusters delete "${GKE_CLUSTER}" --region "${GCP_REGION}" --project "${GCP_PROJECT}"
```

## File Structure

```
gke-gpu-ai-demo/
├── setup.sh                        # One-shot setup script
├── teardown.sh                     # Tears down all resources (--delete-images to also remove registry images)
├── namespace.yaml                  # ai-demo namespace
│
├── app/
│   ├── app.py                      # FastAPI inference service (PyTorch + OTLP)
│   ├── requirements.txt
│   ├── Dockerfile                  # FROM pytorch/pytorch CUDA image
│   ├── deployment.yaml             # Requests nvidia.com/gpu: 1
│   └── service.yaml
│
├── load-generator/
│   ├── locustfile.py               # Short / medium / long prompt mix
│   ├── requirements.txt
│   ├── Dockerfile
│   └── deployment.yaml             # Configurable via env vars
│
├── openlit/
│   └── instrumentation.yaml       # OpenLIT Instrumentation CR
│
├── monitoring/
│   ├── k8s-monitoring-values.yaml       # grafana/k8s-monitoring Helm values (Alloy → Grafana Cloud)
│   ├── prometheus-values.yaml.retired   # No longer used (no in-cluster Prometheus/Grafana)
│   ├── otel-collector.yaml.retired      # No longer used (Alloy receiver replaces it)
│   └── dashboards/
│       ├── ai-observability.json   # Grafana dashboard (importable)
│       └── configmap.yaml          # ConfigMap wrapper for Grafana sidecar
│
└── gke/
    └── node-pool.sh                # GPU node pool creation script
```

## Grafana Dashboard Panels

| Panel | Metric source |
|-------|---------------|
| Request Rate | `otel_gen_ai_requests_total` (OTel Collector) |
| P50/P95/P99 Latency | `otel_gen_ai_request_duration_ms` histogram |
| Token Throughput | `otel_gen_ai_tokens_total` |
| GPU Utilization | `DCGM_FI_DEV_GPU_UTIL` (DCGM Exporter) |
| GPU Memory Used/Free | `DCGM_FI_DEV_FB_USED / FB_FREE` |
| GPU Power Draw | `DCGM_FI_DEV_POWER_USAGE` |
| GPU Temperature | `DCGM_FI_DEV_GPU_TEMP` |
| Error Rate | `otel_gen_ai_requests_total{status!="success"}` |

## OpenLIT Operator

The [OpenLIT Operator](https://github.com/openlit/openlit) watches for the annotation:

```yaml
instrumentation.openlit.io/inject-python: "true"
```

on pods in namespaces labelled `openlit-instrumentation: enabled`. It mutates matching pods to inject an init container that installs and configures the OpenLIT Python SDK, which:

- Emits GenAI semantic-convention spans (model, tokens, latency)
- Collects per-pod GPU stats via NVML
- Forwards everything to the OTel Collector over gRPC

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

# Verify Alloy receiver is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy-receiver

# Tail Alloy receiver logs (shows received + forwarded OTLP data)
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy-receiver -f

# Confirm the OTLP endpoint injected into inference pods
kubectl get deploy gpu-inference -n ai-demo \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .

# Send a test OTLP ping (requires grpcurl)
kubectl port-forward svc/k8s-mon-alloy-receiver 4317:4317 -n monitoring &
grpcurl -plaintext localhost:4317 list
kill %1

# Verify data reached Grafana Cloud — query in Explore:
#   Prometheus: otel_gen_ai_requests_total
#   Tempo: service.name = "gpu-inference-demo"

# Check OpenLIT operator webhook
kubectl get mutatingwebhookconfigurations | grep openlit

# Check instrumentation CR status
kubectl describe instrumentation gpu-ai-instrumentation -n ai-demo

# Check inference pod logs
kubectl logs -l app=gpu-inference -n ai-demo -f
```
