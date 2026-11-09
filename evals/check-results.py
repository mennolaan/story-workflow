#!/usr/bin/env python3
"""Audit native eval outcomes AND process indicators, including unscored ones."""
import argparse
import json
from pathlib import Path
import sys


def audit(report, min_runs=3, require_baseline=False):
    errors = []
    if report.get('partial') is not False:
        errors.append('run is partial or completion status is missing')
    cases = report.get('cases', [])
    if not isinstance(cases, list) or not cases:
        return errors + ['report has no cases']
    names = set()
    for case in cases:
        name = case.get('name', '<unnamed>')
        if name in names:
            errors.append(f'{name}: duplicate case')
        names.add(name)
        arms = case.get('arms', {})
        wanted = ['with', 'without'] if require_baseline else ['with']
        for arm in wanted:
            runs = arms.get(arm, [])
            if len(runs) < min_runs:
                errors.append(f'{name}/{arm}: {len(runs)} runs; need {min_runs}')
            for i, run in enumerate(runs):
                prefix = f'{name}/{arm}/{i + 1}'
                if run.get('error') or run.get('skippedPaidGraders'):
                    errors.append(f'{prefix}: execution/grading incomplete')
                if arm == 'with' and run.get('passed') is not True:
                    errors.append(f'{prefix}: outcome threshold failed')
                graders = run.get('graders', [])
                if not graders:
                    errors.append(f'{prefix}: no grader results')
                # With-only indicators do not inflate a baseline score, but a
                # candidate must still satisfy its declared process checks.
                for grader in graders:
                    if arm == 'with' and grader.get('passed') is not True:
                        errors.append(f'{prefix}: grader {grader.get("name", "?")} failed')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report')
    parser.add_argument('--min-runs', type=int, default=3)
    parser.add_argument('--require-baseline', action='store_true')
    args = parser.parse_args()
    if args.min_runs < 1:
        parser.error('--min-runs must be positive')
    try:
        report = json.loads(Path(args.report).read_text())
        errors = audit(report, args.min_runs, args.require_baseline)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        errors = ['invalid result: ' + str(error)]
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('EVAL CHECKS OK: declared outcomes and process indicators passed; this is not a reliability estimate')
    return 0


if __name__ == '__main__':
    sys.exit(main())
