#!/bin/bash
# Summarise a finished experiment directory.
#
#   ./analyze_experiment.sh out/0906_143000_sample-map-planning
#
# Split out from run_scenorita_experiment.sh so a campaign that was interrupted,
# or one finished months ago, can still be summarised without re-running it.
# Reads only what is on disk; drives nothing.
set -euo pipefail
OUT="${1:?usage: analyze_experiment.sh <out/EXPERIMENT_DIR>}"
[ -d "$OUT" ] || { echo "no such experiment directory: $OUT" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${MOZART_AW_CONTAINER:-mozart_aw_052}"

records="$OUT/records"
n_driven=0
n_bagged=0
if [ -d "$records" ]; then
  n_driven=$(find "$records" -maxdepth 1 -mindepth 1 -type d | wc -l)
  # A scenario counts as measured only if it left a .db3. The distinction
  # matters: a run that launched and produced nothing grades as "no violations"
  # and is indistinguishable from a clean drive unless counted separately.
  n_bagged=$(find "$records" -name '*.db3' | wc -l)
fi
printf 'scenarios driven      %s\n' "$n_driven"
printf 'scenarios with a bag  %s\n' "$n_bagged"
if [ "$n_driven" -gt 0 ] && [ "$n_bagged" -lt "$n_driven" ]; then
  printf 'MISSING BAGS          %s -- these were NOT measured; see records/*/run.log\n' \
    "$((n_driven - n_bagged))"
fi

# A bag with zero route messages means Autoware never accepted the generated
# start/goal pair: the ego never drove, every oracle was gated off, and the
# scenario contributed nothing but wall clock. Counting these separately is the
# difference between "the ADS handled 300 scenarios cleanly" and "half of them
# never moved". Read from metadata.yaml so it costs nothing.
n_unrouted=0
if [ -d "$records" ]; then
  while IFS= read -r meta; do
    # message_count follows the topic name by a variable number of lines (the
    # qos blob sits between them), so scan forward to the first one rather than
    # assuming an offset. `name:` must be matched exactly -- there are a dozen
    # /planning/mission_planning/route* topics and the sibling
    # route_selector/mrm/route is also always 0.
    count=$(awk '
      $1 == "name:" && $2 == "/planning/mission_planning/route" { found = 1; next }
      found && $1 == "message_count:" { print $2; exit }
    ' "$meta" 2>/dev/null)
    [ "${count:-1}" = 0 ] && n_unrouted=$((n_unrouted+1))
  done < <(find "$records" -name metadata.yaml 2>/dev/null)
fi
if [ "$n_unrouted" -gt 0 ]; then
  printf 'NEVER ROUTED          %s -- mission planner refused the start/goal; ego never drove\n' \
    "$n_unrouted"
fi

viol="$OUT/violations"
if [ -d "$viol" ]; then
  echo
  echo "violations by type (unique scenarios in parentheses):"
  shopt -s nullglob
  for csv in "$viol"/*.csv; do
    name=$(basename "$csv" .csv)
    rows=$(( $(wc -l < "$csv") - 1 ))
    uniq=$(tail -n +2 "$csv" | cut -d, -f1 | sort -u | wc -l)
    printf '  %-20s %5s (%s)\n' "$name" "$rows" "$uniq"
  done
  shopt -u nullglob

  # Clustering needs scikit-learn and pandas, which live in the container.
  if docker inspect "$C" >/dev/null 2>&1 && [ -d "$HERE/src" ]; then
    echo
    echo "clusters (kneed/DBSCAN over the violation features):"
    docker exec "$C" bash -lc "
      source /opt/autoware/setup.bash 2>/dev/null
      cd /scenorita/src && python3 - <<'PY' 2>/dev/null || echo '  (clustering unavailable)'
import sys
from pathlib import Path
sys.path.insert(0, '.')
from mylib.clustering import cluster
d = Path('/scenorita/${OUT#$HERE/}/violations')
for csv in sorted(d.glob('*.csv')):
    try:
        df = cluster(csv)
        print(f\"  {csv.stem:<20} {len(df):>5} in {df['cluster'].nunique()} clusters\")
    except Exception as e:
        print(f'  {csv.stem:<20} clustering failed: {e}')
PY"
  fi
else
  echo
  echo "no violations directory -- nothing violated, or nothing was measured"
fi
