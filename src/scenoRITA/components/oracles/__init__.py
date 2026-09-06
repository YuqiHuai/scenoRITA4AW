from loguru import logger

from scenoRITA.components.oracles.BasicMetric import BasicMetric
from scenoRITA.components.oracles.MetricManager import MetricManager
from autoware.rosbag_reader import ROSBagReader
from scenoRITA.components.oracles.OracleInterrupt import OracleInterrupt
from typing import List


class RecordAnalyzer:
    record_path: str

    def __init__(self, record_path: str, oracles: List[BasicMetric]) -> None:
        self.oracle_manager = MetricManager()
        self.record_path = record_path
        self.oracles = oracles
        self.register_oracles()

    def register_oracles(self):
        for o in self.oracles:
            self.oracle_manager.register_oracle(o)

    def topic_names(self):
        return [
            '/localization/acceleration',
            '/localization/kinematic_state',
            '/perception/object_recognition/ground_truth/objects',
            '/planning/mission_planning/route',
        ]

    def analyze(self):
        has_localization = False
        has_ground_truth = False
        has_route = False
        reader = ROSBagReader(self.record_path)
        for topic, message, t in reader.read_messages():
            if not has_localization and topic == '/localization/kinematic_state':
                has_localization = True
            if not has_ground_truth and topic == '/perception/object_recognition/ground_truth/objects':
                has_ground_truth = True
            if not has_route and topic == '/planning/mission_planning/route':
                has_route = True
            if topic in self.topic_names():
                msg = reader.deserialize_msg(message, topic)
                try:
                    self.oracle_manager.on_new_message(topic, msg, t)
                except OracleInterrupt:
                    break
        del reader
        # Each of these means the scenario was NOT measured, and must be told
        # apart from a scenario that was measured and violated nothing --
        # otherwise the GA reads an infrastructure or scenario-validity failure
        # as "these obstacles are harmless" and selects toward it.
        if not has_localization:
            logger.warning(f"{self.record_path}: no localization -- the ego never localised")
            return None
        if not has_ground_truth:
            logger.warning(f"{self.record_path}: no ground truth -- perception published nothing")
            return None
        if not has_route:
            # Autoware never accepted a route, so the ego never drove and every
            # oracle is gated off (they all require has_routing_plan). This is a
            # property of the *generated scenario*, not of the stack: the ego's
            # start/goal pair was one the mission planner refused. Observed on
            # 1 of 2 in the first end-to-end run, so it is not rare -- if it
            # dominates a campaign, the ego route generator is what to look at,
            # not the harness.
            logger.warning(
                f"{self.record_path}: no route was ever published -- the mission "
                "planner refused this scenario's start/goal pair; the ego never drove"
            )
            return None
        return self.get_results()

    def get_results(self):
        return self.oracle_manager.get_results()
