"""Line coverage with the standard library, for tests/crap-dogfood.sh.

Loaded through PYTHONPATH as sitecustomize, so every Python process the tests
start (subprocesses included) records the lines it runs under LINECOV_ROOT and
writes one LCOV file per process to LINECOV_DIR at exit. Python 3.12+
(sys.monitoring). Not a replacement for coverage.py: no branches, and a
process killed by a signal writes nothing.
"""
import atexit
import os
import sys
import types

ROOT = os.environ.get("LINECOV_ROOT")
OUT = os.environ.get("LINECOV_DIR")

if ROOT and OUT and hasattr(sys, "monitoring"):
    ROOT = os.path.realpath(ROOT) + os.sep
    mon = sys.monitoring
    TOOL = mon.COVERAGE_ID
    hits = {}

    def on_line(code, line):
        path = code.co_filename
        if path.startswith(ROOT) or os.path.realpath(path).startswith(ROOT):
            hits.setdefault(os.path.realpath(path), set()).add(line)
        return mon.DISABLE

    def executable(path):
        try:
            source = open(path, encoding="utf-8").read()
            top = compile(source, path, "exec")
        except (OSError, SyntaxError, ValueError):
            return set()
        found, stack = set(), [top]
        while stack:
            code = stack.pop()
            found.update(line for _, _, line in code.co_lines() if line)
            stack.extend(c for c in code.co_consts if isinstance(c, types.CodeType))
        return found

    def write():
        mon.set_events(TOOL, 0)
        if not hits:
            return
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, "%d.lcov" % os.getpid()), "w") as stream:
            for path, ran in sorted(hits.items()):
                stream.write("SF:%s\n" % path)
                for line in sorted(executable(path) | ran):
                    stream.write("DA:%d,%d\n" % (line, 1 if line in ran else 0))
                stream.write("end_of_record\n")

    mon.use_tool_id(TOOL, "linecov")
    mon.register_callback(TOOL, mon.events.LINE, on_line)
    mon.set_events(TOOL, mon.events.LINE)
    atexit.register(write)
