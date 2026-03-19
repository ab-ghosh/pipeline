#!/usr/bin/env bash
# ==============================================================================
# Automated reproduction of the PipelineRun Premature Failure Race Condition
# ==============================================================================
#
# Prerequisites:
#   - kubectl configured against a cluster with Tekton Pipelines installed
#   - Permissions to create PipelineRuns and delete pods
#
# Usage:
#   ./reproduce-premature-failure.sh [--cleanup]
#
# What this script does:
#   1. Creates a PipelineRun with two sequential tasks
#   2. Waits for the first task's pod to start running
#   3. Deletes the pod (simulating Kubernetes eviction)
#   4. Watches the PipelineRun status for 3 minutes
#   5. Reports whether the bug was triggered
#
# Expected result WITHOUT the fix:
#   PipelineRun -> Failed (within 5-15 seconds of pod deletion)
#
# Expected result WITH the fix:
#   PipelineRun -> stays Running -> task-a pod recreated -> task-b runs -> Succeeded
#
# ==============================================================================

set -euo pipefail

PIPELINERUN_NAME="repro-premature-failure-$(date +%s)"
NAMESPACE="${NAMESPACE:-default}"
WATCH_TIMEOUT=180  # 3 minutes

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log()  { echo -e "${BOLD}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] FAIL:${NC} $*"; }
pass() { echo -e "${GREEN}[$(date +%H:%M:%S)] PASS:${NC} $*"; }

cleanup() {
    log "Cleaning up..."
    kubectl delete pipelinerun "$PIPELINERUN_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}

if [[ "${1:-}" == "--cleanup" ]]; then
    # Clean up all repro PipelineRuns
    kubectl delete pipelinerun -n "$NAMESPACE" -l app=repro-premature-failure --ignore-not-found 2>/dev/null || true
    log "Cleanup complete."
    exit 0
fi

trap cleanup EXIT

# ─── Step 1: Create the PipelineRun ──────────────────────────────────────────

log "Creating PipelineRun: $PIPELINERUN_NAME in namespace: $NAMESPACE"

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: ${PIPELINERUN_NAME}
  labels:
    app: repro-premature-failure
spec:
  pipelineSpec:
    tasks:
      - name: task-a
        taskSpec:
          steps:
            - name: work
              image: alpine:3.19
              script: |
                echo "task-a: started"
                sleep 120
                echo "task-a: completed"
      - name: task-b
        runAfter: ["task-a"]
        taskSpec:
          steps:
            - name: work
              image: alpine:3.19
              script: |
                echo "task-b: started (pipeline survived eviction!)"
                sleep 5
                echo "task-b: completed"
  taskRunTemplate:
    serviceAccountName: default
EOF

# ─── Step 2: Wait for task-a's pod to be Running ─────────────────────────────

log "Waiting for task-a pod to start running..."

POD=""
for i in $(seq 1 60); do
    POD=$(kubectl get pod -n "$NAMESPACE" \
        -l "tekton.dev/pipelineTask=task-a" \
        -l "tekton.dev/pipelineRun=${PIPELINERUN_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$POD" ]]; then
        PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$PHASE" == "Running" ]]; then
            log "Pod $POD is Running"
            break
        fi
    fi

    if [[ $i -eq 60 ]]; then
        fail "Timed out waiting for task-a pod to start. Check your cluster."
        kubectl get pipelinerun "$PIPELINERUN_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null || true
        exit 1
    fi
    sleep 2
done

# Give the informer cache a moment to sync the Running status
sleep 3

# ─── Step 3: Delete the pod (simulate eviction) ─────────────────────────────

log "Deleting pod $POD to simulate Kubernetes eviction..."
kubectl delete pod "$POD" -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
log "Pod deleted. The race condition window is now open."

# ─── Step 4: Watch the PipelineRun status ────────────────────────────────────

log "Monitoring PipelineRun status for ${WATCH_TIMEOUT}s..."
echo ""
echo "  Time   | Status      | Reason              | Message"
echo "  -------|-------------|---------------------|----------------------------------------"

FINAL_STATUS=""
FINAL_REASON=""
PREMATURE_FAILURE=false
RECOVERED=false
START_TIME=$(date +%s)

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -gt $WATCH_TIMEOUT ]]; then
        warn "Watch timeout reached (${WATCH_TIMEOUT}s)"
        break
    fi

    STATUS=$(kubectl get pipelinerun "$PIPELINERUN_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "?")
    REASON=$(kubectl get pipelinerun "$PIPELINERUN_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "?")
    MESSAGE=$(kubectl get pipelinerun "$PIPELINERUN_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "?")

    # Truncate message for display
    MESSAGE="${MESSAGE:0:50}"

    printf "  %3ds   | %-11s | %-19s | %s\n" "$ELAPSED" "$STATUS" "$REASON" "$MESSAGE"

    FINAL_STATUS="$STATUS"
    FINAL_REASON="$REASON"

    # Detect premature failure (Failed within 30s of eviction = likely the bug)
    if [[ "$STATUS" == "False" && "$REASON" == "Failed" && $ELAPSED -lt 30 ]]; then
        PREMATURE_FAILURE=true
    fi

    # Detect recovery (was Failed, now Running again)
    if [[ "$PREMATURE_FAILURE" == true && "$STATUS" == "Unknown" ]]; then
        RECOVERED=true
    fi

    # Stop if PipelineRun is Done
    if [[ "$STATUS" == "True" || ("$STATUS" == "False" && $ELAPSED -gt 30) ]]; then
        break
    fi

    sleep 2
done

# ─── Step 5: Report results ─────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FINAL_STATUS" == "True" ]]; then
    pass "PipelineRun SUCCEEDED. The fix is working correctly."
    echo ""
    echo "  The pod eviction was handled gracefully:"
    echo "  1. task-a's pod was recreated after eviction"
    echo "  2. task-a completed successfully"
    echo "  3. task-b ran and completed successfully"
    echo "  4. PipelineRun finished with status: Succeeded"

elif [[ "$PREMATURE_FAILURE" == true && "$RECOVERED" == true ]]; then
    pass "PipelineRun RECOVERED from premature failure (Layer 2 kicked in)."
    echo ""
    echo "  Layer 2 recovery detected:"
    echo "  1. PipelineRun was briefly marked Failed (Layer 1 missed the race)"
    echo "  2. Layer 2 detected running children and reset to Running"
    echo "  3. Final status: $FINAL_STATUS / $FINAL_REASON"

elif [[ "$PREMATURE_FAILURE" == true && "$RECOVERED" == false ]]; then
    fail "BUG REPRODUCED: PipelineRun was PREMATURELY marked Failed."
    echo ""
    echo "  The race condition was triggered:"
    echo "  1. Pod eviction caused TaskRun to briefly show Failed"
    echo "  2. PipelineRun saw stale cache data and marked itself Failed"
    echo "  3. task-b was never scheduled"
    echo "  4. The fix is NOT active or did not prevent the failure"
    echo ""
    echo "  To verify, check the TaskRun status:"
    echo "    kubectl get taskrun -l tekton.dev/pipelineRun=${PIPELINERUN_NAME} -n ${NAMESPACE}"

elif [[ "$FINAL_STATUS" == "False" ]]; then
    warn "PipelineRun Failed (reason: $FINAL_REASON). May or may not be the race condition."
    echo ""
    echo "  Check details:"
    echo "    kubectl get pipelinerun ${PIPELINERUN_NAME} -n ${NAMESPACE} -o yaml"

else
    warn "PipelineRun is still running after ${WATCH_TIMEOUT}s timeout."
    echo "  Current status: $FINAL_STATUS / $FINAL_REASON"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Full PipelineRun details:"
echo "  kubectl get pipelinerun ${PIPELINERUN_NAME} -n ${NAMESPACE} -o yaml"
echo ""
echo "TaskRun details:"
echo "  kubectl get taskrun -l tekton.dev/pipelineRun=${PIPELINERUN_NAME} -n ${NAMESPACE}"
echo ""
echo "Cleanup:"
echo "  kubectl delete pipelinerun ${PIPELINERUN_NAME} -n ${NAMESPACE}"
