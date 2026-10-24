"""Own a test command's descendants before allowing the command to start."""

import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading


def windows_job():
    from ctypes import wintypes

    class BasicLimits(ctypes.Structure):
        _fields_ = [
            ("process_time", ctypes.c_int64),
            ("job_time", ctypes.c_int64),
            ("flags", wintypes.DWORD),
            ("minimum_working_set", ctypes.c_size_t),
            ("maximum_working_set", ctypes.c_size_t),
            ("active_processes", wintypes.DWORD),
            ("affinity", ctypes.c_size_t),
            ("priority", wintypes.DWORD),
            ("scheduling", wintypes.DWORD),
        ]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in (
            "read_operations", "write_operations", "other_operations",
            "read_bytes", "write_bytes", "other_bytes",
        )]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("basic", BasicLimits),
            ("io", IoCounters),
            ("process_memory", ctypes.c_size_t),
            ("job_memory", ctypes.c_size_t),
            ("peak_process_memory", ctypes.c_size_t),
            ("peak_job_memory", ctypes.c_size_t),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
    ]
    kernel.SetInformationJobObject.restype = wintypes.BOOL
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    limits = ExtendedLimits()
    limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
        raise ctypes.WinError(ctypes.get_last_error())
    # No target exists yet. Children inherit membership, but not the handle.
    if not kernel.AssignProcessToJobObject(job, kernel.GetCurrentProcess()):
        raise ctypes.WinError(ctypes.get_last_error())
    return job


def main():
    state = Path(sys.argv[1])
    command = sys.argv[2:]

    def report(**value):
        destination = state if value["state"] == "ready" else state.with_suffix(".result")
        temporary = destination.with_suffix(".writing")
        temporary.write_text(json.dumps(value), encoding="utf-8")
        os.replace(temporary, destination)

    if os.name == "nt":
        job = windows_job()
    else:
        os.setsid()
        # Keep this group leader alive until the final group kill. A handler,
        # unlike SIG_IGN, is reset when exec starts the actual command.
        signal.signal(signal.SIGTERM, lambda *_: None)
    report(state="ready", owner=os.getpid())
    if sys.stdin.buffer.readline() != b"start\n":
        return

    disconnected = threading.Event()

    def read_parent():
        sys.stdin.buffer.read()
        disconnected.set()

    threading.Thread(target=read_parent, daemon=True).start()
    try:
        child = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=sys.stdout,
            stderr=sys.stderr, close_fds=True,
        )
        while child.poll() is None and not disconnected.wait(0.01):
            pass
        if child.returncode is not None:
            report(state="exited", code=child.returncode, pid=child.pid)
    except OSError as error:
        report(state="error", message=f"{command[0]}: {error}", code=error.errno or 1)
    finally:
        # Parent cancellation/death closes stdin. Do not leave its children
        # running, even if Dart never gets as far as its cleanup block.
        disconnected.wait()
        if os.name != "nt":
            os.killpg(os.getpid(), signal.SIGKILL)
        # Exiting closes the only Job handle, terminating all its members.
        os._exit(0)


if __name__ == "__main__":
    main()
