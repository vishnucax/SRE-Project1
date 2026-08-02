#!/usr/bin/env bash
# ===========================================================================
# Failure Simulation #3: High CPU Exhaustion
# ---------------------------------------------------------------------------
# Simulates PDF scenario: "create a stress-job to push a service into high CPU"
#
# Method: repeatedly call the app's /api/stress endpoint, which runs a CPU
# busy-loop. Sustained load pushes pod CPU up, triggering the High CPU alert.
#
# Expected: NotesApiHighCPU alert fires within ~2-3 minutes.
# Recovery: automatic — CPU drops once the stress calls stop.
# ===========================================================================

set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
NAMESPACE="default"
APP_URL="http://13.126.63.217"

echo "=========================================="
echo " FAILURE SIMULATION: High CPU Exhaustion"
echo " Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="

echo "[STEP 1] Baseline — current pod CPU (via kubectl top):"
sudo KUBECONFIG=$KUBECONFIG kubectl top pods -n $NAMESPACE -l app=notes-api || echo "(metrics-server warming up)"

echo ""
echo "[STEP 2] Generating sustained CPU load via /api/stress..."
echo "         Sending 12 rounds of stress (each burns CPU for ~20s)."
echo "         Running them in parallel to hit both replicas."
echo ""

# Fire stress requests in the background, repeatedly, for ~3 minutes.
# Each request makes a pod burn CPU for 20s. Parallel calls hit both replicas.
END=$((SECONDS + 180))   # run for 180 seconds
ROUND=1
while [ $SECONDS -lt $END ]; do
  echo "  Round $ROUND: firing parallel stress requests ($(date -u '+%H:%M:%S'))"
  # 4 parallel requests to spread across both pods
  for j in 1 2 3 4; do
    curl -s -X POST "$APP_URL/api/stress?duration=20" > /dev/null &
  done
  ROUND=$((ROUND + 1))
  sleep 20   # wait for this batch to finish before the next
done
wait

echo ""
echo "[STEP 3] Load generation complete."
echo "[INFO] Detection: watch Prometheus Alerts for 'NotesApiHighCPU'."
echo "[INFO] Watch the CPU rise in Grafana (Node Exporter / app panels)."
echo "[INFO] Recovery is automatic — CPU returns to normal once stress stops."
echo ""
echo "[STEP 4] Post-load pod CPU:"
sleep 5
sudo KUBECONFIG=$KUBECONFIG kubectl top pods -n $NAMESPACE -l app=notes-api || echo "(metrics-server)"

echo ""
echo " End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"