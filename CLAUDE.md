# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Tekton Pipelines is a Kubernetes-native CI/CD system that provides CRDs (Custom Resource Definitions) for declaring pipelines. It is built in Go with vendored dependencies and uses Knative for controller infrastructure.

## Build & Test Commands

```sh
# Build all binaries
make all

# Build a specific binary
go build -mod=vendor ./cmd/controller

# Run all unit tests
go test ./...

# Run a single package's tests
go test ./pkg/reconciler/pipelinerun/...

# Run a single test by name
go test ./pkg/reconciler/pipelinerun/... -run TestReconcile_PipelineRunSuccess

# Run unit tests with race detection
go test -race ./...

# Run e2e tests (requires a running cluster with Tekton installed)
go test -v -count=1 -tags=e2e -timeout=20m ./test

# Run conformance tests
go test -v -count=1 -tags=conformance -timeout=10m ./test

# Lint
make golangci-lint

# Format code
make fmt

# Update generated code (after modifying API types)
./hack/update-codegen.sh

# Update OpenAPI specs
./hack/update-openapigen.sh

# Update dependencies
./hack/update-deps.sh

# Deploy to current cluster using ko
ko apply -R -f config/

# Redeploy just the controller
ko apply -f config/controller.yaml
```

## Architecture

### CRD Types & API Versions
- **v1** (stable): `Task`, `Pipeline`, `TaskRun`, `PipelineRun`, `StepAction` — defined in `pkg/apis/pipeline/v1/`
- **v1beta1** (deprecated): Conversion-compatible types in `pkg/apis/pipeline/v1beta1/`
- **v1alpha1**: `VerificationPolicy`, `StepAction` (pre-stable) — in `pkg/apis/pipeline/v1alpha1/`
- Each type implements `Defaultable` and `Validatable` interfaces for webhook processing
- Generated clients live in `pkg/client/` (auto-generated, do not edit manually)

### Controller Binaries (`cmd/`)
- **controller** — Main reconciliation controller for TaskRuns and PipelineRuns
- **webhook** — Admission/mutation webhook for CRD validation and defaulting
- **resolvers** — Remote resolution of Tasks/Pipelines (hub, git, cluster, bundles)
- **entrypoint** — Injected binary that manages step execution ordering within pods
- **events** — CloudEvents controller for pipeline event emission
- **sidecarlogresults** — Extracts step results from sidecar log files
- **nop** / **workingdirinit** — Init container utilities

### Reconcilers (`pkg/reconciler/`)
Core reconciliation logic for each CRD:
- `pipelinerun/` — Orchestrates PipelineRun execution, creates TaskRuns based on DAG ordering
- `taskrun/` — Manages TaskRun lifecycle, creates pods via `pkg/pod/`
- `resolutionrequest/` — Resolves remote resources

### Key Packages
- `pkg/pod/` — Translates TaskRun specs into Kubernetes Pod specs (step containers, volumes, credential injection)
- `pkg/apis/config/` — ConfigMap-backed runtime configuration (feature flags, defaults, tracing, metrics)
- `pkg/resolution/` — Framework for remote resource resolution
- `pkg/tracing/` — OpenTelemetry tracing setup
- `pkg/credentials/` — Docker/Git credential injection into task pods
- `internal/sidecarlogresults/` — Sidecar-based result extraction

### Configuration (`config/`)
Runtime behavior is controlled via ConfigMaps in the `tekton-pipelines` namespace:
- `config-feature-flags.yaml` — Feature gates (coschedule, disable-creds-init, etc.)
- `config-defaults.yaml` — Default values for TaskRun/PipelineRun
- `config-tracing.yaml` — OpenTelemetry/Jaeger tracing config
- `config-observability.yaml` — Metrics configuration

### Resolver Framework
Built-in resolvers live in `pkg/resolution/resolver/` with config in `config/resolvers/`. Resolution allows Tasks and Pipelines to be fetched from remote sources (OCI bundles, git repos, Tekton Hub, cluster).

## Code Conventions

- Uses vendored dependencies (`go build -mod=vendor`); run `./hack/update-deps.sh` after changing `go.mod`
- After modifying API types in `pkg/apis/`, run `./hack/update-codegen.sh` to regenerate clients and deepcopy methods
- Linting uses `golangci-lint` with config in `.golangci.yml`; the `depguard` rule forbids `io/ioutil` and `github.com/ghodss/yaml` (use `sigs.k8s.io/yaml`)
- E2e test files use build tag `e2e`; unit tests do not require build tags
- The module path is `github.com/tektoncd/pipeline`
