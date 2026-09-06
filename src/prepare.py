"""Pre-flight checks.

This used to install scenoRITA into a host Autoware checkout: it rewrote a
hardcoded `/home/lori/Desktop` out of seven shell scripts, copied them into
`$ADS_ROOT/scripts`, and overwrote
`autoware_launch/launch/planning_simulator.launch.xml` with its own copy.

All of it is gone, and the launch-file overwrite is the reason to say so
loudly rather than just deleting it. `data/config_files/planning_simulator.launch.xml`
is the **v1.0-era** file. Against 0.52.0 it is not a patch, it is a downgrade:
diffing it against the file in the image shows it is missing `use_sim_time`,
`localization_sim_mode`, `enable_all_modules_auto_mode`, `launch_fault_injection`,
`control_module_preset` and `dummy_traffic_light_mode`, among others. Copying it
over the image's launch file would break SSv2's own startup path -- and
`use_sim_time` is exactly what the coverage runs depend on. The file is kept in
the repo for reference only; nothing reads it.

What replaced the scripts: `harness/ssv2/run_scenario.sh`, which scenoRITA
invokes through `environment.container.Container`.
"""
import shutil
from pathlib import Path

from config import ADS_MAP_DIR, RUN_SCENARIO_SH, SUPPORTED_MAPS


class EnvironmentError_(RuntimeError):
    pass


def init_prepare() -> None:
    """Fail fast, with the fix in the message, rather than mid-campaign.

    Every check here corresponds to a failure that is silent or misleading
    later: a missing map corpus reads as "no maps supported", a missing
    run_scenario.sh reads as every scenario failing to drive, and a missing
    lanelet2 binding reads as a crash inside the generator.
    """
    problems = []

    if not Path(ADS_MAP_DIR).is_dir():
        problems.append(
            f"no map corpus at {ADS_MAP_DIR} -- is this running inside the container? "
            "(harness/ssv2/setup_container.sh mounts it)"
        )
    elif not SUPPORTED_MAPS:
        problems.append(f"{ADS_MAP_DIR} has no directory containing lanelet2_map.osm")

    if not Path(RUN_SCENARIO_SH).is_file():
        problems.append(
            f"no scenario driver at {RUN_SCENARIO_SH} -- mount MozartTest-Autoware "
            "at /mozart, or set RUN_SCENARIO_SH"
        )

    try:
        import lanelet2  # noqa: F401
        from autoware_lanelet2_extension_python.projection import MGRSProjector  # noqa: F401
    except ImportError as e:
        problems.append(f"lanelet2 bindings unavailable ({e}) -- source /opt/autoware/setup.bash")

    try:
        from autoware_perception_msgs.msg import TrackedObjects  # noqa: F401
    except ImportError as e:
        problems.append(f"Autoware messages unavailable ({e}) -- source /opt/autoware/setup.bash")

    if shutil.which("ros2") is None:
        problems.append("ros2 not on PATH -- source /opt/autoware/setup.bash")

    if problems:
        raise EnvironmentError_(
            "environment is not ready:\n  - " + "\n  - ".join(problems)
        )


if __name__ == '__main__':
    init_prepare()
    print(f"OK: {len(SUPPORTED_MAPS)} maps under {ADS_MAP_DIR}; driver {RUN_SCENARIO_SH}")
