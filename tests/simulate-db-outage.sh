#!/usr/bin/env bash
# ===========================================================================
# Failure Simulation #2: Database Connectivity Loss
# ---------------------------------------------------------------------------
# Simulates PDF scenario: "network policy change or DB restart causing errors"
#
# Method: scale the Postgres deployment to 0 replicas, making the database
# unreachable. The app then returns HTTP 503 on DB-dependent endpoints.
#
# Expected: NotesApiHighErrorRate alert fires as 5xx errors climb.
# Recovery: run with --recover to scale Postgres back to 1.
# ===========================================================================

set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
NAMESPACE="default"
PG_DEPLOYMENT="notes-api-postgres"
APP_URL="http://13.126.63.217"

recover() {
  echo "[RECOVERY] Scaling Postgres back to 1 replica..."
  sudo KUBECONFIG=$KUBECONFIG kubectl scale deployment $PG_DEPLOYMENT -n $NAMESPACE --replicas=1
  echo "[RECOVERY] Waiting for Postgres to be ready..."
  sudo KUBECONFIG=$KUBECONFIG kubectl rollout status deployment/$PG_DEPLOYMENT -n $NAMESPACE --timeout=120s
  echo "[RECOVERY] Done. Database should be reachable again."
  exit 0
}

if [[ "$1" == "--recover" ]]; then
  recover
fi

echo "=========================================="
echo " FAILURE SIMULATION: Database Connectivity Loss"
echo " Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="

echo "[STEP 1] Baseline — app can reach DB (should return notes):"
curl -s $APP_URL/api/notes | head -c 200
echo ""

echo ""
echo "[STEP 2] Killing the database (scaling Postgres to 0)..."
sudo KUBECONFIG=$KUBECONFIG kubectl scale deployment $PG_DEPLOYMENT -n $NAMESPACE --replicas=0

echo ""
echo "[STEP 3] Waiting for Postgres pod to terminate..."
sleep 8
sudo KUBECONFIG=$KUBECONFIG kubectl get pods -n $NAMESPACE -l app=notes-api-postgres

echo ""
echo "[STEP 4] Generating traffic to trigger 5xx errors..."
echo "         (Each request now fails with 503 database unavailable)"
for i in $(seq 1 15); do
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" $APP_URL/api/notes)
  echo "  Request $i -> HTTP $RESPONSE"
  sleep 2
done

echo ""
echo "[STEP 5] Sample failing response:"
curl -s $APP_URL/api/notes
echo ""
echo ""
echo "[INFO] Detection: watch Prometheus Alerts for 'NotesApiHighErrorRate'."
echo "[INFO] Check Loki for 'database unavailable' error logs."
echo "[INFO] When done capturing evidence, recover with:"
echo "       ./tests/simulate-db-outage.sh --recover"