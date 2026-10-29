#!/usr/bin/env bash
# hpa-load-test.sh — drive the LiteLLM HPA up and back down, and watch it.
#
# Why: litellm-hpa (K8sAppResources) is CPU-only with min 3 / max 30 and a slow
# scale-in; whether it actually scales, how fast, and whether pods stay Ready
# (no restarts, no OOM) under load is only visible on a live cluster.
#
# Load: a k6 Job inside the cluster against Service litellm:4000 (not through
# GA / CloudFront, so the edges are not what is measured), on GET /v1/models —
# a real request through LiteLLM's auth and routing that costs CPU but calls
# no model, so the test is free. Prints HPA replicas / CPU every 30s while the
# load runs (DURATION) and then until the HPA is back at minReplicas or
# WATCH_AFTER seconds have passed. The Job is deleted at the end.
#
# Needs kubectl access to the stack's cluster (aws eks update-kubeconfig ...).
# Usage: ./scripts/hpa-load-test.sh [VUS=300] [DURATION=6m] [WATCH_AFTER=1500]
set -euo pipefail

VUS=${1:-300}
DURATION=${2:-6m}
WATCH_AFTER=${3:-1500}
NS=litellm

cleanup() { kubectl -n "$NS" delete job/litellm-load configmap/litellm-load --ignore-not-found >/dev/null; }
trap cleanup EXIT
cleanup

kubectl -n "$NS" create configmap litellm-load --from-literal=load.js="
import http from 'k6/http';
export const options = { vus: ${VUS}, duration: '${DURATION}', discardResponseBodies: true };
export default function () { http.get('http://litellm.${NS}.svc.cluster.local:4000/v1/models'); }
" >/dev/null

kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: litellm-load
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
        - name: k6
          image: grafana/k6:0.57.0
          args: ["run", "--quiet", "/load/load.js"]
          resources:
            requests: {cpu: "2", memory: 1Gi}
            limits: {cpu: "4", memory: 2Gi}
          volumeMounts:
            - {name: load, mountPath: /load}
      volumes:
        - name: load
          configMap: {name: litellm-load}
EOF

status() {
  local hpa pods
  hpa=$(kubectl -n "$NS" get hpa litellm-hpa -o jsonpath='{.status.currentReplicas}/{.status.desiredReplicas} cpu={.status.currentMetrics[0].resource.current.averageUtilization}%')
  pods=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=litellm --no-headers \
    | awk '{n++; if ($2 ~ /^1\/1/) r++; s+=$4} END {printf "pods=%d ready=%d restarts=%d", n, r, s}')
  printf '%s  replicas(current/desired)=%s  %s\n' "$(date +%T)" "$hpa" "$pods"
}

echo "load: ${VUS} VUs for ${DURATION} on GET /v1/models"
min=$(kubectl -n "$NS" get hpa litellm-hpa -o jsonpath='{.spec.minReplicas}')
peak=0
while kubectl -n "$NS" get job litellm-load -o jsonpath='{.status.active}' 2>/dev/null | grep -q 1; do
  status; cur=$(kubectl -n "$NS" get hpa litellm-hpa -o jsonpath='{.status.currentReplicas}')
  ((cur > peak)) && peak=$cur
  sleep 30
done
kubectl -n "$NS" logs job/litellm-load --tail=30 | grep -E 'http_reqs|http_req_failed|http_req_duration' || true
echo "load done; peak replicas ${peak}; watching scale-in (up to ${WATCH_AFTER}s)"
end=$((SECONDS + WATCH_AFTER))
while ((SECONDS < end)); do
  status
  [[ $(kubectl -n "$NS" get hpa litellm-hpa -o jsonpath='{.status.currentReplicas}') == "$min" ]] && break
  sleep 60
done
echo "OOMKilled containers: $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=litellm -o jsonpath='{range .items[*]}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' | grep -c OOMKilled || true)"
