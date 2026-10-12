"""Windows 10+ process-tree resource boundary for the offline profiler decoder.

CLI: python bounded-process.py -- <executable> [arguments...]
Production limits are fixed. This is resource containment, not a security sandbox.
Child stdio is inherited directly; the wrapper never buffers untrusted output.

References:
https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information
https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812
"""

import ctypes as C
from ctypes import wintypes as W
import json
import math
import os
import subprocess
import sys
import time

TIMEOUT_SECONDS = 60
MEMORY_BYTES = 2 * 1024**3
ACTIVE_PROCESS_LIMIT = 32
SIZE_T = C.c_size_t
ULONG_PTR = C.c_size_t


class BasicLimits(C.Structure):
    _fields_ = [("PerProcessUserTimeLimit", C.c_longlong),
                ("PerJobUserTimeLimit", C.c_longlong), ("LimitFlags", W.DWORD),
                ("MinimumWorkingSetSize", SIZE_T), ("MaximumWorkingSetSize", SIZE_T),
                ("ActiveProcessLimit", W.DWORD), ("Affinity", ULONG_PTR),
                ("PriorityClass", W.DWORD), ("SchedulingClass", W.DWORD)]


class IoCounters(C.Structure):
    _fields_ = [(name, C.c_ulonglong) for name in (
        "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
        "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


class ExtendedLimits(C.Structure):
    _fields_ = [("BasicLimitInformation", BasicLimits), ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", SIZE_T), ("JobMemoryLimit", SIZE_T),
                ("PeakProcessMemoryUsed", SIZE_T), ("PeakJobMemoryUsed", SIZE_T)]


class Accounting(C.Structure):
    _fields_ = [(name, C.c_longlong) for name in (
        "TotalUserTime", "TotalKernelTime", "ThisPeriodTotalUserTime", "ThisPeriodTotalKernelTime")]
    _fields_ += [(name, W.DWORD) for name in (
        "TotalPageFaultCount", "TotalProcesses", "ActiveProcesses", "TotalTerminatedProcesses")]


class StartupInfo(C.Structure):
    _fields_ = [("cb", W.DWORD), ("lpReserved", W.LPWSTR), ("lpDesktop", W.LPWSTR),
                ("lpTitle", W.LPWSTR)]
    _fields_ += [(name, W.DWORD) for name in (
        "dwX", "dwY", "dwXSize", "dwYSize", "dwXCountChars", "dwYCountChars",
        "dwFillAttribute", "dwFlags")]
    _fields_ += [("wShowWindow", W.WORD), ("cbReserved2", W.WORD),
                ("lpReserved2", C.c_void_p), ("hStdInput", W.HANDLE),
                ("hStdOutput", W.HANDLE), ("hStdError", W.HANDLE)]


class StartupInfoEx(C.Structure):
    _fields_ = [("StartupInfo", StartupInfo), ("lpAttributeList", C.c_void_p)]


class ProcessInformation(C.Structure):
    _fields_ = [("hProcess", W.HANDLE), ("hThread", W.HANDLE),
                ("dwProcessId", W.DWORD), ("dwThreadId", W.DWORD)]


def _api():
    if os.name != "nt":
        raise RuntimeError("The bounded decoder runner requires Windows 10 or later")
    dll = C.WinDLL("kernel32", use_last_error=True)
    declarations = {
        "CreateJobObjectW": ([C.c_void_p, W.LPCWSTR], W.HANDLE),
        "SetInformationJobObject": ([W.HANDLE, C.c_int, C.c_void_p, W.DWORD], W.BOOL),
        "QueryInformationJobObject": ([W.HANDLE, C.c_int, C.c_void_p, W.DWORD, C.c_void_p], W.BOOL),
        "TerminateJobObject": ([W.HANDLE, W.UINT], W.BOOL),
        "CloseHandle": ([W.HANDLE], W.BOOL),
        "GetCurrentProcess": ([], W.HANDLE),
        "GetStdHandle": ([W.DWORD], W.HANDLE),
        "DuplicateHandle": ([W.HANDLE, W.HANDLE, W.HANDLE, C.POINTER(W.HANDLE), W.DWORD, W.BOOL, W.DWORD], W.BOOL),
        "InitializeProcThreadAttributeList": ([C.c_void_p, W.DWORD, W.DWORD, C.POINTER(SIZE_T)], W.BOOL),
        "UpdateProcThreadAttribute": ([C.c_void_p, W.DWORD, SIZE_T, C.c_void_p, SIZE_T, C.c_void_p, C.c_void_p], W.BOOL),
        "DeleteProcThreadAttributeList": ([C.c_void_p], None),
        "CreateProcessW": ([W.LPCWSTR, W.LPWSTR, C.c_void_p, C.c_void_p, W.BOOL, W.DWORD,
                            C.c_void_p, W.LPCWSTR, C.POINTER(StartupInfoEx), C.POINTER(ProcessInformation)], W.BOOL),
        "IsProcessInJob": ([W.HANDLE, W.HANDLE, C.POINTER(W.BOOL)], W.BOOL),
        "ResumeThread": ([W.HANDLE], W.DWORD),
        "WaitForSingleObject": ([W.HANDLE, W.DWORD], W.DWORD),
        "GetExitCodeProcess": ([W.HANDLE, C.POINTER(W.DWORD)], W.BOOL),
    }
    for name, (args, result) in declarations.items():
        fn = getattr(dll, name)
        fn.argtypes, fn.restype = args, result
    return dll


def _check(value):
    if not value:
        raise C.WinError(C.get_last_error())
    return value


def run_bounded(command, *, timeout_seconds=TIMEOUT_SECONDS, memory_bytes=MEMORY_BYTES,
                active_process_limit=ACTIVE_PROCESS_LIMIT):
    """Run an owned tree; return an audit dict. Small bounds support focused tests.

    Memory is the job's aggregate committed memory, not reserved virtual address
    space. Exceeding it denies allocations; the wall deadline remains independent.
    Cleanup has a separate five-second bounded wait after termination is requested.
    """
    if not command or not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("A command and a positive finite timeout are required")
    if memory_bytes <= 0 or not 1 <= active_process_limit <= 32:
        raise ValueError("Invalid job resource limits")
    api = _api()
    started = time.monotonic()
    job = None
    attrs = None
    attrs_ready = False
    handles = []
    proc = ProcessInformation()
    audit = {"kind": "bounded-process", "timeoutSeconds": timeout_seconds,
             "memoryLimitBytes": memory_bytes, "activeProcessLimit": active_process_limit,
             "timedOut": False, "exitCode": 125, "cleanupVerified": False}
    try:
        job = _check(api.CreateJobObjectW(None, None))
        limits = ExtendedLimits()
        # KILL_ON_JOB_CLOSE | JOB_MEMORY | ACTIVE_PROCESS. No breakaway flags.
        limits.BasicLimitInformation.LimitFlags = 0x2000 | 0x200 | 0x8
        limits.BasicLimitInformation.ActiveProcessLimit = active_process_limit
        limits.JobMemoryLimit = memory_bytes
        _check(api.SetInformationJobObject(job, 9, C.byref(limits), C.sizeof(limits)))
        effective = ExtendedLimits()
        _check(api.QueryInformationJobObject(job, 9, C.byref(effective), C.sizeof(effective), None))
        if (effective.BasicLimitInformation.LimitFlags != limits.BasicLimitInformation.LimitFlags
                or effective.JobMemoryLimit != memory_bytes
                or effective.BasicLimitInformation.ActiveProcessLimit != active_process_limit):
            raise RuntimeError("Job resource limit readback did not match")
        audit["limitsVerified"] = True
        current = api.GetCurrentProcess()
        for index in (-10, -11, -12):
            original = api.GetStdHandle(index & 0xFFFFFFFF)
            if not original or original == C.c_void_p(-1).value:
                raise RuntimeError("All three standard handles must be available")
            duplicate = W.HANDLE()
            _check(api.DuplicateHandle(current, original, current, C.byref(duplicate), 0, True, 2))
            handles.append(duplicate.value)
        inherited = (W.HANDLE * 3)(*handles)
        jobs = (W.HANDLE * 1)(job)
        size = SIZE_T()
        api.InitializeProcThreadAttributeList(None, 2, 0, C.byref(size))
        if not size.value:
            raise C.WinError(C.get_last_error())
        attrs = C.create_string_buffer(size.value)
        _check(api.InitializeProcThreadAttributeList(attrs, 2, 0, C.byref(size)))
        attrs_ready = True
        _check(api.UpdateProcThreadAttribute(attrs, 0, 0x20002, inherited, C.sizeof(inherited), None, None))
        # Atomic job assignment closes the create-suspended/assign crash gap.
        _check(api.UpdateProcThreadAttribute(attrs, 0, 0x2000D, jobs, C.sizeof(jobs), None, None))
        startup = StartupInfoEx()
        startup.StartupInfo.cb = C.sizeof(startup)
        startup.StartupInfo.dwFlags = 0x100 | 0x1  # USESTDHANDLES | USESHOWWINDOW (hidden)
        startup.StartupInfo.hStdInput, startup.StartupInfo.hStdOutput, startup.StartupInfo.hStdError = handles
        startup.lpAttributeList = C.cast(attrs, C.c_void_p)
        command_line = C.create_unicode_buffer(subprocess.list2cmdline(command))
        # SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW
        _check(api.CreateProcessW(command[0], command_line, None, None, True,
                                 0x4 | 0x80000 | 0x08000000, None, None,
                                 C.byref(startup), C.byref(proc)))
        audit["pid"] = proc.dwProcessId
        in_job = W.BOOL()
        _check(api.IsProcessInJob(proc.hProcess, job, C.byref(in_job)))
        if not in_job.value:
            raise RuntimeError("Process was not assigned to the owned job")
        if api.ResumeThread(proc.hThread) == 0xFFFFFFFF:
            raise C.WinError(C.get_last_error())
        # Short waits keep KeyboardInterrupt responsive, using one absolute deadline.
        while True:
            remaining = timeout_seconds - (time.monotonic() - started)
            if remaining <= 0:
                audit.update(timedOut=True, exitCode=124)
                break
            result = api.WaitForSingleObject(proc.hProcess, min(100, max(1, int(remaining * 1000))))
            if result == 0:
                exit_code = W.DWORD()
                _check(api.GetExitCodeProcess(proc.hProcess, C.byref(exit_code)))
                audit["exitCode"] = exit_code.value
                break
            if result != 258:
                raise C.WinError(C.get_last_error())
    except (Exception, KeyboardInterrupt) as exc:
        audit["error"] = str(exc) or type(exc).__name__
        audit["exitCode"] = 125
    finally:
        if job:
            try:
                _check(api.TerminateJobObject(job, 124 if audit["timedOut"] else 125))
                deadline = time.monotonic() + 5
                accounting = Accounting()
                while True:
                    _check(api.QueryInformationJobObject(job, 1, C.byref(accounting), C.sizeof(accounting), None))
                    if accounting.ActiveProcesses == 0:
                        audit["cleanupVerified"] = True
                        audit["totalProcesses"] = accounting.TotalProcesses
                        break
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Owned job did not reach zero active processes")
                    time.sleep(0.01)
                final_limits = ExtendedLimits()
                _check(api.QueryInformationJobObject(job, 9, C.byref(final_limits), C.sizeof(final_limits), None))
                # Report the OS counter verbatim. In the failed-allocation test it
                # can exceed the cap; it is not a proof of successful committed allocation.
                audit["reportedPeakJobMemoryBytes"] = final_limits.PeakJobMemoryUsed
            except Exception as exc:
                audit["cleanupError"] = str(exc)
                audit["exitCode"] = 125
        for handle in (proc.hThread, proc.hProcess, *handles):
            if handle:
                api.CloseHandle(handle)
        if attrs_ready:
            api.DeleteProcThreadAttributeList(attrs)
        if job:
            api.CloseHandle(job)  # KILL_ON_JOB_CLOSE remains the failure backstop.
    audit["elapsedSeconds"] = round(time.monotonic() - started, 3)
    return audit


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        raise SystemExit("Usage: python bounded-process.py -- <executable> [arguments...]")
    audit = run_bounded(sys.argv[2:])
    print(json.dumps(audit, separators=(",", ":")), file=sys.stderr, flush=True)
    return audit["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
