#!/bin/bash
# Create the container a scenoRITA campaign runs in.
#
#   ./setup_scenorita_container.sh
#
# This is the whole installation: nothing is built and nothing is installed on
# the host. It calls MozartTest-Autoware's harness/ssv2/setup_container.sh --
# which owns the pinned image, the map mount and the two colcon workspaces --
# adding the one mount and the Python packages that are ours.
#
# Those packages used to be installed by that script. They are not any more:
# a container shared by several tools cannot have one tool's dependency list
# baked into the other tool's setup, and the symptom when it did was invisible
# from here. Their pins are load-bearing, so they moved here rather than being
# dropped.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOZART="${MOZART_REPO:-$HERE/../MozartTest-Autoware}"
C="${MOZART_AW_CONTAINER:-mozart_aw_052}"

[ -x "$MOZART/harness/ssv2/setup_container.sh" ] || {
  echo "MozartTest-Autoware not found at $MOZART -- set MOZART_REPO" >&2; exit 1; }

# EXTRA_MOUNTS is that script's hook for exactly this: a mount cannot be added
# to an existing container, so it has to be present at `docker run` time.
EXTRA_MOUNTS="$HERE:/scenorita" "$MOZART/harness/ssv2/setup_container.sh"

# The pins are not cosmetic. Unpinned, pip drags in numpy 2.x, which is
# ABI-incompatible with this image's system scipy AND with the ROS 2 Python
# bindings: `import scipy.interpolate` then dies with "numpy.dtype size
# changed", so grading fails on every scenario while generation keeps working
# -- a campaign that produces bags and no violations. scikit-learn is pinned to
# the last release built against numpy 1.x, for the violation clustering at the
# end of a run.
echo "[deps] installing scenoRITA's Python packages in $C"
docker exec "$C" pip3 install -q \
  "numpy<1.25" "scikit-learn==1.3.2" \
  shapely deap nanoid loguru absl-py ruamel.yaml kneed networkx

# Import them rather than trust pip's exit code: a resolver that silently
# settled on numpy 2.x would still exit 0, and the first sign otherwise is a
# campaign with no violations hours later.
docker exec "$C" python3 -c '
import numpy, scipy.interpolate, sklearn
import shapely, deap, nanoid, loguru, absl, ruamel.yaml, kneed, networkx
assert numpy.__version__ < "1.25", numpy.__version__
print(f"[deps] ok: numpy {numpy.__version__}, scikit-learn {sklearn.__version__}")'

echo "container $C ready for scenoRITA; next: ./run_scenorita_experiment.sh"
