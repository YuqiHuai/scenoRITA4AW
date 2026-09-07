#!/bin/bash
# Run one scenoRITA experiment end to end, on the host, and leave a directory
# that is the whole record of it.
#
#   ./run_scenorita_experiment.sh                            # 12 h, sample-map-planning
#   ./run_scenorita_experiment.sh --map ces2024_demo --hours 12
#   COVERAGE=1 ./run_scenorita_experiment.sh --hours 12      # + line coverage
#
# This is the only entry point. `poetry run python3 src/main.py` no longer works
# from the host and is not supposed to: scenoRITA needs lanelet2 and the
# Autoware message packages, which exist only inside the container. This script
# is the host half -- it owns the two things the search cannot do from inside,
# namely restarting a wedged container and deciding when the experiment is over.
#
# Everything it produces lands under out/<experiment id>/ in this repo, which is
# bind-mounted into the container, so a 12-hour campaign survives `docker rm`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${MOZART_AW_CONTAINER:-mozart_aw_052}"
MOZART="${MOZART_REPO:-$HERE/../MozartTest-Autoware}"

MAP="sample-map-planning"
HOURS="12"
NUM_SCENARIO="20"
MIN_OBS="5"
MAX_OBS="15"
EXP_ID="$(date +%m%d_%H%M%S)"
# A wedged stack is recoverable, but only from out here. main.py exits 17 when
# three consecutive generations could not be fully evaluated; each retry
# restarts the container and starts a fresh run rather than resuming, because
# the GA population is in memory and half of it would be graded against a
# broken stack.
MAX_RESTARTS="${MAX_RESTARTS:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --map) MAP="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    --num-scenario) NUM_SCENARIO="$2"; shift 2 ;;
    --min-obs) MIN_OBS="$2"; shift 2 ;;
    --max-obs) MAX_OBS="$2"; shift 2 ;;
    --id) EXP_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

COVERAGE="${COVERAGE:-0}"
# The instrumented overlay by default, when it is built.
#
# scenoRITA's own grading does not need it -- the oracles read the rosbag. What
# needs it is analysing a campaign afterwards for WHICH planning behaviours
# activated: /planning/module_activation is the only uniform signal across both
# planning layers. virtual_wall and planning_factors cover behavior_velocity
# only; behavior_path publishes no module status, so on stock Autoware there is
# no way to tell whether goal_planner, lane_change or start_planner ever ran.
#
# Falls back to stock rather than failing when the overlay was not built
# (setup --no-overlay), because a campaign without activation data is still a
# valid campaign -- but say so, since the difference is invisible in the bags
# until someone goes looking for a topic that is not there.
USE_OVERLAY="${USE_OVERLAY:-1}"
if [ "$USE_OVERLAY" = 1 ] && [ "$COVERAGE" != 1 ] \
   && ! docker exec "$C" test -d /aw_ws/install 2>/dev/null; then
  echo "note: no overlay at /aw_ws/install -- driving stock /opt/autoware." >&2
  echo "      behavior_path module activation will NOT be recorded." >&2
  echo "      run ./setup_scenorita_container.sh to build it." >&2
  USE_OVERLAY=0
fi
ALL_MODULES="${ALL_MODULES:-1}"

OUT_HOST="$HERE/out/${EXP_ID}_${MAP}"
mkdir -p "$OUT_HOST"
MANIFEST="$OUT_HOST/experiment.txt"

# ---------------------------------------------------------------- preflight --
# Each of these fails silently or misleadingly hours later if not checked now.
docker inspect "$C" >/dev/null 2>&1 || {
  echo "container $C does not exist -- run ./setup_scenorita_container.sh" >&2
  exit 1; }
[ -d "$MOZART/harness/ssv2" ] || {
  echo "MozartTest-Autoware not found at $MOZART -- set MOZART_REPO" >&2; exit 1; }

# The container must see BOTH repos. A container created before these mounts
# existed looks healthy and then fails on the first scenario, so check the
# mounts rather than the container's existence.
for m in /scenorita/src/main.py /mozart/harness/ssv2/run_scenario.sh /autoware_map; do
  docker exec "$C" test -e "$m" 2>/dev/null || {
    echo "$C cannot see $m -- recreate it with ./setup_scenorita_container.sh" >&2
    exit 1; }
done

# scenario_simulator_v2 itself. Without it `source /ss2_ws/install/setup.bash`
# fails and every scenario dies before Autoware starts -- 12 hours of records
# that are all empty. It is a bind mount, so it can be absent on a container
# that otherwise looks perfectly healthy.
docker exec "$C" test -d /ss2_ws/install || {
  echo "no scenario_simulator_v2 build at /ss2_ws/install -- run ./setup_scenorita_container.sh" >&2
  exit 1; }

docker exec "$C" test -d "/autoware_map/$MAP" || {
  echo "no map '$MAP' under /autoware_map; available:" >&2
  docker exec "$C" ls /autoware_map >&2; exit 1; }

if [ "$COVERAGE" = 1 ]; then
  docker exec "$C" test -d /ss2_ws/cov_ws/install || {
    echo "COVERAGE=1 but no build at /ss2_ws/cov_ws -- run ./setup_scenorita_container.sh --with-coverage" >&2
    exit 1; }
  # Zero ONCE, here, and tell run_scenario.sh not to. Its own zeroing is
  # per-scenario, which for a campaign that reports once at the end means the
  # report covers only the last scenario driven -- a number indistinguishable
  # from the campaign's own, and far smaller.
  docker exec "$C" bash -c     'source /opt/autoware/setup.bash
     lcov --directory /ss2_ws/cov_ws/build --zerocounters -q 2>/dev/null; true'
  echo "coverage counters zeroed once for the whole campaign"
fi

# ----------------------------------------------------------------- manifest --
# Written BEFORE the run, so an interrupted campaign still says what it was.
# Which Autoware was driven is the thing most easily lost and most needed when
# comparing two campaigns months apart.
{
  echo "experiment_id   $EXP_ID"
  echo "started         $(date -Is)"
  echo "map             $MAP"
  echo "hours           $HOURS"
  echo "scenarios/gen   $NUM_SCENARIO"
  echo "obstacles       $MIN_OBS-$MAX_OBS"
  echo "container       $C"
  echo "image           $(docker inspect -f '{{.Image}}' "$C")"
  echo "stack           $([ "$COVERAGE" = 1 ] && echo 'coverage build (/ss2_ws/cov_ws)' \
                          || { [ "$USE_OVERLAY" = 1 ] && echo 'instrumented overlay (/aw_ws)' \
                          || echo 'stock (/opt/autoware)'; })"
  echo "all_modules     $ALL_MODULES"
  echo "scenorita_rev   $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "mozart_rev      $(git -C "$MOZART" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} | tee "$MANIFEST"
echo

# ---------------------------------------------------------------------- run --
attempt=0
status=0
while :; do
  attempt=$((attempt+1))
  echo "=== scenoRITA $EXP_ID (attempt $attempt) -- $HOURS h on $MAP ==="
  set +e
  # Run as the invoking user, not root. `out/` is a bind mount of this repo, so
  # a root-owned campaign leaves 12 hours of records the user cannot delete or
  # move without sudo -- and the next run's cleanup fails on them. The image's
  # `aw` user is uid 1000, which is the usual host uid here, but pass the real
  # one rather than assuming.
  docker exec --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e ADS_MAP_DIR=/autoware_map \
    -e COVERAGE="$COVERAGE" -e COVERAGE_ZERO=0 \
    -e USE_OVERLAY="$USE_OVERLAY" -e ALL_MODULES="$ALL_MODULES" \
    -e PYTHONUNBUFFERED=1 \
    "$C" bash -lc "
      set -e
      # No \`set -u\`: /opt/autoware/setup.bash reads COLCON_TRACE unset.
      source /opt/autoware/setup.bash
      # SSv2's own messages: the recorded bag names ~830 topic types and the
      # reader resolves what it can, but sourcing this keeps the analyzer from
      # skipping topics it could have read.
      source /ss2_ws/install/setup.bash
      cd /scenorita/src
      exec python3 main.py \
        --map='$MAP' \
        --execution_id='$EXP_ID' \
        --num_hour='$HOURS' \
        --num_scenario='$NUM_SCENARIO' \
        --min_obs='$MIN_OBS' --max_obs='$MAX_OBS'
    " 2>&1 | tee -a "$OUT_HOST/campaign.log"
  status=${PIPESTATUS[0]}
  set -e

  [ "$status" != 17 ] && break
  if [ "$attempt" -gt "$MAX_RESTARTS" ]; then
    echo "stack wedged $attempt times -- giving up" | tee -a "$OUT_HOST/campaign.log"
    break
  fi
  echo "stack wedged; restarting $C and starting a fresh run" | tee -a "$OUT_HOST/campaign.log"
  docker restart "$C" >/dev/null
  docker exec "$C" bash -c 'until [ -f /opt/autoware/setup.bash ]; do sleep 1; done'
done

# ------------------------------------------------------------------ analyse --
echo
echo "=== results ==="
"$HERE/analyze_experiment.sh" "$OUT_HOST" | tee -a "$MANIFEST"

if [ "$COVERAGE" = 1 ]; then
  echo
  echo "=== coverage ==="
  # The union over every scenario this campaign drove: counters were zeroed
  # once in the preflight above, and run_scenario.sh was told (COVERAGE_ZERO=0)
  # not to zero them again per scenario.
  # `mozart-autoware` is that repo's uv project script: on PATH only if its
  # venv happens to be active, which it is not for a campaign started from
  # here. Fall back to `uv run`, or the report -- the whole point of
  # COVERAGE=1 -- is lost after the hours that produced it.
  COV=(mozart-autoware)
  command -v mozart-autoware >/dev/null 2>&1 || COV=(uv run mozart-autoware)
  ( cd "$MOZART" && "${COV[@]}" coverage report "scenorita_${EXP_ID}" ) \
    | tee -a "$MANIFEST" || echo "coverage report failed" >&2
fi

echo
echo "experiment $EXP_ID finished (exit $status); everything is under:"
echo "  $OUT_HOST"
exit "$status"
