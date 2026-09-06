#!/bin/bash
# Bring a fresh machine to the point where an experiment can run. One command.
#
#   ./setup_scenorita_container.sh                  # ~15 min, sample maps
#   ./setup_scenorita_container.sh --all-maps       # all 64 maps, bigger download
#   ./setup_scenorita_container.sh --with-coverage  # + the gcov build (~20 min more)
#
# Then:
#
#   ./run_scenorita_experiment.sh --map sample-map-planning --hours 12
#
# Every step is idempotent and skipped when already done, so re-running after a
# failure costs only the step that failed. `--force-rebuild` redoes them anyway.
#
# Most of the work is not scenoRITA's: the map corpus, the container and the
# scenario_simulator_v2 build all belong to MozartTest-Autoware, and this script
# calls that repository's own scripts rather than reimplementing them. What it
# owns is the /scenorita bind mount and scenoRITA's Python dependencies -- both
# of which have to be applied at container-create time, since a mount cannot be
# added to a running container and pip installs land in the writable layer that
# `docker rm` destroys.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOZART="${MOZART_REPO:-$HERE/../MozartTest-Autoware}"
C="${MOZART_AW_CONTAINER:-mozart_aw_052}"

ALL_MAPS=0
WITH_COVERAGE=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --all-maps) ALL_MAPS=1 ;;
    --with-coverage) WITH_COVERAGE=1 ;;
    --force-rebuild) FORCE=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

[ -d "$MOZART/harness/ssv2" ] || {
  echo "MozartTest-Autoware not found at $MOZART" >&2
  echo "Clone it next to this repo:" >&2
  echo "  git clone <MozartTest-Autoware> $(dirname "$HERE")/MozartTest-Autoware" >&2
  echo "...or set MOZART_REPO to where it is." >&2
  exit 1; }
command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 1; }

step() { printf '\n=== %s ===\n' "$1"; }

# --------------------------------------------------------------------- maps --
# The vector maps are committed in MozartTest-Autoware; the point clouds are
# not, and are fetched and cached. Must happen before the container is created,
# because the assembled tree is bind-mounted at /autoware_map.
step "1/5  map corpus"
if [ "$FORCE" = 1 ] || [ ! -d "$MOZART/.map_runnable" ]; then
  if [ "$ALL_MAPS" = 1 ]; then
    "$MOZART/scripts/fetch_pointclouds.sh" --all
  else
    "$MOZART/scripts/fetch_pointclouds.sh"
  fi
else
  echo "  already assembled at $MOZART/.map_runnable ($(find "$MOZART/.map_runnable" -maxdepth 1 -mindepth 1 -type d | wc -l) maps); --force-rebuild to redo"
fi

# ---------------------------------------------------------------- container --
step "2/5  container"
EXTRA_MOUNTS="$HERE:/scenorita" "$MOZART/harness/ssv2/setup_container.sh"

# --------------------------------------------------------------------- SSv2 --
# scenario_simulator_v2 built against the installed 0.52.0. This is the
# simulator; without it `source /ss2_ws/install/setup.bash` fails and every
# scenario dies before Autoware starts. The workspace is a bind mount, so this
# survives the container recreate above and only runs once per machine.
step "3/5  scenario_simulator_v2"
if [ "$FORCE" = 1 ] || ! docker exec "$C" test -d /ss2_ws/install; then
  echo "  building (~6 min, 33 packages)"
  "$MOZART/harness/ssv2/build_ssv2.sh"
  docker exec "$C" test -d /ss2_ws/install || {
    echo "build_ssv2.sh finished but /ss2_ws/install does not exist" >&2
    echo "(it exits 0 even on failure -- check its output above)" >&2
    exit 1; }
else
  echo "  already built at /ss2_ws/install; --force-rebuild to redo"
fi

# ----------------------------------------------------------------- coverage --
# Optional, and off by default: scenoRITA grades from the rosbag, so it needs
# neither the activation beacon nor the gcov build. Only worth the ~20 minutes
# if you intend to run COVERAGE=1 and get line coverage out of a campaign.
step "4/5  instrumented + coverage build"
if [ "$WITH_COVERAGE" = 1 ]; then
  # build_overlay.sh clones the autoware.universe fork (branch and commit from
  # harness/ssv2/overlay.rev) into /aw_ws/src/autoware_universe and builds it.
  #
  # The "already done" test is the CLONE AT THE PINNED COMMIT, not /aw_ws/install.
  # Those two can disagree: this machine had an /aw_ws/install from an earlier
  # hand-built overlay with no autoware_universe checkout under it at all, so
  # testing the install directory skipped the build and then
  # `coverage build` failed with "(no checkout)" -- after the setup had already
  # claimed success. `coverage build` refuses to build anything but the pinned
  # commit, so matching its own guard here is what keeps the two consistent.
  WANT=$(awk '/^commit/{print $2}' "$MOZART/harness/ssv2/overlay.rev")
  HAVE=$(docker exec "$C" git -C /aw_ws/src/autoware_universe rev-parse --short=9 HEAD 2>/dev/null || true)
  if [ "$FORCE" = 1 ] || [ "$HAVE" != "$WANT" ]; then
    echo "  overlay: have ${HAVE:-(no checkout)}, overlay.rev pins $WANT -- building"
    "$MOZART/harness/ssv2/build_overlay.sh"
  else
    echo "  overlay already at $WANT"
  fi
  if [ "$FORCE" = 1 ] || ! docker exec "$C" test -d /ss2_ws/cov_ws/install; then
    ( cd "$MOZART" && uv run mozart-autoware coverage build )
  else
    echo "  coverage build already at /ss2_ws/cov_ws/install"
  fi
else
  echo "  skipped (--with-coverage to build it)"
  echo "  without it, campaigns run against stock /opt/autoware, which is what"
  echo "  scenoRITA needs -- it grades from the rosbag, not from the beacon."
fi

# ------------------------------------------------------- scenoRITA's own deps --
# The pins are load-bearing and the failure they prevent is a quiet one.
# Unpinned, these drag in numpy 2.x, which is ABI-incompatible with the image's
# system scipy AND with the ROS 2 Python bindings: `import scipy.interpolate`
# then dies with "numpy.dtype size changed". Generation still works, so a
# campaign runs to completion producing bags and no violations at all.
#
# scikit-learn 1.3.2 is the last release built against numpy 1.x; it is only
# used for the violation clustering at the end of a run, but importing it is
# what surfaces the mismatch.
step "5/5  scenoRITA dependencies"
docker exec "$C" bash -c '
  pip3 install -q "numpy<1.25" "scikit-learn==1.3.2" \
    shapely deap nanoid loguru absl-py ruamel.yaml kneed networkx
' >/dev/null

# Fail here rather than three minutes into the first scenario. Checking the
# imports is the point: the pins above are exactly what a successful
# `pip3 install` can still get wrong.
docker exec "$C" bash -lc '
  source /opt/autoware/setup.bash
  source /ss2_ws/install/setup.bash
  python3 - <<PY
import sys
bad = []
for m in ("numpy", "scipy.interpolate", "sklearn", "shapely", "deap", "nanoid",
          "loguru", "absl", "ruamel.yaml", "kneed", "networkx", "lanelet2",
          "rclpy", "rosidl_runtime_py", "openscenario_utility.conversion"):
    try:
        __import__(m)
    except Exception as e:
        bad.append(f"{m}: {type(e).__name__}: {e}")
for m, a in (("autoware_lanelet2_extension_python.projection", "MGRSProjector"),
             ("autoware_perception_msgs.msg", "TrackedObjects")):
    try:
        getattr(__import__(m, fromlist=[a]), a)
    except Exception as e:
        bad.append(f"{m}.{a}: {type(e).__name__}: {e}")
if bad:
    print("\n".join("  " + b for b in bad), file=sys.stderr)
    sys.exit(1)
import numpy
print(f"  numpy {numpy.__version__}, and every scenoRITA import resolves")
PY'

# Run scenoRITA's own preflight as the final gate, so setup and run agree on
# what "ready" means instead of each having its own idea.
docker exec "$C" bash -lc '
  source /opt/autoware/setup.bash
  source /ss2_ws/install/setup.bash
  cd /scenorita/src && python3 prepare.py'

cat <<EOF

Ready. Start an experiment with:

  ./run_scenorita_experiment.sh --map sample-map-planning --hours 12
EOF
[ "$WITH_COVERAGE" = 1 ] && echo "  COVERAGE=1 ./run_scenorita_experiment.sh --hours 12   # + line coverage"
exit 0
