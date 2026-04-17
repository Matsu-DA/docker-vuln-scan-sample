#!/bin/bash
set -euo pipefail

# ============================================================
# 設定
# ============================================================
IMAGE_NAME="${TARGET_IMAGE:-vuln-scan-target:latest}"
SEVERITY="${SEVERITY_LEVELS:-HIGH,CRITICAL}"
MODE="${MODE:-local}"
SHOW_UNFIXED="${SHOW_UNFIXED:-false}"
STRICT_LOCAL="${STRICT_LOCAL:-false}"
OUTPUT_DIR="/output"
RESULT_JSON="${OUTPUT_DIR}/result.json"
DECISION_JSON="${OUTPUT_DIR}/decision.json"
MAX_DISPLAY="${MAX_DISPLAY:-20}"

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*"; }

# ============================================================
# Trivyオプション構築
# ============================================================
build_trivy_opts() {
  local opts="--scanners vuln --severity ${SEVERITY}"
  if [ "${SHOW_UNFIXED}" != "true" ]; then
    opts="${opts} --ignore-unfixed"
  fi
  if [ -f /trivyignore ]; then
    opts="${opts} --ignorefile /trivyignore"
  fi
  echo "${opts}"
}

# ============================================================
# スキャン実行（1回のみ）
# ============================================================
run_scan() {
  local opts
  opts=$(build_trivy_opts)
  mkdir -p "${OUTPUT_DIR}"

  log_info "Scanning image: ${IMAGE_NAME}"
  if ! trivy image ${opts} --format json -o "${RESULT_JSON}" "${IMAGE_NAME}"; then
    log_error "Trivy scan failed"
    log_error "Possible causes: network issue, DB corruption, Docker daemon unavailable"
    log_error "Scan aborted due to system error."
    exit 2
  fi

  if ! jq -e '.Results' "${RESULT_JSON}" >/dev/null 2>&1; then
    log_error "Invalid Trivy JSON output."
    exit 2
  fi

  log_info "Scan completed."
}

# ============================================================
# table表示（localモード、severity降順、件数制限）
# ============================================================
show_table() {
  if [ "${MODE}" != "local" ]; then return; fi

  local total_vulns
  total_vulns=$(jq '[.Results[]? | select(.Vulnerabilities != null) | .Vulnerabilities | length] | add // 0' "${RESULT_JSON}")

  if [ "$total_vulns" -eq 0 ]; then
    log_info "No vulnerabilities found."
    return
  fi

  echo ""
  echo "=== Vulnerability Report (${SEVERITY}) ==="
  echo ""

  local table_output
  table_output=$(jq -r '
    def severity_order:
      if . == "CRITICAL" then 0 elif . == "HIGH" then 1
      elif . == "MEDIUM" then 2 else 3 end;
    [.Results[] | select(.Vulnerabilities != null) |
     .Target as $target | .Vulnerabilities[] |
     {target: $target, id: .VulnerabilityID, sev: .Severity,
      pkg: .PkgName, ver: .InstalledVersion, fix: (.FixedVersion // "none"),
      order: (.Severity | severity_order)}] |
    sort_by(.order) | .[] |
    "\(.target)\t\(.id)\t\(.sev)\t\(.pkg)\t\(.ver)\t\(.fix)"
  ' "${RESULT_JSON}")

  {
    echo -e "TARGET\tCVE\tSEVERITY\tPACKAGE\tINSTALLED\tFIXED"
    echo "$table_output" | head -n "${MAX_DISPLAY}"
  } | if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi

  if [ "$total_vulns" -gt "$MAX_DISPLAY" ]; then
    echo ""
    log_info "Showing ${MAX_DISPLAY}/${total_vulns}. Full list: ${RESULT_JSON}"
  fi
  echo ""
}

# ============================================================
# 修正難易度分類
# ============================================================
classify_vulns() {
  jq '
    [.Results[] | select(.Vulnerabilities != null) |
     .Type as $type | .Vulnerabilities[] |
     select(.Severity == "CRITICAL" and .FixedVersion != "") |
     { id: .VulnerabilityID, pkg: .PkgName, installed: .InstalledVersion,
       fixed: .FixedVersion,
       class: (if $type == "debian" or $type == "alpine" or $type == "ubuntu"
               then "os" else "app" end) }]
  ' "${RESULT_JSON}"
}

# ============================================================
# 結果判定 + 行動誘導
# ============================================================
evaluate_results() {
  local critical_fixable high_count total_vulns
  critical_fixable=$(jq '[.Results[]?.Vulnerabilities // [] | .[] |
    select(.Severity=="CRITICAL" and .FixedVersion!="")] | length' "${RESULT_JSON}")
  high_count=$(jq '[.Results[]?.Vulnerabilities // [] | .[] |
    select(.Severity=="HIGH")] | length' "${RESULT_JSON}")
  total_vulns=$(jq '[.Results[]? | select(.Vulnerabilities != null) |
    .Vulnerabilities | length] | add // 0' "${RESULT_JSON}")

  local classified app_fixable os_fixable
  classified=$(classify_vulns)
  app_fixable=$(echo "$classified" | jq '[.[] | select(.class=="app")] | length')
  os_fixable=$(echo "$classified" | jq '[.[] | select(.class=="os")] | length')

  # fail判定
  local result="pass"
  local exit_reason=""
  if [ "$critical_fixable" -gt 0 ]; then
    exit_reason="critical_fixable"
    result="fail"
  fi
  if [ "$result" = "fail" ] && [ "$MODE" = "local" ] && [ "$STRICT_LOCAL" != "true" ]; then
    result="warn"
  fi

  # decision.json
  jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --arg mode "${MODE}" \
    --arg image "${IMAGE_NAME}" \
    --argjson total "$total_vulns" \
    --argjson critical_fixable "$critical_fixable" \
    --argjson high "$high_count" \
    --argjson app_fixable "$app_fixable" \
    --argjson os_fixable "$os_fixable" \
    --arg result "$result" \
    --arg exit_reason "$exit_reason" \
    '{ timestamp: $timestamp, mode: $mode, image: $image,
       vulnerabilities: { total: $total, critical_fixable: $critical_fixable, high: $high },
       fix_classification: { app: $app_fixable, os: $os_fixable },
       result: $result, exit_reason: $exit_reason }' > "${DECISION_JSON}"

  # サマリー
  echo ""
  log_info "=== Summary ==="
  log_info "Total (${SEVERITY}): ${total_vulns}"
  log_info "Critical fixable: ${critical_fixable} (app: ${app_fixable}, os: ${os_fixable})"
  log_info "High: ${high_count}"

  # fail時: 行動誘導
  if [ "$critical_fixable" -gt 0 ]; then
    echo ""
    log_error "CRITICAL vulnerabilities with available fixes:"
    if [ "$app_fixable" -gt 0 ]; then
      echo ""
      echo "  [App dependencies]"
      echo "$classified" | jq -r '.[] | select(.class=="app") |
        "    \(.id) (\(.pkg) \(.installed)) -> npm install \(.pkg)@\(.fixed)"'
    fi
    if [ "$os_fixable" -gt 0 ]; then
      echo ""
      echo "  [OS packages]"
      echo "$classified" | jq -r '.[] | select(.class=="os") |
        "    \(.id) (\(.pkg) \(.installed)) -> update base image"'
    fi
    echo ""
    echo "Next actions:"
    echo "  1. npm install <package>@<fixed-version>"
    echo "  2. docker compose build target"
    echo "  3. docker compose up --build"
    echo "  Or add to .trivyignore with justification"
  fi

  # exit
  case "$result" in
    fail)
      log_error "Result: FAIL"
      exit 1
      ;;
    warn)
      log_warn "Result: WARN (CI mode would FAIL)"
      [ "$high_count" -gt 0 ] && log_info "${high_count} HIGH remain."
      ;;
    pass)
      log_info "Result: PASS"
      [ "$high_count" -gt 0 ] && log_info "${high_count} HIGH remain."
      ;;
  esac
}

# ============================================================
# メイン
# ============================================================
echo "======================================"
echo " Docker Vulnerability Scanner"
echo "======================================"
echo ""
echo "Policy:"
echo "  FAIL : CRITICAL + fix available"
echo "  WARN : HIGH (visible, no fail)"
echo "  HIDE : unfixed (no action possible)"
echo ""

run_scan
show_table
evaluate_results

echo ""
log_info "Report: ${RESULT_JSON}"
log_info "Decision: ${DECISION_JSON}"
