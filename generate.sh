#!/usr/bin/env bash
# ============================================================
# Bindy Helm Chart Generator
# ============================================================
# Idempotently downloads Bindy upstream release assets and produces:
#
#   charts/bindy-crds   – CRD-only library chart  (install first)
#   charts/bindy        – Operator chart with fully-templated resources
#
# Usage:
#   ./generate.sh           # auto-resolves latest Bindy release
#   ./generate.sh v0.5.2    # pin a specific release
#
# Requirements: curl, python3, pyyaml (pip install pyyaml)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${SCRIPT_DIR}/charts"
VERSION="${1:-}"
TMP_DIR=""

cleanup() { [[ -n "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}▶${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die()  { echo -e "${RED}✗ ERROR:${NC} $*" >&2; exit 1; }

# ─── Dependency check ────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing required tools: ${missing[*]}"
  python3 -c "import yaml" 2>/dev/null \
    || die "PyYAML required — run: pip install pyyaml"
}

# ─── Version resolution ──────────────────────────────────────────────────────
resolve_version() {
  if [[ -z "${VERSION}" ]]; then
    log "Fetching latest Bindy release tag..."
    VERSION=$(curl -fsSL "https://api.github.com/repos/firestoned/bindy/releases/latest" \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    info "Latest: ${VERSION}"
  fi
  VERSION="${VERSION#v}"      # strip leading 'v' → 0.5.2
  APP_VERSION="v${VERSION}"   # → v0.5.2
}

# ─── CRD chart ───────────────────────────────────────────────────────────────
generate_crd_chart() {
  local tmp_dir="$1"
  local chart_dir="${CHARTS_DIR}/bindy-crds"
  log "Generating  charts/bindy-crds  (v${VERSION})"
  mkdir -p "${chart_dir}/crds"

  # Chart.yaml — version is injected by bash (unquoted heredoc)
  cat > "${chart_dir}/Chart.yaml" << EOF
apiVersion: v2
name: bindy-crds
description: CustomResourceDefinitions for the Bindy BIND9 Kubernetes Operator
type: application
version: ${VERSION}
appVersion: "${APP_VERSION}"
keywords:
  - dns
  - bind9
  - crds
home: https://github.com/firestoned/bindy
sources:
  - https://github.com/firestoned/bindy
  - https://github.com/Hobart2967/bindy-charts
EOF

  # Extract individual CRDs from install.yaml, preserving original YAML formatting
  INSTALL_YAML="${tmp_dir}/install.yaml" CRD_DIR="${chart_dir}/crds" \
  python3 << 'PYEOF'
import os, yaml

install_yaml = os.environ['INSTALL_YAML']
crd_dir      = os.environ['CRD_DIR']

with open(install_yaml) as f:
    content = f.read()

# Split on bare '---' lines, keeping raw text intact per document
raw_chunks = []
current    = []
for line in content.splitlines(keepends=True):
    if line.rstrip() == '---':
        if current:
            raw_chunks.append(''.join(current))
        current = []
    else:
        current.append(line)
if current:
    raw_chunks.append(''.join(current))

count = 0
for chunk in raw_chunks:
    non_empty = [l for l in chunk.splitlines()
                 if l.strip() and not l.strip().startswith('#')]
    if not non_empty:
        continue
    try:
        doc = yaml.safe_load(chunk)
    except Exception:
        continue
    if not isinstance(doc, dict) or doc.get('kind') != 'CustomResourceDefinition':
        continue
    plural = doc['spec']['names']['plural']
    # Trim any leading comment lines so the file starts with apiVersion:
    lines = chunk.splitlines(keepends=True)
    start = next(
        (i for i, l in enumerate(lines)
         if l.strip() and not l.strip().startswith('#')),
        0
    )
    with open(os.path.join(crd_dir, f'{plural}.yaml'), 'w') as f:
        f.writelines(lines[start:])
    count += 1

print(f"  Extracted {count} CRDs")
PYEOF
}

# ─── Operator chart ──────────────────────────────────────────────────────────
generate_operator_chart() {
  local tmp_dir="$1"
  local chart_dir="${CHARTS_DIR}/bindy"
  log "Generating  charts/bindy        (v${VERSION})"
  mkdir -p "${chart_dir}/templates"

  # ── Chart.yaml
  cat > "${chart_dir}/Chart.yaml" << EOF
apiVersion: v2
name: bindy
description: Helm chart for the Bindy BIND9 Kubernetes Operator
type: application
version: ${VERSION}
appVersion: "${APP_VERSION}"
keywords:
  - dns
  - bind9
  - operator
home: https://github.com/firestoned/bindy
sources:
  - https://github.com/firestoned/bindy
  - https://github.com/Hobart2967/bindy-charts
EOF

  # ── values.yaml  (quoted heredoc — no bash expansion inside)
  cat > "${chart_dir}/values.yaml" << 'EOF'
# Namespace to deploy Bindy into.
# Changed from the upstream default (bindy-system) to allow easy customisation.
namespace: dns

# Create the namespace as part of this chart installation.
createNamespace: true

image:
  repository: ghcr.io/firestoned/bindy
  # Overrides .Chart.AppVersion when set; leave empty to track the chart version.
  tag: ""
  pullPolicy: IfNotPresent

# Number of operator replicas.
# For HA set to 2-3; leader election ensures only one pod is active at a time.
replicas: 1

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

leaderElection:
  enabled: "true"
  leaseName: bindy-leader
  leaseDurationSeconds: "15"
  renewDeadlineSeconds: "10"
  retryPeriodSeconds: "2"

log:
  level: info
  format: text

# Name overrides
nameOverride: ""
fullnameOverride: ""
EOF

  # ── _helpers.tpl
  cat > "${chart_dir}/templates/_helpers.tpl" << 'EOF'
{{/*
Chart name.
*/}}
{{- define "bindy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "bindy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- default "bindy" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "bindy.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{ include "bindy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "bindy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bindy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
EOF

  # ── namespace.yaml
  cat > "${chart_dir}/templates/namespace.yaml" << 'EOF'
{{- if .Values.createNamespace }}
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: {{ .Values.namespace }}
  name: {{ .Values.namespace }}
{{- end }}
EOF

  # ── serviceaccount.yaml
  cat > "${chart_dir}/templates/serviceaccount.yaml" << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "bindy.fullname" . }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "bindy.labels" . | nindent 4 }}
EOF

  # ── clusterrole.yaml — rules extracted live from install.yaml
  info "Extracting ClusterRole rules..."
  INSTALL_YAML="${tmp_dir}/install.yaml" CHART_DIR="${chart_dir}" \
  python3 << 'PYEOF'
import os, yaml

install_yaml = os.environ['INSTALL_YAML']
chart_dir    = os.environ['CHART_DIR']

with open(install_yaml) as f:
    docs = [d for d in yaml.safe_load_all(f) if d and isinstance(d, dict)]

cr = next((d for d in docs if d.get('kind') == 'ClusterRole'), None)
if not cr:
    raise SystemExit("ClusterRole not found in install.yaml")

rules_yaml = yaml.dump(
    {'rules': cr['rules']},
    default_flow_style=False,
    sort_keys=False
)

# Build the template by plain string concatenation — no f-strings, to keep
# the {{ }} Helm delimiters as literal text in the output file.
header = (
    'apiVersion: rbac.authorization.k8s.io/v1\n'
    'kind: ClusterRole\n'
    'metadata:\n'
    '  name: {{ include "bindy.fullname" . }}-role\n'
    '  labels:\n'
    '    {{- include "bindy.labels" . | nindent 4 }}\n'
    '  annotations:\n'
    '    # Trivy suppressions — see upstream justifications in firestoned/bindy\n'
    '    trivy.aquasecurity.com/ignore: KSV-0041,KSV-0056\n'
)

out = os.path.join(chart_dir, 'templates', 'clusterrole.yaml')
with open(out, 'w') as f:
    f.write(header + rules_yaml)

print(f"  ClusterRole written ({len(cr['rules'])} rule groups)")
PYEOF

  # ── clusterrolebinding.yaml
  cat > "${chart_dir}/templates/clusterrolebinding.yaml" << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "bindy.fullname" . }}-rolebinding
  labels:
    {{- include "bindy.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "bindy.fullname" . }}-role
subjects:
  - kind: ServiceAccount
    name: {{ include "bindy.fullname" . }}
    namespace: {{ .Values.namespace }}
EOF

  # ── deployment.yaml
  cat > "${chart_dir}/templates/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "bindy.fullname" . }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "bindy.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      {{- include "bindy.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "bindy.selectorLabels" . | nindent 8 }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: {{ include "bindy.fullname" . }}
      securityContext:
        fsGroup: 65534
        runAsNonRoot: true
      containers:
        - name: bindy
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args: ["run"]
          env:
            - name: RUST_LOG
              value: {{ .Values.log.level | quote }}
            - name: RUST_LOG_FORMAT
              value: {{ .Values.log.format | quote }}
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: BINDY_ENABLE_LEADER_ELECTION
              value: {{ .Values.leaderElection.enabled | quote }}
            - name: BINDY_LEASE_NAME
              value: {{ .Values.leaderElection.leaseName | quote }}
            - name: BINDY_LEASE_DURATION_SECONDS
              value: {{ .Values.leaderElection.leaseDurationSeconds | quote }}
            - name: BINDY_LEASE_RENEW_DEADLINE_SECONDS
              value: {{ .Values.leaderElection.renewDeadlineSeconds | quote }}
            - name: BINDY_LEASE_RETRY_PERIOD_SECONDS
              value: {{ .Values.leaderElection.retryPeriodSeconds | quote }}
          ports:
            - name: metrics
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65534
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/name
                      operator: In
                      values:
                        - {{ include "bindy.name" . }}
                topologyKey: kubernetes.io/hostname
EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  check_deps
  resolve_version

  TMP_DIR=$(mktemp -d)

  local install_url="https://github.com/firestoned/bindy/releases/download/${APP_VERSION}/install.yaml"
  log "Downloading install.yaml (${APP_VERSION})..."
  curl -fsSL "${install_url}" -o "${TMP_DIR}/install.yaml" \
    || die "Download failed: ${install_url}"

  mkdir -p "${CHARTS_DIR}"
  generate_crd_chart      "${TMP_DIR}"
  generate_operator_chart "${TMP_DIR}"

  echo ""
  log "✓ Charts ready in ${CHARTS_DIR}/"
  info "bindy-crds   v${VERSION}  →  ${CHARTS_DIR}/bindy-crds"
  info "bindy        v${VERSION}  →  ${CHARTS_DIR}/bindy"
}

main "$@"
