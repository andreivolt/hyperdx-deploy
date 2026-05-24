#!/usr/bin/env bash
# Idempotent: applies the hyperdx ArgoCD Application from volt-bootstrap.
# The Application manifest lives in the cluster-bootstrap repo (single
# source of truth, deployed by the app-of-apps); this script is only
# needed for fresh-cluster bootstrap before app-of-apps takes over.
set -euo pipefail

HOST="${VOLT_SSH_HOST:-volt}"
BOOTSTRAP_REPO_DIR="${BOOTSTRAP_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)}"

ssh "$HOST" 'sudo k3s kubectl apply -f -' <"$BOOTSTRAP_REPO_DIR/argocd/apps/hyperdx.yaml"

echo "Applied. Watch sync with:"
echo "  ssh $HOST 'sudo k3s kubectl -n argocd get app hyperdx -w'"
