#!/usr/bin/env bash
# =============================================================================
# Hub Resolver — ConfigMap URL List Scenarios (EOF commands)
# =============================================================================
# Each scenario requires patching the hubresolver-config ConfigMap BEFORE
# running the TaskRun. Run them one at a time.
#
# Cleanup:
#   kubectl delete taskrun -l test-suite=hub-resolver-configmap-scenarios
#   kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
#     --type json -p '[{"op":"remove","path":"/data/artifact-hub-urls"}]'
# =============================================================================

set -euo pipefail

describe_tr() {
  local name="$1"
  echo ""
  echo ">>> Waiting for $name to complete..."
  sleep 10
  echo ">>> Events for $name:"
  kubectl describe "$name" | sed -n '/^Events:/,$ p'
  echo ""
}

# #############################################################################
# 4a. Single ConfigMap URL resolves successfully
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://artifacthub.io\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4a-single-configmap-url-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4a"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4b. Single ConfigMap URL fails — error NOT wrapped in aggregate message
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://broken-hub.invalid\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4b-single-url-error-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4b"
spec:
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4c. Multiple URLs — first fails, falls through to second
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://broken-hub.invalid\n- https://artifacthub.io\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4c-multi-url-fallback-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4c"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4d. Multiple URLs — first succeeds, second not contacted
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://artifacthub.io\n- https://should-not-be-contacted.invalid\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4d-multi-url-first-wins-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4d"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4e. All ConfigMap URLs fail — aggregated error message
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://broken-hub-1.invalid\n- https://broken-hub-2.invalid\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4e-all-urls-fail-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4e"
spec:
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4f. ConfigMap URLs with multiple trailing slashes
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://artifacthub.io///\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4f-trailing-slashes-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4f"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4g. url param overrides ConfigMap URL list
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://should-not-be-contacted.invalid\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4g-url-overrides-configmap-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4g"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9.0"
      - name: url
        value: https://artifacthub.io
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4h. Tekton Hub ConfigMap URL list (bypasses missing TEKTON_HUB_API)
# #############################################################################
# Patch first (remove artifact-hub-urls, add tekton-hub-urls):
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type json -p '[{"op":"remove","path":"/data/artifact-hub-urls"},{"op":"add","path":"/data/tekton-hub-urls","value":"- https://api.hub.tekton.dev\n"}]'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4h-tekton-configmap-url-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4h"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: tekton
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: "0.9"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4i. Version constraint + ConfigMap URL list — pinning test
# #############################################################################
# Patch first (remove tekton-hub-urls, add artifact-hub-urls):
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type json -p '[{"op":"remove","path":"/data/tekton-hub-urls"},{"op":"add","path":"/data/artifact-hub-urls","value":"- https://artifacthub.io\n"}]'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4i-constraint-pinning-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4i"
spec:
  workspaces:
    - name: output
      emptyDir: {}
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: url
      value: https://github.com/tektoncd/pipeline.git
    - name: revision
      value: main
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: ">= 0.7.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# 4j. Version constraint — all ConfigMap URLs fail
# #############################################################################
# Patch first:
kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
  --type merge -p '{"data":{"artifact-hub-urls":"- https://broken-hub-1.invalid\n- https://broken-hub-2.invalid\n"}}'
sleep 5

TR_NAME=$(kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hub-4j-constraint-all-fail-
  labels:
    test-suite: hub-resolver-configmap-scenarios
    test-scenario: "4j"
spec:
  taskRef:
    resolver: hub
    params:
      - name: type
        value: artifact
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: version
        value: ">= 0.7.0"
EOF
)
TR_NAME=$(echo "$TR_NAME" | awk '{print $1}')
describe_tr "$TR_NAME"

# #############################################################################
# RESTORE ConfigMap (cleanup)
# #############################################################################
# kubectl patch configmap hubresolver-config -n tekton-pipelines-resolvers \
#   --type json -p '[{"op":"remove","path":"/data/artifact-hub-urls"}]'
# kubectl delete taskrun -l test-suite=hub-resolver-configmap-scenarios
