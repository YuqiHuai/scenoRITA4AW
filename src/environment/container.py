"""Driving one scenario.

This replaces the v1.0 `Container` class, which started its own containers with
`docker run`, installed Autoware into them, copied a generated `run_scenario_N.sh`
in, and killed processes by pattern. All of that is now
`harness/ssv2/run_scenario.sh` in MozartTest-Autoware, which scenoRITA calls.

The name `Container` is kept because `main.py` and `mylib/workers.py` speak in
those terms, but there is no container management left here: scenoRITA already
runs inside the one container, and `run_scenario.sh` detects that and executes
directly instead of via `docker exec`.

Why call out to a shell script instead of porting its logic here: the script is
almost entirely scar tissue -- the CycloneDDS participant ceiling, the
kill-and-verify loop, the renamed final-trajectory topic, the overlay sourcing
order that makes pluginlib resolve the instrumented modules. A Python
reimplementation would be a second copy of that knowledge, and the copy would
drift silently. The sweeps and scenoRITA now drive the same file.
"""
import os
import subprocess
from pathlib import Path
from typing import Optional

from config import (
    ALL_MODULES,
    COVERAGE,
    DOCKER_CONTAINER_NAME,
    MAX_RECORD_TIME,
    RUN_SCENARIO_SH,
    SCENARIO_TIMEOUT,
    USE_OVERLAY,
)


class Container:
    """One Autoware stack. Serial by construction -- see CONTAINER_NUM."""

    def __init__(self, ctn_name: str = DOCKER_CONTAINER_NAME, ctn_id: str = "0") -> None:
        self.ctn_name = ctn_name
        self.ctn_id = ctn_id

    @property
    def container_name(self) -> str:
        return self.ctn_name

    def is_running(self) -> bool:
        """We are inside it. If we are executing, it is running."""
        return True

    # Kept as no-ops so the worker code reads the same as before. The real
    # stack kill lives in run_scenario.sh, which does it both before AND after
    # every scenario and *verifies* it -- a fire-and-forget pkill here was what
    # let leaked stacks shadow later launches.
    def start_instance(self, restart: bool = False) -> None:
        return None

    def env_init(self) -> None:
        return None

    def setup_env(self) -> None:
        return None

    def kill_process(self) -> None:
        return None

    def run_scenario(self, scenario_path: Path, out_dir: Path,
                     log_path: Optional[Path] = None) -> int:
        """Drive one scenario to completion. Returns the script's exit code.

        `out_dir` is where scenario_test_runner writes result.junit.xml and the
        rosbag; it must be a path that exists inside the container, which every
        path under PROJECT_ROOT is.
        """
        env = dict(os.environ)
        env.update(
            OUT=str(out_dir),
            GLOBAL_TIMEOUT=str(SCENARIO_TIMEOUT),
            RECORD="true",
            USE_OVERLAY=USE_OVERLAY,
            COVERAGE=COVERAGE,
            ALL_MODULES=ALL_MODULES,
            MOZART_AW_CONTAINER=self.ctn_name,
        )
        out_dir.mkdir(parents=True, exist_ok=True)
        log = open(log_path, "w") if log_path else subprocess.DEVNULL
        try:
            # `timeout` is a backstop only: run_scenario.sh already passes
            # SCENARIO_TIMEOUT to SSv2 as global_timeout. This catches the case
            # where the launch itself wedges before SSv2 can enforce anything,
            # which would otherwise stall a 12-hour campaign indefinitely.
            return subprocess.call(
                ["/bin/bash", RUN_SCENARIO_SH, str(scenario_path)],
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=SCENARIO_TIMEOUT + MAX_RECORD_TIME + 180,
            )
        except subprocess.TimeoutExpired:
            return -1
        finally:
            if log_path:
                log.close()
