# scenoRITA for Autoware Universe 0.52.0

A genetic search for ADS violations: it generates OpenSCENARIO scenarios against
an HD map, drives them through Autoware, grades the resulting rosbag with four
oracles (collision, speeding, unsafe lane change, comfort), and evolves the
obstacle set toward whatever violates.

This branch runs against **Autoware 0.52.0 inside a container**. There is no
host build. The v1.0 instructions -- `vcs import`, `colcon build`, a second
"reduced Autoware" checkout to get lanelet2 into the host Python, `rocker`,
three parallel containers -- are all gone. See [PORTING.md](PORTING.md) for what
changed and why.

## From a fresh machine to a running experiment

Docker is the only prerequisite. Clone the two repositories side by side, then
two scripts:

```bash
git clone <MozartTest-Autoware>          # the harness, maps and container
git clone <scenoRITA4AW>                 # this repo -- side by side, not nested

cd scenoRITA4AW
./setup_scenorita_container.sh                                  # ~15 min, once
./run_scenorita_experiment.sh --map sample-map-planning --hours 12
```

Nothing is built or installed on the host. No Autoware checkout, no ROS, no
`colcon`, no Poetry environment -- `python3 src/main.py` is not a supported way
to start this and will not work from the host.

`setup_scenorita_container.sh` does five things, each skipped when already done,
so re-running after a failure costs only the step that failed:

| | | |
|---|---|---|
| 1 | map corpus | fetches the point clouds for the vector maps committed in the harness repo (`--all-maps` for all 64) |
| 2 | container | creates `mozart_aw_052` from the pinned image, with this repo mounted at `/scenorita` |
| 3 | scenario_simulator_v2 | builds SSv2 against the installed 0.52.0, ~6 min |
| 4 | coverage build | **skipped unless `--with-coverage`**, ~20 min |
| 5 | dependencies | installs scenoRITA's Python packages, pinned, and verifies every import |

Add `--with-coverage` only if you intend to run `COVERAGE=1`; scenoRITA grades
from the rosbag and needs neither the activation beacon nor the gcov build for
an ordinary campaign.

It calls `MozartTest-Autoware/harness/ssv2/setup_container.sh`, which owns the
image, the map corpus and the two colcon workspaces, passing it the `/scenorita`
mount; then it installs the Python packages that are ours. Those used to be
installed by that script and are not any more -- a container shared by several
tools cannot carry one tool's dependency list in another tool's setup. Their
pins are load-bearing (see the script), so they moved here rather than being
dropped.

## Running an experiment

```bash
./run_scenorita_experiment.sh                                  # 12 h, sample-map-planning
./run_scenorita_experiment.sh --map ces2024_demo --hours 12
COVERAGE=1 ./run_scenorita_experiment.sh --hours 12            # + line coverage
```

| flag | default | |
|---|---|---|
| `--map` | `sample-map-planning` | any of the 64 under `/autoware_map` |
| `--hours` | `12` | wall-clock budget for the search |
| `--num-scenario` | `20` | scenarios per generation |
| `--min-obs` / `--max-obs` | `5` / `15` | obstacles per scenario |
| `--id` | timestamp | experiment id, and the output directory name |

Environment: `COVERAGE=1` drives the gcov build and reports line coverage at the
end (needs `--with-coverage` at setup); `USE_OVERLAY=1` drives the instrumented
overlay instead of stock `/opt/autoware`; `ALL_MODULES=0` leaves the eleven
non-default planning modules off.

The default is **stock Autoware**. The instrumented overlay exists to publish
`/planning/module_activation`, which scenoRITA does not read -- it grades from
the rosbag -- so driving stock keeps a campaign one build closer to the release
under test.

Everything lands in `out/<id>_<map>/`:

```
experiment.txt      what was run, which Autoware, which revisions -- written before the run
campaign.log        the full log
input/              every scenario generated, as OpenSCENARIO YAML
records/<sce_id>/   that scenario's rosbag, junit result and run.log
violations/         a copy of each violating record, plus one CSV per violation type
```

Re-summarise a finished or interrupted run without re-driving it:

```bash
./analyze_experiment.sh out/0906_143000_sample-map-planning
```

## What runs where

```
host                                container (mozart_aw_052)
----                                -------------------------
run_scenorita_experiment.sh   -->   src/main.py            the GA loop
  restarts a wedged container         generate  (lanelet2)
  decides when time is up             drive     --> /mozart/harness/ssv2/run_scenario.sh
  summarises the result               grade     (rosbag2 + Autoware msgs)
```

The search runs **inside** the container because that is the only place lanelet2
and the Autoware message packages exist. The host keeps the two jobs the search
cannot do from in there: restarting the container when a stack wedges (`main.py`
exits `17` to ask for it) and owning the experiment's wall clock.

Scenarios are driven by `harness/ssv2/run_scenario.sh` from MozartTest-Autoware
rather than by a launcher here. That script carries the CycloneDDS participant
ceiling, the kill-and-verify loop for leaked stacks, the renamed final-trajectory
topic and the overlay sourcing order -- each of which was paid for in a wrong
answer, and none of which should exist in two places.

## One container, on purpose

v1.0 ran `CONTAINER_NUM=3` in parallel. This harness measured that Autoware under
CPU contention does not merely run slower, it *plans differently*, so a parallel
campaign trades the validity of its own results for wall clock. For the same
reason a generation is evaluated in three phases -- generate everything, drive
one at a time with the machine otherwise quiet, then grade in parallel once no
stack is running -- rather than as a pipeline.

Budget roughly **20-25 scenarios per hour**, so a 12-hour campaign is on the
order of 250-300 scenarios, or 12-15 generations at the default 20 per
generation.

## Which simulator

scenario_simulator_v2, via `scenario_test_runner`. SSv2 launches Autoware
through a file called `planning_simulator.launch.xml`, which is confusing but is
just Autoware's launch entry point -- the simulator is SSv2's
`simple_sensor_simulator`, and `scenario_simulation:=true` turns Autoware's own
dummy perception and dummy vehicle off.

`data/config_files/planning_simulator.launch.xml` is the **v1.0-era** copy of
that file and is kept for reference only. Nothing reads it, and it must not be
copied over the image's: against 0.52.0 it is a downgrade, missing
`use_sim_time`, `localization_sim_mode`, `enable_all_modules_auto_mode` and
more.

## Notes

See [NOTES.md](NOTES.md) for the design notes carried over from v1.0 (traffic
rules, obstacle constraints, ego generation), and [PORTING.md](PORTING.md) for
the 0.52.0 delta.
