#!/usr/bin/env bash
# ===========================================================================
# Failure Simulation #1: Pod Crash Loop
# ---------------------------------------------------------------------------
# Simulates PDF scenario: "corrupt startup configuration causing CrashLoopBackOff"
#
# Method: patch the notes-api deployment with a broken startup command so the
# container exits immediately on start, triggering CrashLoopBackOff.
#
# Expected: NotesApiPodCrashLooping alert fires within ~2-3 minutes.
# Recovery: run the --recover flag (or re-deploy via CI/CD) to restore.
# ===========================================================================

set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
NAMESPACE="default"
DEPLOYMENT="notes-api"

recover() {
  echo "[RECOVERY] Removing the broken command override..."
  sudo KUBECONFIG=$KUBECONFIG kubectl patch deployment $DEPLOYMENT -n $NAMESPACE --type='json' \
    -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/command"}]' || true
  echo "[RECOVERY] Waiting for rollout to stabilize..."
  sudo KUBECONFIG=$KUBECONFIG kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=120s
  echo "[RECOVERY] Done. Pods should be healthy again."
  exit 0
}

# If called with --recover, restore and exit
if [[ "$1" == "--recover" ]]; then
  recover
fi

echo "=========================================="
echo " FAILURE SIMULATION: Pod Crash Loop"
echo " Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="

echo "[STEP 1] Current pod status (healthy baseline):"
sudo KUBECONFIG=$KUBECONFIG kubectl get pods -n $NAMESPACE -l app=notes-api

echo ""
echo "[STEP 2] Injecting broken startup command (corrupt config)..."
# Override the container command with a broken one that exits with error
sudo KUBECONFIG=$KUBECONFIG kubectl patch deployment $DEPLOYMENT -n $NAMESPACE --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/command", "value": ["python", "-c", "import sys; print(\"FATAL: corrupt startup configuration\"); sys.exit(1)"]}]'

echo ""
echo "[STEP 3] Watching pods enter CrashLoopBackOff (Ctrl+C to stop watching)..."
echo "         Detection: check Prometheus Alerts for 'NotesApiPodCrashLooping'"
echo "         Expected alert fire: ~2-3 minutes after crash loop begins"
echo ""
sudo KUBECONFIG=$KUBECONFIG kubectl get pods -n $NAMESPACE -l app=notes-api -w