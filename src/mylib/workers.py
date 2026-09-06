import multiprocessing as mp
import random
from logging import Logger
from pathlib import Path
from typing import Optional

from environment.container import Container
from autoware.open_scenario import OpenScenario
from scenario_handling.ScenarioReplayer import record_dir, replay_scenario
from scenoRITA.components.grading_metrics import GradingResult, grade_scenario
from scenoRITA.representation import ObstacleFitness


def generator_worker(
    _logger: Logger,
    task_queue: "mp.Queue[Optional[OpenScenario]]",
    result_queue: mp.Queue,
    target_dir: Path,
):
    while True:
        scenario = task_queue.get()
        if scenario is None:
            break
        _logger.info(f"{scenario.get_id()}: generate start")

        target_file = Path(target_dir, "input")
        target_file.parent.mkdir(parents=True, exist_ok=True)
        scenario.export_to_file(target_file)

        _logger.info(f"{scenario.get_id()}: generate end")
        result_queue.put(scenario)


def player_worker(
    container: Container,
    _logger: Logger,
    task_queue: "mp.Queue[Optional[OpenScenario]]",
    result_queue: "mp.Queue[Optional[OpenScenario]]",
    target_dir: Path,
    dry_run: bool,
):
    while True:
        scenario = task_queue.get()
        if scenario is None:
            break
        sce_id = scenario.get_id()
        _logger.info(f"{sce_id}: play start ({container.container_name})")

        if dry_run:
            target_output_path = Path(record_dir(sce_id), f"{sce_id}_0.db3")
            target_output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(target_output_path, "w") as fp:
                fp.write("dry run")
        else:
            if not replay_scenario(scenario, container):
                # Do NOT pass this to the analyzer. A run that produced no bag
                # is an infrastructure failure, and grading it as "no
                # violations" would tell the GA the obstacles were harmless
                # when in fact nothing was measured. main.py counts the gap
                # between scenarios sent and results returned and restarts the
                # stack when it persists.
                _logger.error(f"{sce_id}: no bag produced -- see records/{sce_id}/run.log")
                continue

        _logger.info(f"{sce_id}: play end")
        result_queue.put(scenario)


def analysis_worker(
    _logger: Logger,
    task_queue: "mp.Queue[Optional[OpenScenario]]",
    result_queue: "mp.Queue[GradingResult]",
    target_dir: Path,
    dry_run: bool,
):
    while True:
        scenario = task_queue.get()
        if scenario is None:
            break
        sce_id = scenario.get_id()
        _logger.info(f"{sce_id}: analysis start")

        # Where scenario_test_runner actually nests the bag; the player has
        # already confirmed a .db3 is there.
        target_input_file = record_dir(sce_id)
        if dry_run:
            obs_ids = [obs.id for obs in scenario.obstacles]
            fitnesses = dict()
            for oid in obs_ids:
                fitnesses[oid] = tuple(
                    random.random() for _ in range(len(ObstacleFitness.weights))
                )
            result_queue.put(
                GradingResult(
                    scenario.get_id(),
                    target_input_file,
                    fitnesses,
                    [],
                )
            )
        else:
            grading_result = grade_scenario(
                scenario.get_id(), target_input_file
            )
            if grading_result is None:
                # Not necessarily retries: grade_scenario also returns None
                # when the record shows the scenario was never measured (no
                # localisation, no ground truth, or no route). The reason is
                # logged by RecordAnalyzer.analyze just above this line.
                _logger.error(f"{sce_id}: not graded -- see the warning above for why")
                fallback_fitness = dict()
                for obs in scenario.obstacles:
                    fallback_fitness[obs.id] = ObstacleFitness.get_fallback_fitness()
                result_queue.put(
                    GradingResult(sce_id, target_input_file, fallback_fitness, [])
                )
            else:
                result_queue.put(grading_result)

        _logger.info(f"{sce_id}: analysis end")
