"""Play one scenario and leave its rosbag where the analyzer expects it.

v1.0 launched scenario_test_runner itself, polled the process, called
`stop_recorder.sh` when MAX_RECORD_TIME elapsed, then moved the bag out of
`/tmp/scenario_test_runner`. Three of those four steps are gone: run_scenario.sh
owns the launch and the timeout, and SSv2 is told where to write directly, so
nothing has to be moved out of /tmp afterwards -- which also means a container
restart can no longer lose a finished run's bag.
"""
import shutil
from pathlib import Path

from autoware.open_scenario import OpenScenario
from utils import get_output_dir


def scenario_out_dir(scenario_id: str) -> Path:
    """Where run_scenario.sh is told to put this scenario's output."""
    return Path(get_output_dir(), "records", scenario_id)


def record_dir(scenario_id: str) -> Path:
    """The rosbag directory itself.

    scenario_test_runner nests output as
    <out>/scenario_test_runner/<scenario name>/<scenario name>/, with the .db3
    and metadata.yaml in the innermost directory. The analyzer needs that
    innermost path, not the root we passed in.
    """
    return Path(scenario_out_dir(scenario_id), "scenario_test_runner", scenario_id, scenario_id)


def replay_scenario(scenario: OpenScenario, container) -> bool:
    """Drive one scenario. True if it produced a readable bag.

    A missing bag is reported as a failure rather than an empty result: an
    infrastructure failure that grades as "no violations" is indistinguishable
    from a scenario the ADS handled correctly, and over a 12-hour campaign that
    silently biases the search toward whatever was breaking.
    """
    sce_id = scenario.get_id()
    out_dir = scenario_out_dir(sce_id)
    # Runs are re-driven when a generation is re-evaluated; a stale bag from a
    # previous attempt at the same id would otherwise be graded as this one's.
    if out_dir.exists():
        shutil.rmtree(out_dir, ignore_errors=True)

    scenario_path = Path(get_output_dir(), "input", f"{sce_id}.yaml")
    container.run_scenario(scenario_path, out_dir, log_path=Path(out_dir, "run.log"))

    bag = record_dir(sce_id)
    return bag.is_dir() and any(bag.glob("*.db3"))
