#!/usr/bin/env bash
# Model-check Waycar's mosh protocol with TLC and compare every run with the
# outcome it is meant to have (README.md explains each run).
#
#   check.sh             quick tier (about 5 minutes)
#   check.sh full        quick tier plus the deepest bounds (about 10 more)
#   check.sh NAME...     only the named runs
#   check.sh list        run names, tiers and expected outcomes
#   check.sh cfg NAME    print the TLC .cfg a run uses
#
# Needs Java 17+ on PATH (or JAVA_HOME). tla2tools.jar v1.7.4 is downloaded to
# ~/.cache/waycar and checked against a pinned sha256 unless TLA2TOOLS names a
# jar. TLC_WORKERS (default 4) and TLC_HEAP (default 6g) size the runs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TLC_URL=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
TLC_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88

# ---------------------------------------------------------------------------
# Constants. A profile is a list of NAME=VALUE pairs; a run may override some.
# ---------------------------------------------------------------------------
profile() {
  case $1 in
    # One cell and two values: states alternate 0,1,0,1, which is enough for a
    # cell that changes and changes back. Datagram budget 4 each way.
    dl-quick) echo "NCells=1 NVals=2 MaxStates=3 MaxAddr=2 MaxSeq=4 MaxLoss=1 MaxDup=1 MaxInFlight=2 MaxHeld=4 ApplyOnTop=FALSE ApplyStale=FALSE RoamAnySeq=FALSE AnyBase=FALSE EagerResend=TRUE" ;;
    dl-deep) echo "NCells=1 NVals=2 MaxStates=3 MaxAddr=2 MaxSeq=5 MaxLoss=1 MaxDup=1 MaxInFlight=2 MaxHeld=4 ApplyOnTop=FALSE ApplyStale=FALSE RoamAnySeq=FALSE AnyBase=FALSE EagerResend=TRUE" ;;
    # Two cells, so a diff can touch one cell and skip the other. One flow.
    dl-2cell) echo "NCells=2 NVals=2 MaxStates=3 MaxAddr=1 MaxSeq=4 MaxLoss=1 MaxDup=1 MaxInFlight=2 MaxHeld=4 ApplyOnTop=FALSE ApplyStale=FALSE RoamAnySeq=FALSE AnyBase=FALSE EagerResend=TRUE" ;;
    # Four states and a cap of 3 screens: the cap can bind.
    dl-cap) echo "NCells=1 NVals=2 MaxStates=4 MaxAddr=1 MaxSeq=4 MaxLoss=1 MaxDup=1 MaxInFlight=3 MaxHeld=3 ApplyOnTop=FALSE ApplyStale=FALSE RoamAnySeq=FALSE AnyBase=FALSE EagerResend=TRUE" ;;
    # Retransmit timer only fires when nothing of that state is in flight.
    dl-live) echo "NCells=1 NVals=2 MaxStates=2 MaxAddr=2 MaxSeq=4 MaxLoss=1 MaxDup=1 MaxInFlight=2 MaxHeld=4 ApplyOnTop=FALSE ApplyStale=FALSE RoamAnySeq=FALSE AnyBase=FALSE EagerResend=FALSE" ;;
    dl-live-deep) echo "NCells=1 NVals=2 MaxStates=2 MaxAddr=2 MaxSeq=5 MaxLoss=1 MaxDup=1 MaxInFlight=2 MaxHeld=4 ApplyOnTop=FALSE ApplyStale=FALSE RoamAnySeq=FALSE AnyBase=FALSE EagerResend=FALSE" ;;
    up-quick) echo "MaxStates=3 MaxKeys=2 MaxSeq=5 MaxShutSends=2 MaxRebinds=1 MaxLoss=1 MaxDup=1 MaxInFlight=2 ShutdownOnOlderBase=FALSE RecordAfterSend=FALSE RebindResetsSeq=FALSE EagerResend=TRUE" ;;
    up-deep) echo "MaxStates=3 MaxKeys=2 MaxSeq=6 MaxShutSends=2 MaxRebinds=1 MaxLoss=1 MaxDup=1 MaxInFlight=3 ShutdownOnOlderBase=FALSE RecordAfterSend=FALSE RebindResetsSeq=FALSE EagerResend=TRUE" ;;
    up-live) echo "MaxStates=2 MaxKeys=2 MaxSeq=6 MaxShutSends=1 MaxRebinds=1 MaxLoss=1 MaxDup=1 MaxInFlight=2 ShutdownOnOlderBase=FALSE RecordAfterSend=FALSE RebindResetsSeq=FALSE EagerResend=FALSE" ;;
    *) echo "unknown profile $1" >&2; exit 64 ;;
  esac
}

DL_INV="TypeOK TerminalExact HeldExact DisplayedHeld BaseAlwaysHeld AckSound TargetOpened"
DL_PROP="NoRollback TargetMonotone"
UP_INV="TypeOK NoInventedInput ContentsAgree ServerNeverAsserts PrefixChain ShutdownKeepsInput NonceUnique AckSound"
UP_PROP="FedMonotone"

# ---------------------------------------------------------------------------
# The runs. Columns: name | tier | module | profile | overrides | spec |
# invariants | properties | expected outcome.
# Outcomes: ok | inv:NAME | prop:NAME (an action property) | temporal.
# A witness asserts that something never happens, so it must be violated.
# ---------------------------------------------------------------------------
runs() {
  cat <<EOF
downlink-safety|quick|MoshDownlink|dl-quick||Spec|$DL_INV|$DL_PROP|ok
downlink-safety-2cell|quick|MoshDownlink|dl-2cell||Spec|$DL_INV|$DL_PROP|ok
downlink-safety-deep|full|MoshDownlink|dl-deep||Spec|$DL_INV|$DL_PROP|ok
downlink-live|quick|MoshDownlink|dl-live||LiveSpec|TypeOK|Converges|ok
downlink-live-deep|full|MoshDownlink|dl-live-deep||LiveSpec|TypeOK|Converges|ok
downlink-live-without-fairness|quick|MoshDownlink|dl-live||Spec|TypeOK|Converges|temporal
downlink-cap-evicts-base|quick|MoshDownlink|dl-cap||Spec|$DL_INV|$DL_PROP|inv:BaseAlwaysHeld
downlink-cap-terminal-exact|quick|MoshDownlink|dl-cap||Spec|TypeOK TerminalExact HeldExact DisplayedHeld AckSound TargetOpened|$DL_PROP|ok
downlink-stale-state-applied|quick|MoshDownlink|dl-quick|ApplyStale=TRUE|Spec|$DL_INV|$DL_PROP|ok
downlink-apply-on-top|quick|MoshDownlink|dl-quick|ApplyOnTop=TRUE|Spec|$DL_INV|$DL_PROP|inv:TerminalExact
downlink-roam-any-seq|quick|MoshDownlink|dl-quick|RoamAnySeq=TRUE|Spec|$DL_INV|$DL_PROP|prop:TargetMonotone
downlink-any-base|quick|MoshDownlink|dl-quick|AnyBase=TRUE|Spec|$DL_INV|$DL_PROP|inv:TerminalExact
downlink-witness-repaint|quick|MoshDownlink|dl-quick||Spec||NeverRepaints|prop:NeverRepaints
downlink-witness-drop|quick|MoshDownlink|dl-quick||Spec||NeverDrops|prop:NeverDrops
downlink-witness-stale-seq|quick|MoshDownlink|dl-quick||Spec||NeverStaleSeq|prop:NeverStaleSeq
downlink-witness-closed-flow|quick|MoshDownlink|dl-quick||Spec||NeverClosedFlow|prop:NeverClosedFlow
downlink-witness-roam|quick|MoshDownlink|dl-quick||Spec||NeverRoams|prop:NeverRoams
downlink-witness-finish|quick|MoshDownlink|dl-quick||Spec|NeverFinishes||inv:NeverFinishes
downlink-witness-caught-up|quick|MoshDownlink|dl-live||LiveSpec|NeverCaughtUp||inv:NeverCaughtUp
downlink-witness-full-cache|quick|MoshDownlink|dl-cap||Spec|NeverFullCache||inv:NeverFullCache
uplink-safety|quick|MoshUplink|up-quick||Spec|$UP_INV|$UP_PROP|ok
uplink-safety-deep|full|MoshUplink|up-deep||Spec|$UP_INV|$UP_PROP|ok
uplink-live|quick|MoshUplink|up-live||LiveSpec|TypeOK|InputDelivered|ok
uplink-live-without-fairness|quick|MoshUplink|up-live||Spec|TypeOK|InputDelivered|temporal
uplink-shutdown-on-older-base|quick|MoshUplink|up-quick|ShutdownOnOlderBase=TRUE|Spec|$UP_INV|$UP_PROP|inv:ContentsAgree
uplink-record-after-send|quick|MoshUplink|up-quick|RecordAfterSend=TRUE|Spec|$UP_INV|$UP_PROP|inv:ContentsAgree
uplink-rebind-resets-seq|quick|MoshUplink|up-quick|RebindResetsSeq=TRUE|Spec|$UP_INV|$UP_PROP|inv:NonceUnique
uplink-witness-retransmit|quick|MoshUplink|up-quick||Spec||NeverRetransmits|prop:NeverRetransmits
uplink-witness-ignored-base|quick|MoshUplink|up-quick||Spec||NeverIgnores|prop:NeverIgnores
uplink-witness-exit|quick|MoshUplink|up-quick||Spec|NeverExits||inv:NeverExits
uplink-witness-shutdown-acked|quick|MoshUplink|up-quick||Spec|NeverShutAcked||inv:NeverShutAcked
uplink-witness-all-typed|quick|MoshUplink|up-quick||Spec|NeverAllTyped||inv:NeverAllTyped
uplink-witness-all-delivered|quick|MoshUplink|up-live||LiveSpec|NeverAllDelivered||inv:NeverAllDelivered
uplink-witness-rebind-delivers|quick|MoshUplink|up-quick||Spec|NeverRebindDelivers||inv:NeverRebindDelivers
EOF
}

# Print the .cfg for one run row.
make_cfg() { # profile overrides spec invariants properties
  local consts=$1 over=$2 spec=$3 invs=$4 props=$5 kv key
  echo "SPECIFICATION $spec"
  echo "CONSTANTS"
  for kv in $consts; do
    key=${kv%%=*}
    for o in $over; do [[ ${o%%=*} == "$key" ]] && kv=$o; done
    echo "    ${kv%%=*} = ${kv#*=}"
  done
  if [[ -n $invs ]]; then echo "INVARIANTS"; for i in $invs; do echo "    $i"; done; fi
  if [[ -n $props ]]; then echo "PROPERTIES"; for p in $props; do echo "    $p"; done; fi
  echo "CONSTRAINT InFlightBound"
  echo "CHECK_DEADLOCK FALSE"
}

row() { # name -> sets fields from the table, or fails
  local line
  line=$(runs | awk -F'|' -v n="$1" '$1 == n') || true
  [[ -n $line ]] || { echo "check.sh: no run named $1 (try: check.sh list)" >&2; exit 64; }
  IFS='|' read -r name tier module prof over spec invs props expect <<<"$line"
}

# ---------------------------------------------------------------------------
# Tooling.
# ---------------------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

find_jar() {
  if [[ -n ${TLA2TOOLS:-} ]]; then echo "$TLA2TOOLS"; return; fi
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/waycar jar
  jar=$dir/tla2tools-1.7.4.jar
  if [[ ! -f $jar ]]; then
    mkdir -p "$dir"
    curl -fsSL -o "$jar.part" "$TLC_URL"
    mv "$jar.part" "$jar"
  fi
  [[ $(sha256_of "$jar") == "$TLC_SHA256" ]] || { echo "check.sh: $jar does not match the pinned sha256" >&2; exit 70; }
  echo "$jar"
}

find_java() {
  if [[ -n ${JAVA_HOME:-} && -x $JAVA_HOME/bin/java ]]; then echo "$JAVA_HOME/bin/java"
  elif command -v java >/dev/null; then command -v java
  else echo "check.sh: Java 17+ not found (set JAVA_HOME or put java on PATH)" >&2; exit 69; fi
}

# Classify TLC's output into an outcome token.
outcome() {
  local out=$1 line
  if grep -q '^Model checking completed. No error has been found' "$out"; then echo ok; return; fi
  if line=$(grep -m1 -E '^Error: Invariant .* is violated' "$out"); then
    line=${line#Error: Invariant }; echo "inv:${line%% *}"; return
  fi
  if line=$(grep -m1 -E '^Error: Action property .* is violated' "$out"); then
    line=${line#Error: Action property }; echo "prop:${line%% *}"; return
  fi
  if grep -q '^Error: Temporal properties were violated' "$out"; then echo temporal; return; fi
  echo "error:$(grep -m1 -E '^Error' "$out" | tr ' ' '_' | cut -c1-80)"
}

run_one() { # name
  row "$1"
  local cfg=$work/$name.cfg out=$work/$name.out started=$SECONDS got
  make_cfg "$(profile "$prof")" "$over" "$spec" "$invs" "$props" >"$cfg"
  ( cd "$here" && "$java" -Xmx"${TLC_HEAP:-6g}" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
      -workers "${TLC_WORKERS:-4}" -metadir "$work/meta-$name" -config "$cfg" "$module" ) >"$out" 2>&1 || true
  got=$(outcome "$out")
  local states depth verdict=PASS
  states=$(grep -E '^[0-9]+ states generated' "$out" | tail -1 | sed -E 's/^[0-9]+ states generated, ([0-9]+) distinct.*/\1/' || true)
  depth=$(grep -E '^The depth of the complete state graph search is' "$out" | sed -E 's/.* is ([0-9]+)\./\1/' || true)
  [[ $got == "$expect" ]] || { verdict=FAIL; failed=$((failed + 1)); cp "$out" "${TMPDIR:-/tmp}/waycar-tlc-$name.out"; }
  printf '%-4s %-34s expect %-26s got %-26s distinct %-10s depth %-3s %4ss\n' \
    "$verdict" "$name" "$expect" "$got" "${states:-?}" "${depth:--}" "$((SECONDS - started))"
}

# ---------------------------------------------------------------------------
case ${1:-quick} in
  list) runs | awk -F'|' '{printf "%-34s %-6s %s\n", $1, $2, $9}'; exit 0 ;;
  cfg)
    [[ $# -eq 2 ]] || { echo "usage: check.sh cfg NAME" >&2; exit 64; }
    row "$2"; make_cfg "$(profile "$prof")" "$over" "$spec" "$invs" "$props"; exit 0 ;;
esac

java=$(find_java)
jar=$(find_jar)
work=$(mktemp -d "${TMPDIR:-/tmp}/waycar-tlc.XXXXXX")
trap 'rm -rf "$work"' EXIT
failed=0

case ${1:-quick} in
  quick) names=$(runs | awk -F'|' '$2 == "quick" {print $1}') ;;
  full)  names=$(runs | awk -F'|' '{print $1}') ;;
  *)     names=$* ;;
esac

echo "$("$java" -version 2>&1 | head -1), tla2tools $(basename "$jar")"
for n in $names; do run_one "$n"; done
if (( failed )); then echo "$failed run(s) did not match; their TLC output is in ${TMPDIR:-/tmp}/waycar-tlc-*.out" >&2; exit 1; fi
echo "every run matched its expected outcome"
