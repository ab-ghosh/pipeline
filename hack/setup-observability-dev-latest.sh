#!/bin/bash
# setup-observability-dev.sh - Local observability setup for Tekton Pipeline development
# This script sets up a Kind cluster with Tekton Pipeline, Prometheus, and Jaeger for observability.
# Services are accessed via port-forward for simplicity.
# It assumes you have `kind`, `kubectl`, and `ko` installed and configured.

set -euo pipefail

# Configuration
: "${KO_DOCKER_REPO:=kind.local}" # Local registry for development
: "${KIND_CLUSTER_NAME:=tekton-pipeline-latest}"

wait_for_deploy() {
  local ns="$1"
  local name="$2"
  echo "Waiting for deployment $name in namespace $ns..."
  for i in {1..60}; do
    if kubectl -n "$ns" get deploy "$name" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl -n "$ns" rollout status deploy/"$name" --timeout=300s
}

setup_port_forwards() {
  echo "Setting up port forwards..."
  
  # Kill any existing port-forwards
  pkill -f "kubectl.*port-forward" || true
  sleep 2
  
  # Setup port forwards in background
  kubectl port-forward -n monitoring svc/prometheus 9091:9090 > /dev/null 2>&1 &
  kubectl port-forward -n observability-system svc/jaeger 16686:16686 > /dev/null 2>&1 &
  kubectl port-forward -n tekton-pipelines svc/tekton-pipelines-controller 9090:9090 > /dev/null 2>&1 &
  kubectl port-forward -n tekton-pipelines svc/tekton-pipelines-webhook 9092:9090 > /dev/null 2>&1 &
  kubectl port-forward -n tekton-pipelines svc/tekton-events-controller 9093:9090 > /dev/null 2>&1 &
  kubectl port-forward -n tekton-pipelines-resolvers svc/tekton-pipelines-remote-resolvers 9094:9090 > /dev/null 2>&1 &
  
  echo "Port forwards started in background"
}

export_metrics_to_csv() {
  echo "Exporting metrics to CSV files..."
  
  # Wait a moment for port forwards to be ready
  sleep 3
  
  # Define components with their ports and names
  declare -A components=(
    ["controller"]="9090"
    ["webhook"]="9092"
    ["events"]="9093"
    ["resolvers"]="9094"
  )
  
  for component in "${!components[@]}"; do
    port="${components[$component]}"
    output_file="tekton-${component}-metrics.csv"
    
    echo "Exporting metrics from ${component} (port ${port}) to ${output_file}..."
    
    # Fetch metrics and parse them
    curl -s "http://localhost:${port}/metrics" > /tmp/metrics_${component}.txt
    
    # Create CSV with headers
    echo "metric_name,type,help" > "${output_file}"
    
    # Parse metrics using awk
    awk '
      /^# HELP / {
        help_name = $3
        help_text = ""
        for (i=4; i<=NF; i++) help_text = help_text (i==4 ? "" : " ") $i
        gsub(/"/, "\"\"", help_text)  # Escape quotes
        help[help_name] = help_text
      }
      /^# TYPE / {
        type_name = $3
        type_value = $4
        if (type_name in help) {
          printf "\"%s\",\"%s\",\"%s\"\n", type_name, type_value, help[type_name]
        } else {
          printf "\"%s\",\"%s\",\"\"\n", type_name, type_value
        }
      }
    ' /tmp/metrics_${component}.txt >> "${output_file}"
    
    # Count metrics exported
    metric_count=$(($(wc -l < "${output_file}") - 1))
    echo "  ✓ Exported ${metric_count} metrics to ${output_file}"
  done
  
  # Cleanup temp files
  rm -f /tmp/metrics_*.txt
  
  echo ""
  echo "CSV files created:"
  ls -lh tekton-*-metrics.csv
}

echo "Setting up observability stack..."

# Create Kind cluster configuration
cat > kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.32.0
EOF

# Create Kind cluster
echo "Creating Kind cluster..."
kind create cluster --config kind-config.yaml --name "${KIND_CLUSTER_NAME}"

# Set kubectl context to the new cluster
kubectl config use-context "kind-${KIND_CLUSTER_NAME}"

# Create namespaces first
echo "Creating Tekton namespaces..."
kubectl apply -f config/100-namespace/
kubectl apply -f config/resolvers/

# Create CRDs
echo "Creating Tekton CRDs..."
kubectl apply -f config/300-crds/

# Build and deploy Tekton Pipeline from source
echo "Building and deploying Tekton Pipeline from source..."
export KO_DOCKER_REPO
export KIND_CLUSTER_NAME
ko apply -f config/

# Wait for Tekton Pipeline deployments
echo "Waiting for Tekton Pipeline to be ready..."
wait_for_deploy tekton-pipelines tekton-pipelines-controller
wait_for_deploy tekton-pipelines tekton-pipelines-webhook

# Install Prometheus
echo "Installing Prometheus..."
kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      metric_name_validation_scheme: legacy
    scrape_configs:
    - job_name: 'tekton-pipelines-controller'
      metric_name_escaping_scheme: underscores
      static_configs:
      - targets: ['tekton-pipelines-controller.tekton-pipelines.svc.cluster.local:9090']
    - job_name: 'tekton-pipelines-webhook'
      metric_name_escaping_scheme: underscores
      static_configs:
      - targets: ['tekton-pipelines-webhook.tekton-pipelines.svc.cluster.local:9090']
    - job_name: 'tekton-events-controller'
      metric_name_escaping_scheme: underscores
      static_configs:
      - targets: ['tekton-events-controller.tekton-pipelines.svc.cluster.local:9090']
    - job_name: 'tekton-pipelines-resolvers'
      metric_name_escaping_scheme: underscores
      static_configs:
      - targets: ['tekton-pipelines-remote-resolvers.tekton-pipelines-resolvers.svc.cluster.local:9090']
    - job_name: 'kubernetes-pods'
      metric_name_escaping_scheme: underscores
      kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [tekton-pipelines, tekton-pipelines-resolvers]
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        args:
        - '--config.file=/etc/prometheus/prometheus.yml'
        - '--storage.tsdb.path=/prometheus'
        - '--web.console.libraries=/etc/prometheus/console_libraries'
        - '--web.console.templates=/etc/prometheus/consoles'
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
  type: ClusterIP
EOF

wait_for_deploy monitoring prometheus

# Install Jaeger
echo "Installing Jaeger..."
kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: observability-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:latest
        ports:
        - containerPort: 16686
        - containerPort: 14268
        env:
        - name: COLLECTOR_OTLP_ENABLED
          value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability-system
spec:
  selector:
    app: jaeger
  ports:
  - name: ui
    port: 16686
    targetPort: 16686
  - name: collector
    port: 14268
    targetPort: 14268
  type: ClusterIP
EOF

wait_for_deploy observability-system jaeger

# Update config-tracing to enable Jaeger
echo "Enabling tracing with Jaeger endpoint..."
kubectl patch configmap config-tracing -n tekton-pipelines --type merge -p '{
  "data": {
    "enabled": "true",
    "endpoint": "http://jaeger.observability-system.svc.cluster.local:14268/api/traces"
  }
}'

# Restart deployments to pick up tracing configuration
echo "Restarting Tekton components to enable tracing..."
kubectl rollout restart deployment/tekton-pipelines-controller -n tekton-pipelines
kubectl rollout restart deployment/tekton-pipelines-webhook -n tekton-pipelines
kubectl rollout status deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=300s
kubectl rollout status deployment/tekton-pipelines-webhook -n tekton-pipelines --timeout=300s

wait_for_deploy monitoring prometheus
wait_for_deploy observability-system jaeger

# Setup port forwards
setup_port_forwards

# Export metrics to CSV
export_metrics_to_csv

echo "Setup complete!"
echo ""
echo "Access URLs (via port-forward):"
echo "  Prometheus: http://localhost:9091"
echo "  Jaeger: http://localhost:16686"
echo "  Controller Metrics: http://localhost:9090/metrics"
echo "  Webhook Metrics: http://localhost:9092/metrics"
echo "  Events Controller Metrics: http://localhost:9093/metrics"
echo "  Resolvers Metrics: http://localhost:9094/metrics"
echo ""
echo "Dump all metric names:"
echo "  # Controller metrics"
echo "  curl -s http://localhost:9090/metrics | grep '^# TYPE' | awk '{print \$3}' | sort"
echo ""
echo "  # Webhook metrics"
echo "  curl -s http://localhost:9092/metrics | grep '^# TYPE' | awk '{print \$3}' | sort"
echo ""
echo "  # Events controller metrics"
echo "  curl -s http://localhost:9093/metrics | grep '^# TYPE' | awk '{print \$3}' | sort"
echo ""
echo "  # Resolvers metrics"
echo "  curl -s http://localhost:9094/metrics | grep '^# TYPE' | awk '{print \$3}' | sort"
echo ""
echo "  # All Tekton-specific metrics across all components"
echo "  for port in 9090 9092 9093 9094; do curl -s http://localhost:\$port/metrics; done | grep '^# TYPE' | grep tekton | awk '{print \$3}' | sort -u"
echo ""
echo "  # All Knative metrics (workqueue, webhook, etc.)"
echo "  for port in 9090 9092 9093 9094; do curl -s http://localhost:\$port/metrics; done | grep '^# TYPE' | grep -E 'workqueue|webhook|rest_client' | awk '{print \$3}' | sort -u"
echo ""
echo "Example: Create a sample Pipeline and TaskRun to generate traces and metrics"
echo "  kubectl apply -f examples/v1/pipelineruns/pipelinerun.yaml"
echo ""
echo "Quick metric checks:"
echo "  curl -s http://localhost:9090/metrics | grep -E 'tekton_pipelines_controller_'"
echo "  curl -s http://localhost:9092/metrics | grep -E 'tekton_pipelines_webhook_'"
echo "  curl -s http://localhost:9093/metrics | grep -E 'tekton_events_'"
echo "  curl -s http://localhost:9094/metrics | grep -E 'tekton_resolution_'"
echo ""
echo "Troubleshooting:"
echo "  kubectl logs -n tekton-pipelines -l app.kubernetes.io/part-of=tekton-pipelines,app.kubernetes.io/component=controller"
echo "  kubectl logs -n tekton-pipelines -l app.kubernetes.io/part-of=tekton-pipelines,app.kubernetes.io/component=webhook"
echo "  kubectl logs -n tekton-pipelines -l app.kubernetes.io/part-of=tekton-pipelines,app.kubernetes.io/component=events"
echo "  kubectl logs -n tekton-pipelines-resolvers -l app.kubernetes.io/part-of=tekton-pipelines,app.kubernetes.io/component=resolvers"
echo "  kubectl get configmap -n tekton-pipelines config-observability -o yaml"
echo "  kubectl get configmap -n tekton-pipelines config-tracing -o yaml"
echo ""
echo "Exported metrics CSV files:"
echo "  tekton-controller-metrics.csv"
echo "  tekton-webhook-metrics.csv"
echo "  tekton-events-metrics.csv"
echo "  tekton-resolvers-metrics.csv"
echo ""
echo "Note: Port forwards are running in background. To stop them:"
echo "  pkill -f 'kubectl.*port-forward'"
echo ""
echo "To re-export metrics to CSV after running workloads:"
echo "  # Run this from the script directory" - dump-metrics.sh