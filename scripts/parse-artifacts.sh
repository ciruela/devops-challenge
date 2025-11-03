#!/usr/bin/env bash
set -euo pipefail

# Summarize k6 and Trivy artifacts into human-readable markdown files.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TRIVY_DIR="$ARTIFACTS_DIR/trivy"

mkdir -p "$ARTIFACTS_DIR"

echo "Generating k6 summary..."
K6_SUMMARY="$ARTIFACTS_DIR/k6-summary.md"
cat > "$K6_SUMMARY" <<EOF
# k6 Summary

Generated: $(date --iso-8601=seconds 2>/dev/null || date)

EOF

for ln in bluegreen canary; do
  if [ "$ln" = "bluegreen" ]; then
    LOG="$ARTIFACTS_DIR/k6-bluegreen.log"
    TITLE="Blue/Green"
  else
    LOG="$ARTIFACTS_DIR/k6-canary.log"
    TITLE="Canary"
  fi

  if [ -f "$LOG" ]; then
    echo "\n## $TITLE" >> "$K6_SUMMARY"
    echo "" >> "$K6_SUMMARY"
    # Extract key lines
    awk '/checks\.{5,}/ {print "- checks: " $0} /http_req_failed/ {print "- http_req_failed: " $0} /http_req_duration/ {print "- http_req_duration: " $0} /http_reqs\.{2,}/ {print "- http_reqs: " $0} /iterations\.{2,}/ {print "- iterations: " $0} /vus_max/ {print "- vus_max: " $0} /data_received/ {print "- data_received: " $0} /data_sent/ {print "- data_sent: " $0}' "$LOG" >> "$K6_SUMMARY" || true
    echo "" >> "$K6_SUMMARY"
  else
    echo "Skipping $TITLE — log not found: $LOG"
  fi
done

echo "k6 summary written to $K6_SUMMARY"

echo "\nGenerating Trivy triage..."
TRIAGE_MD="$ARTIFACTS_DIR/trivy-triage.md"
mkdir -p "$TRIVY_DIR"
cat > "$TRIAGE_MD" <<EOF
# Trivy Triage

Generated: $(date --iso-8601=seconds 2>/dev/null || date)

This report lists top vulnerabilities per image and severity counts. Review and prioritize CRITICAL → HIGH → MEDIUM → LOW.

EOF

if compgen -G "$TRIVY_DIR/*.json" >/dev/null 2>&1; then
  for f in "$TRIVY_DIR"/*.json; do
    name="$(basename "$f")"
    echo "\n## $name" >> "$TRIAGE_MD"
    echo "" >> "$TRIAGE_MD"
    # severity counts
    echo "### Severity counts" >> "$TRIAGE_MD"
    jq -r '[.Results[].Vulnerabilities[]? | .Severity] | group_by(.) | map({severity:.[0], count: length})' "$f" >> "$TRIAGE_MD" 2>/dev/null || echo "(no vulnerabilities)" >> "$TRIAGE_MD"
    echo "" >> "$TRIAGE_MD"
    echo "### Top findings (up to 20)" >> "$TRIAGE_MD"
    echo "| CVE | Package | Installed | Fixed | Severity | Title |" >> "$TRIAGE_MD"
    echo "|---|---|---|---|---|---|" >> "$TRIAGE_MD"
    jq -r '.Results[] | .Target as $t | .Vulnerabilities[]? | [.VulnerabilityID, .PkgName, .InstalledVersion, (.FixedVersion // ""), .Severity, (.Title // "")] | @tsv' "$f" | sort -k5,5r | awk -F"\t" 'NR<=20{printf "| %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6}' >> "$TRIAGE_MD" || true
  done
  echo "Trivy triage written to $TRIAGE_MD"
else
  echo "No Trivy JSON files found in $TRIVY_DIR — run Trivy scans first (scripts/ci-local.sh runs them by default)."
fi

echo "Done. Files created:\n - $K6_SUMMARY\n - $TRIAGE_MD (if trivy data present)"

exit 0
