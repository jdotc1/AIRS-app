#!/bin/bash
# First-run CI example; reuse an existing receipt instead of repeating unchanged checks.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo 'Usage: verify-owned-policy-example.sh /absolute/airs-entitlements /absolute/new-output-directory' >&2
    exit 2
fi
POLICY_CLI="$1"
POLICY_OUTPUT="$2"
POLICY_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir "$POLICY_OUTPUT"
POLICY_EXPECTED=0
for POLICY_CASE in passed failed incomplete; do
    set +e
    "$POLICY_CLI" review --request "$POLICY_PROJECT/fixtures/policy-owned/$POLICY_CASE-request.json" --output "$POLICY_OUTPUT/$POLICY_CASE.json" > "$POLICY_OUTPUT/$POLICY_CASE.stdout.json" 2> "$POLICY_OUTPUT/$POLICY_CASE.stderr.log"
    POLICY_ACTUAL=$?
    set -e
    if [ "$POLICY_ACTUAL" -ne "$POLICY_EXPECTED" ]; then
        echo "$POLICY_CASE: expected exit $POLICY_EXPECTED, got $POLICY_ACTUAL" >&2
        exit 1
    fi
    POLICY_EXPECTED=$((POLICY_EXPECTED + 1))
done
python3 - "$POLICY_OUTPUT" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
for name, violations, missing in [('passed',0,0),('failed',1,0),('incomplete',1,2)]:
    result=json.loads((root/(name+'.json')).read_text())
    assert result['status']==name and result['mode']=='historicalRecord'
    assert len(result['violations'])==violations and len(result['missingEvidence'])==missing
    assert (root/(name+'.json')).read_bytes()==(root/(name+'.stdout.json')).read_bytes()
print('Owned policy example: exits 0/1/2, known violations, missing evidence and stdout/file parity passed.')
PY
