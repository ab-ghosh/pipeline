# PipelineRun Premature Failure: Root Cause Analysis and Fix

## The Problem (Two Distinct Issues)

There are **two separate failure modes** that can cause a PipelineRun to be prematurely marked Failed. They have different root causes and different fixes:

| # | Failure Mode | Root Cause | Fix |
|---|-------------|-----------|-----|
| 1 | **Pod eviction/deletion** | TaskRun is **genuinely, permanently Failed** (step exits with code 255, TaskRun reconciler does NOT recreate the pod) | Use `retries` on PipelineTask |
| 2 | **Informer cache staleness** | PipelineRun reads a **stale Failed status** from the informer cache while the TaskRun is actually still Running in the API server | Layer 1 + Layer 2 code fix |

---

## Issue 1: Pod Eviction (TaskRun Does NOT Auto-Recover)

### What Actually Happens

A common misconception is that the TaskRun reconciler will recreate a pod after eviction. **It does not.** Here's the actual sequence:

```
Pod deleted (eviction, kubectl delete, node drain, etc.)
    │
    ▼
Step container receives SIGKILL → exits with code 255
    │
    ▼
TaskRun reconciler calls MakeTaskRunStatus() with the dying pod
    → DidTaskRunFail(pod) returns true (ExitCode != 0)
    → markStatusFailure() sets ConditionSucceeded = False
    → TaskRun is PERMANENTLY Failed
    │
    ▼
Next reconcile: tr.IsDone() == true (line 159)
    → Short-circuits before reconcile() is ever called
    → Pod recreation code at line 704 is NEVER reached
    │
    ▼
TaskRun stays Failed forever
    │
    ▼
PipelineRun sees genuinely Failed TaskRun → marks PipelineRun Failed
```

### Why the Pod Recreation Code is Unreachable

The TaskRun reconciler (`pkg/reconciler/taskrun/taskrun.go`) has pod recreation logic:

```go
// Line 642-645: This code CAN handle missing pods...
if tr.Status.PodName != "" {
    pod, err = c.podLister.Pods(tr.Namespace).Get(tr.Status.PodName)
    if k8serrors.IsNotFound(err) {
        // "Keep going, this will result in the Pod being created below."
    }
}

// Line 704: ...and this code WOULD create a new pod
if pod == nil {
    pod, err = c.createPod(ctx, ts, tr, rtr, workspaceVolumes)
}
```

But this code lives inside `reconcile()` (line 631), which is called at line 230. The problem is that **`tr.IsDone()` at line 159 returns early BEFORE `reconcile()` is ever called**:

```go
// Line 159: This runs FIRST
if tr.IsDone() {       // <-- true because TaskRun was marked Failed
    // ... cleanup ...
    return              // <-- returns here, reconcile() never called
}

// Line 230: This NEVER runs
reconcile(ctx, tr, rtr)  // <-- unreachable when IsDone() is true
```

### Reproduction

```bash
# Apply the pipeline
kubectl apply -f examples/v1/pipelineruns/no-ci/reproduce-premature-failure.yaml

# Wait for task-a pod to be Running
kubectl get pods -w -l tekton.dev/pipelineRun=repro-premature-failure

# Kill the pod
POD=$(kubectl get pod -l tekton.dev/pipelineTask=task-a \
      -l tekton.dev/pipelineRun=repro-premature-failure \
      -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD --grace-period=0

# Watch -- PipelineRun goes Failed permanently
kubectl get pipelinerun repro-premature-failure -w
```

**Result**: PipelineRun marked Failed within seconds. TaskRun is also permanently Failed.

### Fix: Use `retries` on PipelineTask

Tekton has a built-in mechanism for this. Adding `retries: N` to a PipelineTask tells the PipelineRun controller to create a **brand new TaskRun** when one fails:

```yaml
tasks:
  - name: task-a
    retries: 2     # Creates up to 2 new TaskRuns on failure
    taskSpec:
      steps:
        - name: work
          image: alpine:3.19
          script: |
            echo "working..."
            sleep 30
```

When a TaskRun fails (for any reason -- pod eviction, OOM, step error), the PipelineRun controller:
1. Archives the failed TaskRun's status in `tr.Status.RetriesStatus`
2. Creates a brand new TaskRun with a new pod
3. Only marks the PipelineTask as Failed after all retries are exhausted

This is the correct solution for pod eviction resilience today.

---

## Issue 2: Informer Cache Staleness (Race Condition)

### When This Happens

This is a more subtle race that occurs in production Kubernetes clusters under load:

1. The informer cache (lister) is an **asynchronous mirror** of the API server, updated via watch events
2. Watch events can be **delayed by seconds** due to API server load, network latency, or watch bookmark gaps
3. During this delay, the PipelineRun controller reads **stale data** from the cache

### The Race Condition: Step by Step

#### Phase 1: Normal Operation

```
PipelineRun: Running
  TaskRun-A: Running (pod-A is healthy)
  TaskRun-B: Pending (waiting for TaskRun-A to finish)
```

#### Phase 2: Transient Status Flicker

A TaskRun's status can briefly show as Failed in the informer cache while the API server already has a different state. This can happen due to:
- Watch event ordering (Failed event arrives before the correction event)
- API server write latency (TaskRun reconciler wrote Failed, then immediately corrected it, but the cache only received the first write)
- Network partition between the watch stream and the API server

```
API server:  TaskRun-A = Unknown/Running  (already corrected)
Informer:    TaskRun-A = False/Failed     (stale, hasn't received the update yet)
```

#### Phase 3: The Cascade

The PipelineRun controller reads from the stale informer cache:

```go
// pkg/reconciler/pipelinerun/pipelinerun.go:274-280
err = c.updatePipelineRunStatusFromInformer(ctx, pr)  // reads stale cache
```

Then three things happen in rapid succession:

**3a. IsStopping() returns true**

```go
// pkg/reconciler/pipelinerun/resources/pipelinerunstate.go:411-422
func (facts *PipelineRunFacts) IsStopping() bool {
    for _, t := range facts.State {
        if facts.isDAGTask(t.PipelineTask.Name) {
            if t.IsFailure() && t.PipelineTask.OnError != v1.PipelineTaskContinue {
                return true  // "A task failed, stop scheduling new tasks"
            }
        }
    }
    return false
}
```

TaskRun-A appears Failed in cache -> `IsStopping()` = true -> no new tasks scheduled.

**3b. Task count shows zero incomplete**

```go
// pkg/reconciler/pipelinerun/resources/pipelinerunstate.go:793-842
func (facts *PipelineRunFacts) getPipelineTasksCount() pipelineRunStatusCount {
    for _, t := range facts.State {
        switch {
        case t.IsFailure():     s.Failed++       // TaskRun-A counted here
        // TaskRun-B is skipped (StoppingSkip), not counted as Incomplete
        }
    }
}
```

`s.Incomplete == 0` -> all tasks appear "done".

**3c. PipelineRun marked Failed**

```go
if s.Incomplete == 0 && s.Failed > 0 {
    reason = v1.PipelineRunReasonFailed.String()
    status = corev1.ConditionFalse  // PipelineRun marked Failed!
}
```

#### Phase 4: The Point of No Return

```go
if pr.IsDone() {
    c.cleanupAffinityAssistantsAndPVCs(ctx, pr)  // cleanup resources!
    return  // permanently done
}
```

Even when the informer cache catches up (TaskRun-A is actually Running), the PipelineRun is already Done and won't re-evaluate.

### Timeline Diagram

```
Time ──────────────────────────────────────────────────────────────►

API Server:   [  TaskRun-A = Running  ]  [brief flicker?]  [  Running  ]

Informer:     [  TaskRun-A = Running  ]  [  Failed (stale!)  ]  [  Running  ]
                                          │    ▲
                                          │    │ stale cache read
                                          │    │
PipelineRun:  [       Running         ]  [Failed/Done]  ─── forever stuck ──►
                                          │
                                          └── IsStopping() = true
                                              Incomplete = 0
                                              MarkFailed()
                                              CompletionTime set
                                              Resources cleaned up

                              ◄────────────►
                              DANGER ZONE
                          (cache lags behind
                           API server state)
```

---

## The Code Fix: Defense in Depth (Two Layers)

These layers protect against the **informer cache staleness** race (Issue 2). They do NOT fix pod eviction (Issue 1) -- use `retries` for that.

### Layer 1: API Server Verification Before Marking Failed

**When**: At the moment `GetPipelineConditionStatus()` returns `ConditionFalse` with reason `Failed`.

**What**: Before accepting the failure, directly query the API server for each "failed" TaskRun to verify it's truly failed, bypassing the potentially stale informer cache.

```go
// pkg/reconciler/pipelinerun/pipelinerun.go ~line 875
after := pipelineRunFacts.GetPipelineConditionStatus(ctx, pr, logger, c.Clock)
switch after.Status {
case corev1.ConditionFalse:
    if after.Reason == v1.PipelineRunReasonFailed.String() {
        if !c.verifyTaskRunFailures(ctx, pr, pipelineRunFacts) {
            // Cache says failed, but API server disagrees. Defer the failure.
            pr.Status.MarkRunning(v1.PipelineRunReasonRunning.String(),
                "Verifying TaskRun failures before marking PipelineRun as failed")
            pr.Status.CompletionTime = nil
            break
        }
    }
    pr.Status.MarkFailed(after.Reason, after.Message)
}
```

**The verification function** (`verifyTaskRunFailures`):

```go
func (c *Reconciler) verifyTaskRunFailures(ctx context.Context, pr *v1.PipelineRun,
    pipelineRunFacts *resources.PipelineRunFacts) bool {

    verifyCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    for _, rpt := range pipelineRunFacts.State {
        if !rpt.IsFailure() { continue }

        for _, tr := range rpt.TaskRuns {
            if !tr.Status.GetCondition(apis.ConditionSucceeded).IsFalse() { continue }

            // Bypass informer cache -- go directly to API server
            freshTR, err := c.PipelineClientSet.TektonV1().TaskRuns(pr.Namespace).
                Get(verifyCtx, tr.Name, metav1.GetOptions{})
            if err != nil {
                return false  // Can't verify? Safer to defer.
            }

            freshCond := freshTR.Status.GetCondition(apis.ConditionSucceeded)
            if freshCond == nil || !freshCond.IsFalse() {
                // API server shows TaskRun is NOT failed
                return false  // defer the PipelineRun failure
            }
        }
    }
    return true  // all failures confirmed by API server
}
```

**Design decisions**:
- Only fires for `PipelineRunReasonFailed` -- timeouts, cancellations, and validation failures skip verification
- Returns `false` on API errors (safer to defer than accept stale data)
- 5-second timeout prevents blocking the reconciler
- Only checks TaskRuns (CustomRuns/child PipelineRuns don't have this race)
- Nil-safe condition handling (freshCond can be nil if no condition exists yet)

### Layer 2: Recovery for Already-Failed PipelineRuns

**When**: The PipelineRun is already marked Done+Failed (Layer 1 missed the race due to TOCTOU).

**What**: Before taking the `IsDone()` short-circuit exit, check if any children are actually still running. If so, reset the PipelineRun back to Running.

```go
// pkg/reconciler/pipelinerun/pipelinerun.go ~line 240
if pr.IsDone() && pr.IsFailure() {
    condition := pr.Status.GetCondition(apis.ConditionSucceeded)
    if condition != nil && condition.Reason == v1.PipelineRunReasonFailed.String() {
        if c.hasRunningChildren(pr) {
            pr.Status.MarkRunning(v1.PipelineRunReasonRunning.String(),
                "Re-evaluating PipelineRun: child run recovered from transient failure")
            pr.Status.CompletionTime = nil
            pr.Status.Results = nil
            // Falls through to normal reconciliation
        }
    }
}

if pr.IsDone() {
    // Normal short-circuit: cleanup and return
}
```

**The children check function** (`hasRunningChildren`):
- Uses informer cache (lister) -- zero API server calls, O(1) lookups
- Checks all child types: TaskRun, CustomRun, PipelineRun
- Only triggers for `PipelineRunReasonFailed` -- timeouts and cancellations are intentional
- Clears `CompletionTime` and `Results` (invalid when Running)
- Runs BEFORE `cleanupAffinityAssistantsAndPVCs()`, preventing premature cleanup

**Why Layer 2 is needed even with Layer 1**:
- **TOCTOU race**: API server might show Failed during Layer 1's check, but the TaskRun status is corrected milliseconds later
- **Trigger mechanism**: When the corrected TaskRun watch event fires, it triggers PipelineRun re-reconciliation, which hits Layer 2

---

## How the Two Layers Interact

```
                    PipelineRun Reconcile
                           │
                           ▼
              ┌─── pr.IsDone() && pr.IsFailure()? ───┐
              │ YES                                    │ NO
              ▼                                        │
     Layer 2: hasRunningChildren()?                    │
      │ YES            │ NO                            │
      ▼                ▼                               │
   Reset to       Short-circuit                        │
   Running        (stay Failed)                        │
      │                                                │
      ▼                                                ▼
              Normal Reconciliation
                       │
                       ▼
            GetPipelineConditionStatus()
                       │
           ┌───────────┼───────────┐
           │           │           │
        Success     Failure     Running
           │           │           │
           ▼           ▼           ▼
       MarkSucceeded   │      MarkRunning
                       │
                       ▼
              Layer 1: Reason == "Failed"?
               │ YES            │ NO (timeout/cancel)
               ▼                ▼
        verifyTaskRunFailures() MarkFailed immediately
         │ true      │ false
         ▼           ▼
    MarkFailed    MarkRunning (defer failure)
```

---

## Edge Cases

| Scenario | Layer 1 | Layer 2 | Outcome |
|----------|---------|---------|---------|
| **Pod eviction (TaskRun genuinely dead)** | API confirms Failed | No running children | PipelineRun correctly Failed. Use `retries` to handle this. |
| **Informer cache stale, API shows Running** | Defers failure | N/A (never marked Failed) | PipelineRun stays Running |
| **TOCTOU: API shows Failed, then TaskRun corrects** | L1 accepts failure | L2 detects running child on next reconcile | Self-corrects |
| **API server unreachable** | Defers failure (returns false) | Fallback on next reconcile | Safe: never marks Failed on stale data |
| **Timeout failure** | Skipped (reason != "Failed") | Skipped (reason != "Failed") | Correctly marked TimedOut |
| **Cancelled PipelineRun** | Skipped | Skipped | Correctly stays Cancelled |

---

## Summary: Which Fix Applies When

```
Pod eviction / node drain / OOM kill / step error
    │
    └── TaskRun is GENUINELY Failed (permanently)
        │
        └── Fix: Add `retries: N` to PipelineTask
            The PipelineRun controller creates a new TaskRun on failure.

Informer cache staleness / watch event delay
    │
    └── TaskRun APPEARS Failed in cache but is actually Running
        │
        └── Fix: Layer 1 (API server verification) + Layer 2 (recovery)
            Prevents PipelineRun from acting on stale data.
```

---

## Files Modified

| File | Change |
|------|--------|
| `pkg/reconciler/pipelinerun/pipelinerun.go` | Added `verifyTaskRunFailures()`, `hasRunningChildren()`, Layer 1 check at status transition, Layer 2 check before IsDone() short-circuit |
| `pkg/reconciler/pipelinerun/resources/pipelinerunresolution.go` | Exported `IsFailure()` (was `isFailure()`) so the pipelinerun package can call it |
| `pkg/reconciler/pipelinerun/resources/pipelinerunstate.go` | Updated callers of `isFailure()` to `IsFailure()` |
| `pkg/reconciler/pipelinerun/pipelinerun_test.go` | 10 new tests covering both layers, unit tests for helpers |
| `pkg/reconciler/pipelinerun/resources/pipelinerunstate_test.go` | Updated stale comments referencing `isFailure()` |

---

## Test Coverage

| Test | What it verifies |
|------|-----------------|
| `TestReconcile_DeferFailureWhenTaskRunRecoveredInAPIServer` | Layer 1: cache=Failed, API=Running -> PipelineRun stays Running |
| `TestReconcile_ConfirmFailureWhenTaskRunFailedInAPIServer` | Layer 1: cache=Failed, API=Failed -> PipelineRun marked Failed |
| `TestReconcile_APIServerErrorDuringVerification` | Layer 1: API error -> failure deferred |
| `TestReconcile_SkipVerificationForTimeoutAndCancellation` | Layer 1: timeout/cancel skips verification |
| `TestReconcile_FailedPipelineRunWithRecoveringTaskRun` | Layer 2: Failed PR + running child -> resets to Running |
| `TestReconcile_FailedPipelineRunWithAllTerminalChildren` | Layer 2: Failed PR + all done children -> stays Failed |
| `TestReconcile_TimedOutPipelineRunWithRunningChildren` | Layer 2: TimedOut PR not re-evaluated |
| `TestReconcile_CancelledPipelineRunWithRunningChildren` | Layer 2: Cancelled PR not re-evaluated |
| `TestHasRunningChildren` | Unit: TaskRun, CustomRun, PipelineRun children, lister errors |
| `TestVerifyTaskRunFailures` | Unit: confirmed failed, recovered, API error |

---

## Reproducing Pod Eviction with `retries`

```bash
# Clean up previous run
kubectl delete pipelinerun repro-premature-failure --ignore-not-found
kubectl delete pipeline repro-premature-failure-pipeline --ignore-not-found

# Apply the version with retries
kubectl apply -f examples/v1/pipelineruns/no-ci/reproduce-premature-failure.yaml

# Wait for pod, then kill it
kubectl get pods -w -l tekton.dev/pipelineRun=repro-premature-failure
POD=$(kubectl get pod -l tekton.dev/pipelineTask=task-a \
      -l tekton.dev/pipelineRun=repro-premature-failure \
      -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD --grace-period=0

# Watch -- should retry task-a, then run task-b, then Succeeded
kubectl get pipelinerun repro-premature-failure -w
```
