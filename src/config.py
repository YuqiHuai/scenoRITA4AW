"""Paths and execution settings.

scenoRITA runs INSIDE the Autoware container (`mozart_aw_052`), not on the host.
That is the point of the 0.52.0 port: the v1.0 layout needed a host `colcon
build` of Autoware plus a second "reduced" build to get lanelet2 and the
Autoware messages into the host Python. Both now come from the image, so there
is nothing to build and nothing to keep in sync.

Every path below is a path inside that container. All of them are bind mounts
from the host, so `out/` survives `docker rm` and editing this file on the host
takes effect on the next scenario.
"""
import os
from pathlib import Path

PROJECT_NAME = "scenoRITA_autoware_v1"

LOGGING_PREFIX_REGEX = (
    "^(?P<severity>[DIWEF])(?P<month>\d\d)(?P<day>\d\d) "
    "(?P<hour>\d\d):(?P<minute>\d\d):(?P<second>\d\d)\.(?P<microsecond>\d\d\d) "
    "(?P<filename>[a-zA-Z<][\w._<>-]+):(?P<line>\d+)"
)
LOGGING_FORMAT = (
    "<level>{level.name[0]}{time:MMDD}</level> "
    "<green>{time:HH:mm:ss.SSS}</green> "
    "<cyan>{file}:{line}</cyan>] "
    "<bold>{message}</bold>"
)

# ENVIRONMENT SETTINGS
DOCKER_CONTAINER_NAME = os.environ.get("MOZART_AW_CONTAINER", "mozart_aw_052")

# One container, and not a tunable. v1.0 ran CONTAINER_NUM=3 in parallel; this
# harness measured that Autoware under CPU contention does not merely run
# slower, it *plans differently* -- so a parallel campaign trades the validity
# of its own results for wall clock. The stack is ~500% CPU on its own.
CONTAINER_NUM = 1

# How long a scenario may run, in SIMULATED seconds. Written into every
# generated scenario as the StopTrigger's SimulationTimeCondition; the scenario
# ends earlier when the ego reaches its goal.
#
# This was hardcoded to 180 in open_scenario.py. v1.0 could not actually use it:
# ScenarioReplayer killed the rosbag recorder after MAX_RECORD_TIME (60 s), so
# the observation window was 60 s no matter what the scenario said. Nothing kills
# the recorder now, so the scenario really does get its full duration.
SCENARIO_DURATION = int(os.environ.get("SCENARIO_DURATION", "180"))

# Wall-clock ceiling for one scenario, passed to SSv2 as global_timeout.
#
# MUST EXCEED SCENARIO_DURATION plus startup, and it is derived rather than set
# so it cannot silently fall behind. Getting this wrong is invisible: a
# global_timeout below the scenario's own duration truncates every long scenario
# at the timeout, and a truncated run looks exactly like one that ended
# normally. It happened here -- a 150 s timeout against a 180 s scenario
# produced a 154.0 s bag that read as a complete run.
#
# Startup to WaitingForRoute is ~20 s measured; 60 s of headroom covers that
# plus the concealer's initialise handshake.
SCENARIO_TIMEOUT = int(os.environ.get("SCENARIO_TIMEOUT", str(SCENARIO_DURATION + 60)))
if SCENARIO_TIMEOUT <= SCENARIO_DURATION:
    raise ValueError(
        f"SCENARIO_TIMEOUT ({SCENARIO_TIMEOUT}) must exceed SCENARIO_DURATION "
        f"({SCENARIO_DURATION}) plus startup, or every long scenario is "
        "truncated and the truncation is indistinguishable from a normal end"
    )


PROJECT_ROOT = os.environ.get("SCENORITA_ROOT", str(Path(__file__).parent.parent))

# The map corpus, mounted read-only. Slug-named directories each holding
# lanelet2_map.osm + pointcloud_map.pcd + map_projector_info.yaml -- exactly the
# layout MapLoader and OpenScenario's RoadNetwork already expected.
ADS_MAP_DIR = os.environ.get("ADS_MAP_DIR", "/autoware_map")
SUPPORTED_MAPS = sorted(
    x.name for x in Path(ADS_MAP_DIR).iterdir()
    if x.is_dir() and (x / "lanelet2_map.osm").exists()
) if Path(ADS_MAP_DIR).is_dir() else []

# The harness script that drives one scenario. NOT reimplemented here: it
# carries the DDS participant ceiling, the verified stack kill, the renamed
# trajectory topic and the overlay/coverage sourcing, every one of which was
# paid for in a wrong answer. See harness/ssv2/README.md in MozartTest-Autoware.
RUN_SCENARIO_SH = os.environ.get("RUN_SCENARIO_SH", "/mozart/harness/ssv2/run_scenario.sh")

# Which Autoware to drive. Defaults match run_scenario.sh's own: the instrumented
# overlay at /aw_ws (the /planning/module_activation beacon). USE_OVERLAY=0 gives
# the stock /opt/autoware stack; COVERAGE=1 gives the gcov build at
# /ss2_ws/cov_ws, so a campaign accumulates line coverage as it searches.
USE_OVERLAY = os.environ.get("USE_OVERLAY", "1")
COVERAGE = os.environ.get("COVERAGE", "0")
# ALL_MODULES=1 turns on the eleven planning modules the default preset leaves
# off. Without it a scenario aimed at one of them covers nothing at all.
ALL_MODULES = os.environ.get("ALL_MODULES", "0")
