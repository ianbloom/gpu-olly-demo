#!/usr/bin/env bash
# Creates a GKE GPU node pool for the ai-demo workloads.
# Adjust PROJECT, CLUSTER, REGION, and GPU_TYPE as needed.
set -euo pipefail

PROJECT="${GCP_PROJECT:-my-gcp-project}"
CLUSTER="${GKE_CLUSTER:-gpu-demo-cluster}"
REGION="${GKE_REGION:-us-central1}"
GPU_TYPE="${GPU_TYPE:-nvidia-tesla-t4}"
GPU_COUNT="${GPU_COUNT:-1}"
MACHINE_TYPE="${MACHINE_TYPE:-n1-standard-8}"
NODE_COUNT="${NODE_COUNT:-2}"

echo "Creating GPU node pool in project=${PROJECT} cluster=${CLUSTER} region=${REGION}"

gcloud container node-pools create gpu-pool \
  --cluster="${CLUSTER}" \
  --region="${REGION}" \
  --project="${PROJECT}" \
  --machine-type="${MACHINE_TYPE}" \
  --accelerator="type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=latest" \
  --num-nodes="${NODE_COUNT}" \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=4 \
  --node-taints="nvidia.com/gpu=present:NoSchedule" \
  --node-labels="cloud.google.com/gke-accelerator=${GPU_TYPE}" \
  --scopes="https://www.googleapis.com/auth/cloud-platform"

echo "Node pool created. GKE automatically installs the NVIDIA driver DaemonSet."
echo "Verify with: kubectl get pods -n kube-system -l k8s-app=nvidia-gpu-device-plugin"
