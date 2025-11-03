#!/usr/bin/env bash
set -euo pipefail

# Summarize k6 and Trivy artifacts into human-readable markdown files.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TRIVY_DIR="$ARTIFACTS_DIR/trivy"

mkdir -p "$ARTIFACTS_DIR"

echo "Generating k6 summary (from k6 JSONs)..."
K6_SUMMARY="$ARTIFACTS_DIR/k6-summary.md"
cat > "$K6_SUMMARY" <<EOF
# k6 Summary (parsed from JSON)

Generated: $(date --iso-8601=seconds 2>/dev/null || date)

EOF

parse_k6_json() {
  local json_file="$1"
  local title="$2"
  [ -f "$json_file" ] || return 0

  echo "\n## $title" >> "$K6_SUMMARY"
  echo "" >> "$K6_SUMMARY"

  # Extract arrays of numbers and metadata using jq
  # durations (ms)
  jq -r 'select(.metric=="http_req_duration" and .type=="Point") | .data.value' "$json_file" > /tmp/k6_durations.txt || true

  # failed flags (0/1)
  jq -r 'select(.metric=="http_req_failed" and .type=="Point") | .data.value' "$json_file" > /tmp/k6_failed.txt || true

  # requests increments (many files have value=1 per point) — sum gives total requests
  jq -r 'select(.metric=="http_reqs" and .type=="Point") | .data.value' "$json_file" > /tmp/k6_reqs.txt || true

  # checks (rate points) — sum
  jq -r 'select(.metric=="checks" and .type=="Point") | .data.value' "$json_file" > /tmp/k6_checks.txt || true

  # vus_max gauge (take max)
  VUS_MAX=$(jq -r 'select(.metric=="vus_max" and .type=="Point") | .data.value' "$json_file" | awk 'BEGIN{m=0} {if($1+0>m) m=$1} END{print m+0}')

  # data sent/received (take last values)
  DATA_SENT=$(jq -r 'select(.metric=="data_sent" and .type=="Point") | .data.value' "$json_file" | tail -n1)
  DATA_RECV=$(jq -r 'select(.metric=="data_received" and .type=="Point") | .data.value' "$json_file" | tail -n1)

  # timestamps for http_reqs to compute duration
  jq -r 'select(.metric=="http_reqs" and .type=="Point") | .data.time' "$json_file" > /tmp/k6_reqs_times.txt || true

  # Compute stats via Python for durations and counts
  python3 - <<PY >> "$K6_SUMMARY" 2>/dev/null || true
import sys,statistics
from pathlib import Path
dur_file=Path('/tmp/k6_durations.txt')
req_file=Path('/tmp/k6_reqs.txt')
failed_file=Path('/tmp/k6_failed.txt')
checks_file=Path('/tmp/k6_checks.txt')
time_file=Path('/tmp/k6_reqs_times.txt')

def to_float_lines(p):
    if not p.exists():
        return []
    return [float(x) for x in p.read_text().split() if x.strip()]

durations=to_float_lines(dur_file)
reqs=to_float_lines(req_file)
failed=to_float_lines(failed_file)
checks=to_float_lines(checks_file)
times=[x.strip() for x in (time_file.read_text().splitlines() if time_file.exists() else [])]

def pctile(arr,p):
    if not arr:
        return None
    arr_sorted=sorted(arr)
    k=(len(arr_sorted)-1)*(p/100.0)
    f=int(k)
    c=min(f+1,len(arr_sorted)-1)
    if f==c:
        return arr_sorted[int(k)]
    d=k-f
    return arr_sorted[f] + (arr_sorted[c]-arr_sorted[f])*d

total_reqs=sum(reqs)
total_failed=sum(failed)
total_checks=sum(checks)
duration_seconds=None
if times:
    # parse ISO times and compute duration
    from datetime import datetime
    try:
        t0=datetime.fromisoformat(times[0].replace('Z','+00:00'))
        t1=datetime.fromisoformat(times[-1].replace('Z','+00:00'))
        duration_seconds=(t1-t0).total_seconds()
    except Exception:
        duration_seconds=None

print(f"- total_requests: {int(total_reqs)}")
print(f"- total_failed: {int(total_failed)}")
print(f"- total_checks: {int(total_checks)}")
print(f"- vus_max: {int(float($VUS_MAX or 0)) if '$VUS_MAX' != 'None' else 'N/A'}")
if duration_seconds:
    rps = total_reqs / duration_seconds if duration_seconds>0 else 0
    print(f"- duration_s: {duration_seconds:.2f}")
    print(f"- rps: {rps:.2f} req/s")
else:
    print(f"- duration_s: unknown")

if durations:
    print(f"- duration_ms_avg: {statistics.mean(durations):.3f}")
    print(f"- duration_ms_min: {min(durations):.3f}")
    print(f"- duration_ms_max: {max(durations):.3f}")
    print(f"- duration_ms_p50: {pctile(durations,50):.3f}")
    print(f"- duration_ms_p90: {pctile(durations,90):.3f}")
    print(f"- duration_ms_p95: {pctile(durations,95):.3f}")
    print(f"- duration_ms_p99: {pctile(durations,99):.3f}")
else:
    print("- duration data: none")

if DATA_SENT:
    try:
        ds=float('$DATA_SENT')
        dr=float('$DATA_RECV')
        print(f"- data_sent_kb: {ds/1024:.1f} kB")
        print(f"- data_received_kb: {dr/1024:.1f} kB")
    except Exception:
        pass
PY

  echo "" >> "$K6_SUMMARY"
  # cleanup temp files
  rm -f /tmp/k6_durations.txt /tmp/k6_failed.txt /tmp/k6_reqs.txt /tmp/k6_checks.txt /tmp/k6_reqs_times.txt || true
}

parse_k6_json "$ARTIFACTS_DIR/k6-bluegreen.json" "Blue/Green"
parse_k6_json "$ARTIFACTS_DIR/k6-canary.json" "Canary"

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
