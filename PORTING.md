# Porting scenoRITA from Autoware Universe v1.0 to 0.52.0

What changed, and why each change was needed. Written so that the next person
reading a surprising result can tell whether it is the ADS or the port.

The headline: **the search itself did not need porting.** The scenario
generator, the genetic operators, the OpenSCENARIO writer and all four oracles
are unchanged in substance. What changed is where the code runs, two renamed
Autoware packages, and the removal of an installation procedure that on 0.52.0
would have been actively destructive.

## 1. No host build

v1.0 required, on the host: a full Autoware `vcs import` + `colcon build`, and a
second "reduced Autoware" checkout to get lanelet2 and the Autoware messages
importable from host Python. Both are gone. Everything scenoRITA needs is in the
`mozart_aw_052` image already, so the search runs inside the container.

| v1.0 | 0.52.0 |
|---|---|
| `rocker` + 3 containers, `DOCKER_IMAGE_ID` pasted into `config.py` | one container from `harness/ssv2/setup_container.sh`, pinned by digest |
| `src/prepare.py` copies 7 shell scripts into `$ADS_ROOT/scripts` | deleted; `prepare.py` is now a preflight check |
| `environment/container.py` does `docker run`/`docker network create` | `Container` is a thin wrapper over `run_scenario.sh` |
| `ScenarioReplayer` launches SSv2, polls, moves bags out of `/tmp` | `run_scenario.sh` owns the launch; SSv2 writes to the output dir directly |

## 2. Two renamed packages

Mechanical, and the only source-level API changes needed:

| v1.0 | 0.52.0 | where |
|---|---|---|
| `autoware_auto_perception_msgs` | `autoware_perception_msgs` | 5 files |
| `lanelet2_extension_python` | `autoware_lanelet2_extension_python` | `map_service.py` |

The second one matters more than it looks: it is where `MGRSProjector` lives.
Plain `lanelet2` has no MGRS projector, so without this package anything
positional has to be expressed as `LanePosition` to stay frame-independent.
scenoRITA gets the real projector back, and loads maps in the frame the
simulator runs in.

## 3. `data/config_files/planning_simulator.launch.xml` must never be installed

`prepare.py` used to copy this over
`autoware_launch/launch/planning_simulator.launch.xml`. On 0.52.0 that is not a
patch, it is a downgrade. Diffed against the file in the image, the v1.0 copy is
missing `use_sim_time`, `localization_sim_mode`, `enable_all_modules_auto_mode`,
`launch_fault_injection`, `control_module_preset` and `dummy_traffic_light_mode`,
among others -- and `use_sim_time` is what the coverage runs depend on.

The file is kept for reference. Nothing reads it.

Worth knowing: SSv2 launches Autoware *through* a file of this name
(`scenario_test_runner.launch.py` maps every `awf/universe/*` architecture type
to it). That is Autoware's launch entry point, not the `planning_simulator`
simulator. scenoRITA drove scenario_simulator_v2 in v1.0 and still does.

## 4. One container, and three phases per generation

`CONTAINER_NUM` was 3. It is now 1, and not a tunable. This harness measured
that Autoware under CPU contention does not merely run slower, it *plans
differently* -- so a parallel campaign trades the validity of its own results
for wall clock.

The same reasoning changed `evaluate_scenarios` from a pipeline to three
phases. Grading a bag deserialises thousands of messages and runs shapely over
each one; running that concurrently with a drive would corrupt exactly the
trajectories being graded. Now: generate all, drive one at a time with the
machine quiet, then grade in parallel with no stack running.

Cost: roughly 20-25 scenarios/hour.

## 5. Failures that used to be silent

Four changes where the old behaviour produced a *wrong answer* rather than an
error. These are the ones to know about when comparing v1.0 results to these.

**A run that produced no bag is no longer graded.** `replay_scenario` returns
whether a `.db3` exists, and the player drops the scenario if not. Previously an
infrastructure failure flowed into the analyzer, graded as zero violations, and
told the GA the obstacles were harmless -- when nothing had been measured. Over
a long campaign that biases the search toward whatever is breaking.

**`speed_limit` is optional and is now defaulted.** `get_speed_limits` did an
unguarded `attributes['speed_limit']` over every vehicle lanelet, and it is
reached from `Speeding.__init__`. One unannotated lanelet raised `KeyError`,
grading returned `None` for every scenario on that map, and the map reported no
violations at all -- indistinguishable from a map the ADS drove perfectly. The
attribute appears somewhere in all 64 maps of this corpus but is not guaranteed
per-lanelet.

**Violating records no longer overwrite each other.** `main.py` copied the bag
directory's *contents* into `violations/` itself, so every violating scenario in
a run merged into one directory and all but the last `.db3` was overwritten. The
evidence for a violation was the trajectory of a different scenario. Now each
goes to `violations/<scenario id>/`.

**The bag reader tolerates types it cannot import.** `ROSBagReader` resolved
every topic type eagerly. A 0.52.0 SSv2 bag names ~830 topics including SSv2's
own `traffic_simulator_msgs`, so it died before reading a single message. The
oracles use four topics; an unimportable type on any of the other 826 is now
ignored, and only becomes an error if something asks to deserialise it.

## 6. Dependency pins

Installing scenoRITA's requirements unpinned drags in numpy 2.x, which is
ABI-incompatible with the image's system scipy *and* with the ROS 2 Python
bindings. `import scipy.interpolate` then fails with "numpy.dtype size changed",
so grading fails on every scenario while generation still works -- a campaign
that produces bags and no violations. `harness/ssv2/setup_container.sh` pins
`numpy<1.25` and `scikit-learn==1.3.2`.

## Verified

- Generation, XSD validation, drive and grading, end to end, on
  `sample-map-planning` against the instrumented overlay and against the
  `--coverage` build (253 of 551 gcno produced counters).
- The generated scenario validates against the current OpenSCENARIO 1.2 schema
  with no change to the writer.
