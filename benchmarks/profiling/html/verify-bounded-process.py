"""Focused Windows smoke, timeout/tree cleanup, and aggregate-memory checks.

Uses small disposable Python children only. Does not launch a decoder or Studio.
"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def worker(case):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("bounded_process", Path(__file__).with_name("bounded-process.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if case == "stdio":
        command = [sys.executable, "-c", "import sys; print(sys.stdin.read()); print('stderr-proof', file=sys.stderr); sys.exit(7)"]
        audit = module.run_bounded(command)
    elif case in ("normal-tree", "timeout-tree"):
        code = "import subprocess, sys, time; p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); print(p.pid, flush=True); "
        code += "time.sleep(60)" if case == "timeout-tree" else "sys.exit(0)"
        audit = module.run_bounded([sys.executable, "-c", code], timeout_seconds=1)
    elif case == "memory":
        child = "import time; held=bytearray(80*1024**2); print('allocated', flush=True); time.sleep(60)"
        code = "import subprocess, sys\n"
        code += "child=subprocess.Popen([sys.executable, '-c', " + repr(child) + "], stdout=subprocess.PIPE, text=True)\n"
        code += "assert child.stdout.readline().strip() == 'allocated'\n"
        code += "try:\n    held=bytearray(80*1024**2)\nexcept MemoryError:\n    print('aggregate-memory-denied'); sys.exit(23)\n"
        code += "sys.exit(99)\n"
        audit = module.run_bounded([sys.executable, "-c", code], timeout_seconds=5, memory_bytes=128 * 1024**2)
    elif case == "launch-failure":
        audit = module.run_bounded([str(Path(__file__).with_name("no-such-owned-executable.exe"))])
    else:
        raise AssertionError(case)
    print(json.dumps(audit), file=sys.stderr, flush=True)


def main():
    sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    results = []
    try:
        for case in ("stdio", "normal-tree", "timeout-tree", "memory", "launch-failure"):
            result = subprocess.run([sys.executable, __file__, "--worker", case],
                                    input="stdin-proof", capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (case, result.stderr)
            audit = json.loads(result.stderr.strip().splitlines()[-1])
            assert audit["cleanupVerified"], audit
            assert audit["limitsVerified"], audit
            assert sentinel.poll() is None, "Unrelated sentinel was affected"
            assert "cleanupError" not in audit, audit
            if case == "stdio":
                assert audit["exitCode"] == 7 and result.stdout.strip() == "stdin-proof", (audit, result.stdout)
                assert "stderr-proof" in result.stderr
            elif case == "normal-tree":
                assert audit["exitCode"] == 0 and audit["totalProcesses"] >= 2, audit
            elif case == "timeout-tree":
                assert audit["timedOut"] and audit["exitCode"] == 124 and audit["totalProcesses"] >= 2, audit
                assert audit["elapsedSeconds"] < 7, audit
            elif case == "memory":
                assert audit["exitCode"] == 23 and "aggregate-memory-denied" in result.stdout, (audit, result.stdout)
                # The second allocation is smaller than the job cap but fails
                # while a separate process holds the first: aggregate enforcement.
                assert audit["totalProcesses"] >= 2, audit
            else:
                assert audit["exitCode"] == 125 and audit["totalProcesses"] == 0 and "error" in audit, audit
            results.append({"case": case, "audit": audit})
        cli = subprocess.run([sys.executable, str(Path(__file__).with_name("bounded-process.py")),
                              "--", sys.executable, "-c", "import sys; print(sys.stdin.read()); sys.exit(7)"],
                             input="cli-stdio-proof", capture_output=True, text=True, timeout=10)
        cli_audit = json.loads(cli.stderr.strip())
        assert cli.returncode == 7 and cli.stdout.strip() == "cli-stdio-proof", cli
        assert cli_audit["limitsVerified"] and cli_audit["cleanupVerified"], cli_audit
        assert sentinel.poll() is None
        results.append({"case": "cli", "audit": cli_audit})
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=5)
    print(json.dumps({"passed": True, "cases": results}, indent=2))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        worker(sys.argv[2])
    else:
        main()
