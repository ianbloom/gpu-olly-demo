#!/usr/bin/env bash
# Tears down everything created by setup.sh.
# Does NOT delete the GKE cluster, GPU node pool, or Artifact Registry repo.
# Pass --delete-images to also delete the two container images from the registry.
set -euo pipefail

DELETE_IMAGES=false
for arg in "$@"; do
  [[ "${arg}" == "--delete-images" ]] && DELETE_IMAGES=true
done

# ── Required env vars ──────────────────────────────────────────────────────────
REQUIRED_VARS=(GCP_PROJECT GCP_REGION GKE_CLUSTER ARTIFACT_REGISTRY)
missing=()
for var in "${REQUIRED_VARS[@]}"; do
  [[ -z "${!var:-}" ]] && missing+=("${var}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: the following required env vars are not set:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

PROJECT="${GCP_PROJECT}"
REGION="${GCP_REGION}"
REGISTRY="${ARTIFACT_REGISTRY}"
CLUSTER="${GKE_CLUSTER}"

K8S_MON_RELEASE="grafana-k8s-monitoring"
K8S_MON_NS="default"

echo "=== GKE GPU AI Observability Demo Teardown ==="
echo "Project:  ${PROJECT}"
echo "Region:   ${REGION}"
echo "Cluster:  ${CLUSTER}"
echo "Registry: ${REGISTRY}"
echo

# ── Cluster credentials ────────────────────────────────────────────────────────
echo "--- Fetching GKE credentials ---"
gcloud container clusters get-credentials "${CLUSTER}" \
  --region "${REGION}" --project "${PROJECT}"

# ── 1. ai-demo namespace (workloads + OpenLIT Instrumentation CR) ──────────────
echo "--- Deleting ai-demo namespace and all workloads ---"
kubectl delete namespace ai-demo --ignore-not-found --wait --timeout=120s

# ── 2. NVIDIA DCGM (host engine + exporter) ───────────────────────────────────
echo "--- Deleting NVIDIA DCGM DaemonSets ---"
kubectl delete -f monitoring/dcgm-daemonsets.yaml --ignore-not-found
kubectl delete namespace gpu-operator --ignore-not-found --wait --timeout=60s

# ── 3. grafana/k8s-monitoring (Alloy + telemetry services) ────────────────────
echo "--- Uninstalling grafana-k8s-monitoring ---"
if helm status "${K8S_MON_RELEASE}" -n "${K8S_MON_NS}" &>/dev/null; then
  helm uninstall "${K8S_MON_RELEASE}" -n "${K8S_MON_NS}" --wait --timeout=180s
else
  echo "  ${K8S_MON_RELEASE} release not found, skipping"
fi

# Clean up CRDs and cluster-scoped resources the chart may have left behind
echo "--- Cleaning up k8s-monitoring cluster-scoped resources ---"
kubectl get crd -o name | grep -E "grafana|alloy|opencost|kepler" \
  | xargs --no-run-if-empty kubectl delete --ignore-not-found

# ClusterRoles / ClusterRoleBindings / Secrets that survive namespace deletion
for kind in clusterrole clusterrolebinding; do
  kubectl get "${kind}" -o name \
    | grep "${K8S_MON_RELEASE}" \
    | xargs --no-run-if-empty kubectl delete --ignore-not-found
done

# ── 5. Leftover deploy working-copy files ──────────────────────────────────────
echo "--- Cleaning up any leftover .deploy working copies ---"
rm -f \
  app/deployment.yaml.deploy \
  app/deployment.yaml.deploy.bak \
  load-generator/deployment.yaml.deploy \
  load-generator/deployment.yaml.deploy.bak

# ── 6. Container images (opt-in) ───────────────────────────────────────────────
if [[ "${DELETE_IMAGES}" == "true" ]]; then
  echo "--- Deleting container images from Artifact Registry ---"
  for image in gpu-inference load-generator; do
    gcloud artifacts docker images delete \
      "${REGISTRY}/${image}:latest" \
      --project="${PROJECT}" \
      --quiet \
      --delete-tags \
      2>/dev/null && echo "  Deleted ${image}:latest" \
      || echo "  ${image}:latest not found, skipping"
  done
else
  echo "--- Skipping image deletion (pass --delete-images to remove) ---"
fi

echo
echo "=== Teardown complete ==="
echo
echo "Still running (not touched by this script):"
echo "  GKE cluster:      ${CLUSTER}"
echo "  GPU node pool:    gpu-pool"
echo "  Artifact Registry: ${REGISTRY}"
echo
echo "To also delete the cluster:"
echo "  gcloud container clusters delete ${CLUSTER} --region ${REGION} --project ${PROJECT}"
