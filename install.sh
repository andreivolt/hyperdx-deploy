#!/usr/bin/env bash
# Register the hyperdx ArgoCD Application on volt. Idempotent.
set -euo pipefail

HOST="${VOLT_SSH_HOST:-volt}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh "$HOST" 'sudo k3s kubectl apply -f -' <"$REPO_DIR/argocd/hyperdx.yaml"

echo "Applied. Watch sync with:"
echo "  ssh $HOST 'sudo k3s kubectl -n argocd get app hyperdx -w'"
