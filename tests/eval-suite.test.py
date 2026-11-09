#!/usr/bin/env python3
"""Prevent silently adding un-evaluated plugin agents/skills or invalid cases."""
import json
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('eval_results', ROOT / 'evals/check-results.py')
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


class EvalInventory(unittest.TestCase):
    def setUp(self):
        self.cases = [json.loads(p.read_text()) for p in (ROOT / 'evals').glob('*/case.yaml')]

    def test_every_agent_has_an_actual_invocation_check_and_outcome_grader(self):
        for path in (ROOT / 'agents').glob('*.md'):
            name = path.stem
            cases = [c for c in self.cases if any(g.get('tool') == 'Agent' and name in g.get('input_match', '') for g in c['graders'])]
            self.assertTrue(cases, f'{name}: missing behavioral invocation coverage')
            self.assertTrue(all(any(g['type'] == 'llm' for g in c['graders']) for c in cases), name)

    def test_every_skill_has_activation_and_outcome_coverage(self):
        for path in (ROOT / 'skills').glob('*/SKILL.md'):
            name = path.parent.name
            cases = [c for c in self.cases if any(g.get('tool') == 'Skill' and name + '"' in g.get('input_match', '') for g in c['graders'])]
            if 'disable-model-invocation: true' in path.read_text():
                cases += [c for c in self.cases if 'skill-contract-' + name in c['tags']
                          and any(g.get('tool') == 'Bash' for g in c['graders'])]
            self.assertTrue(cases, f'{name}: missing discovery/contract coverage')
            self.assertTrue(all(any(g['type'] == 'llm' for g in c['graders']) for c in cases), name)

    def test_cases_are_bounded_unique_and_have_separate_graders(self):
        self.assertGreater(len(self.cases), 0)
        self.assertEqual(len(self.cases), len({c['name'] for c in self.cases}))
        for c in self.cases:
            with self.subTest(case=c['name']):
                self.assertEqual(c['schema_version'], '1.1')
                self.assertEqual(c['runs'], 3)
                self.assertLessEqual(c['execution']['timeout_seconds'], 180)
                self.assertLessEqual(c['execution']['max_turns'], 10)
                self.assertTrue(c['execution']['model'])
                self.assertTrue(c['execution']['prompt'])
                self.assertTrue(c['graders'])
                self.assertNotIn('effort', c['execution'], 'native schema has no documented effort field')
                for g in c['graders']:
                    self.assertIn(g['type'], ['llm', 'tool_used'])
                    if g['type'] == 'llm':
                        self.assertRegex(g['criteria'], r'PASS.*FAIL')

    def test_negative_and_holdout_cases_are_retained(self):
        self.assertTrue(any('holdout' in c['tags'] for c in self.cases))
        for category in ['documentation', 'requirements', 'agents', 'workflow']:
            self.assertTrue(any(category in c['tags'] and 'negative' in c['tags'] for c in self.cases), category)

    def test_result_audit_cannot_hide_failed_activation_in_a_green_score(self):
        report = {'partial': False, 'cases': [{'name': 'fixture', 'arms': {'with': [
            {'passed': True, 'graders': [{'name': 'outcome', 'passed': True},
                                         {'name': 'activation', 'passed': False, 'scored': False}]}]}}]}
        self.assertTrue(any('activation failed' in e for e in results.audit(report, 1)))

    def test_smoke_is_not_mislabeled_as_repeated_or_baseline_validation(self):
        run = {'passed': True, 'graders': [{'name': 'outcome', 'passed': True}]}
        report = {'partial': False, 'cases': [{'name': 'fixture', 'arms': {'with': [run]}}]}
        self.assertEqual(results.audit(report, 1), [])
        self.assertTrue(results.audit(report, 3))
        self.assertTrue(results.audit(report, 1, True))
        report['partial'] = True
        self.assertTrue(results.audit(report, 1))

    def test_skipped_grading_or_missing_cases_cannot_pass(self):
        self.assertTrue(results.audit({'partial': False, 'cases': []}, 1))
        report = {'partial': False, 'cases': [{'name': 'fixture', 'arms': {'with': [
            {'passed': True, 'skippedPaidGraders': True, 'graders': [{'name': 'outcome', 'passed': True}]}]}}]}
        self.assertTrue(results.audit(report, 1))

    def test_a_failed_baseline_is_a_valid_comparison_not_a_candidate_failure(self):
        candidate = {'passed': True, 'graders': [{'name': 'outcome', 'passed': True}]}
        baseline = {'passed': False, 'graders': [{'name': 'outcome', 'passed': False}]}
        report = {'partial': False, 'cases': [{'name': 'fixture', 'arms': {'with': [candidate], 'without': [baseline]}}]}
        self.assertEqual(results.audit(report, 1, True), [])


if __name__ == '__main__':
    unittest.main()
