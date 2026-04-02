#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=================================================="
echo "T31 — Suite de tests de producto"
echo "=================================================="

echo
echo "[1/7] cargo fmt --all --check"
cargo fmt --all --check

echo
echo "[2/7] cargo clippy --workspace --all-targets -- -D warnings"
cargo clippy --workspace --all-targets -- -D warnings

echo
echo "[3/7] cargo test --workspace"
cargo test --workspace

echo
echo "[4/7] auth + RBAC + auditoría"
bash scripts/e2e_t31_auth_and_rbac.sh

echo
echo "[5/7] tenant isolation"
bash scripts/e2e_t31_tenant_isolation.sh

echo
echo "[6/7] ingest + schema + severidad + filtros"
bash scripts/e2e_t31_ingest_schema_and_severity.sh

echo
echo "[7/7] webhook retries"
bash scripts/e2e_t31_webhook_retries.sh

echo
echo "✅ T31 completa: suite de producto OK"