#!/usr/bin/env python3
"""Firstmate credential-domain lane executor.

Public interface:
  fm-test-supervisor.py execute --manifest MANIFEST
  fm-test-supervisor.py validate-artifact ARTIFACT
  fm-test-supervisor.py qualify --artifact ARTIFACT

The execute command is the sole owner of test attempts, deadlines, credentials,
the child-environment allowlist, signaling, cleanup, and schema-v2 evidence.
Required containment needs uid 0. The explicitly labeled developer mode is
non-enforcing and never qualifies CI.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import grp
import hashlib
import json
import os
import pathlib
import pwd
import selectors
import shutil
import signal
import stat
import sys
import tempfile
import time
from dataclasses import dataclass, field
from typing import Any

SCHEMA_VERSION = 2
UID_MIN = 61000
UID_MAX = 64999
STARTUP_RESERVE = 15.0
CLEANUP_RESERVE = 4.0
TERM_GRACE = 1.0
LEASE_DIRECTORY_ROOT = pathlib.Path("/tmp/fm-test-credential-leases")
QUIESCE_GRACE = 3.0
OUTPUT_TAIL_BYTES = 32768
IMMUTABLE_PLANNED_FIELDS = (
    "index",
    "path",
    "family",
    "attempt",
    "expected_gate_skip",
    "duration_baseline_ms",
    "duration_budget_ms",
    "phase",
)

# Explicit child-environment allowlist. This executor is the single owner of the
# test credential domain, including which ambient variables a contained test may
# see. The model is default-deny: only these exact names and prefixes survive
# into a child, so an unexpected variable (a runner secret, a fleet-routing
# override, or a forged ownership marker) cannot leak in by accident. Fleet
# routing (FM_HOME, HERDR_*, CMUX_*, TMUX, ...) is simply absent from the list
# rather than blocklisted, so a newly added routing variable is denied by
# default instead of silently inherited.
ALLOWED_ENV_NAMES = frozenset({
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TZ",
    "LANG", "LANGUAGE", "PWD", "SHLVL", "TMPDIR", "TMP", "TEMP",
    "COLUMNS", "LINES", "HOSTNAME", "DISPLAY", "XDG_RUNTIME_DIR",
    # Continuous-integration context a test may legitimately read. Secret-bearing
    # names (GITHUB_TOKEN, ...) are excluded by SECRET_SUBSTRINGS below even if a
    # future prefix would otherwise admit them.
    "CI", "GITHUB_ACTIONS", "GITHUB_WORKFLOW", "GITHUB_JOB", "GITHUB_RUN_ID",
    "GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT", "GITHUB_REPOSITORY",
    "GITHUB_REF", "GITHUB_REF_NAME", "GITHUB_SHA", "GITHUB_EVENT_NAME",
    "GITHUB_ACTION", "GITHUB_WORKSPACE", "GITHUB_ACTOR",
    "RUNNER_OS", "RUNNER_ARCH", "RUNNER_NAME", "RUNNER_TEMP",
    "RUNNER_TOOL_CACHE",
})
# Prefix allowlist. LC_* localizes tools deterministically. FM_TEST_ENV_* is the
# one sanctioned channel for a test fixture to pass its own coordination values
# (evidence directories, fault switches) through to a contained child without
# widening the allowlist to arbitrary names.
ALLOWED_ENV_PREFIXES = ("LC_", "FM_TEST_ENV_")
# Defense-in-depth backstop: never forward a name that reads as a credential,
# even if it is otherwise allowlisted.
SECRET_SUBSTRINGS = (
    "TOKEN", "SECRET", "PASSWORD", "PASSWD", "COOKIE", "CREDENTIAL",
    "AUTHORIZATION", "PRIVATE_KEY", "SESSION", "API_KEY",
)


def iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class AtomicJsonError(RuntimeError):
    def __init__(self, cause: BaseException, published: bool) -> None:
        super().__init__(str(cause))
        self.published = published


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    temporary: pathlib.Path | None = None
    published = False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        counter = getattr(atomic_json, "counter", 0) + 1
        atomic_json.counter = counter
        temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}.{counter}")
        payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        published = True
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException as exc:
        raise AtomicJsonError(exc, published) from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def event(name: str, **values: Any) -> dict[str, Any]:
    return {"name": name, "at": iso_now(), **values}


class ContainmentError(RuntimeError):
    pass


class InventoryError(ContainmentError):
    pass


@dataclass
class Credentials:
    pid: int
    uids: tuple[int, int, int, int]
    gids: tuple[int, int, int, int]
    no_new_privs: int | None = None
    capabilities_clear: bool | None = None
    zombie: bool = False
    supplementary_gids: tuple[int, ...] = ()


class DarwinProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class CredentialPlatform:
    def __init__(self) -> None:
        if sys.platform.startswith("linux"):
            self.name = "linux"
        elif sys.platform == "darwin":
            self.name = "darwin"
            self._libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        else:
            raise ContainmentError(f"unsupported platform: {sys.platform}")

    def inventory(self) -> dict[int, Credentials]:
        if self.name == "linux":
            return self._linux_inventory()
        return self._darwin_inventory()

    @staticmethod
    def _linux_pid_credentials(pid: int) -> Credentials:
        try:
            fields: dict[str, str] = {}
            for line in pathlib.Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    fields[key] = value.strip()
            uids = tuple(int(v) for v in fields["Uid"].split())
            gids = tuple(int(v) for v in fields["Gid"].split())
            supplementary_gids = tuple(int(v) for v in fields["Groups"].split())
            caps = all(int(fields.get(k, "0"), 16) == 0 for k in ("CapInh", "CapPrm", "CapEff", "CapAmb"))
            return Credentials(
                pid, uids, gids, int(fields.get("NoNewPrivs", "0")), caps,
                fields.get("State", "").startswith("Z"), supplementary_gids,
            )
        except (KeyError, ValueError, OSError) as exc:
            raise InventoryError(f"could not inspect /proc/{pid}/status: {exc}") from exc

    @classmethod
    def _linux_inventory(cls) -> dict[int, Credentials]:
        result: dict[int, Credentials] = {}
        proc = pathlib.Path("/proc")
        if not proc.is_dir():
            raise InventoryError("/proc is unavailable")
        unreadable: list[str] = []
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                result[int(entry.name)] = cls._linux_pid_credentials(int(entry.name))
            except InventoryError as exc:
                if isinstance(exc.__cause__, FileNotFoundError):
                    continue
                if isinstance(exc.__cause__, PermissionError):
                    unreadable.append(entry.name)
                    continue
                raise
        if unreadable:
            raise InventoryError(f"credential inventory unreadable for pids: {','.join(unreadable[:8])}")
        return result

    def _darwin_inventory(self) -> dict[int, Credentials]:
        count = int(self._libproc.proc_listpids(1, 0, None, 0))
        if count <= 0:
            err = ctypes.get_errno()
            raise InventoryError(f"proc_listpids sizing failed: errno={err}")
        capacity = max(1024, count // ctypes.sizeof(ctypes.c_int) + 256)
        for _ in range(8):
            array = (ctypes.c_int * capacity)()
            byte_capacity = ctypes.sizeof(array)
            size = int(self._libproc.proc_listpids(1, 0, array, byte_capacity))
            if size <= 0:
                raise InventoryError(f"proc_listpids failed: errno={ctypes.get_errno()}")
            if size < byte_capacity:
                break
            capacity *= 2
        else:
            raise InventoryError("proc_listpids remained possibly truncated")
        result: dict[int, Credentials] = {}
        for pid in array[: size // ctypes.sizeof(ctypes.c_int)]:
            if pid <= 0:
                continue
            info = DarwinProcBSDInfo()
            got = int(self._libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)))
            if got == 0:
                if ctypes.get_errno() in (errno.ESRCH, 0):
                    continue
                raise InventoryError(f"proc_pidinfo unreadable for pid {pid}: errno={ctypes.get_errno()}")
            if got != ctypes.sizeof(info):
                raise InventoryError(f"proc_pidinfo short read for pid {pid}: {got}")
            # macOS has no public API for enumerating another process's supplementary groups.
            # The residual risk is accepted because (1) the leased GID is an unassigned-high
            # system GID on ephemeral clean runners; (2) the child already setgroups([]) clears
            # its own supplementary groups; (3) private roots are mode 0700 with no group
            # permission bits, so no group-permissioned cross-channel exists even if another
            # process shared the GID.
            result[pid] = Credentials(
                pid,
                (int(info.pbi_ruid), int(info.pbi_uid), int(info.pbi_svuid), int(info.pbi_uid)),
                (int(info.pbi_rgid), int(info.pbi_gid), int(info.pbi_svgid), int(info.pbi_gid)),
                zombie=int(info.pbi_status) == 5,
            )
        return result

    def credential_absent(self, uid: int, gid: int) -> bool:
        try:
            pwd.getpwuid(uid)
            return False
        except KeyError:
            pass
        try:
            grp.getgrgid(gid)
            return False
        except KeyError:
            pass
        for item in self.inventory().values():
            if uid in item.uids or gid in item.gids or gid in item.supplementary_gids:
                return False
        return True

    def pid_credentials(self, pid: int) -> Credentials:
        if self.name == "linux":
            try:
                return self._linux_pid_credentials(pid)
            except InventoryError as exc:
                if isinstance(exc.__cause__, FileNotFoundError):
                    raise InventoryError(f"blocked child {pid} disappeared before credential verification") from exc
                raise
        inventory = self._darwin_inventory_for_pids((pid,))
        item = inventory.get(pid)
        if item is None:
            raise InventoryError(f"blocked child {pid} disappeared before credential verification")
        return item

    def _darwin_inventory_for_pids(self, pids: tuple[int, ...]) -> dict[int, Credentials]:
        result: dict[int, Credentials] = {}
        for pid in pids:
            info = DarwinProcBSDInfo()
            got = int(self._libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)))
            if got == 0:
                if ctypes.get_errno() in (errno.ESRCH, 0):
                    continue
                raise InventoryError(f"proc_pidinfo unreadable for pid {pid}: errno={ctypes.get_errno()}")
            if got != ctypes.sizeof(info):
                raise InventoryError(f"proc_pidinfo short read for pid {pid}: {got}")
            result[pid] = Credentials(
                pid,
                (int(info.pbi_ruid), int(info.pbi_uid), int(info.pbi_svuid), int(info.pbi_uid)),
                (int(info.pbi_rgid), int(info.pbi_gid), int(info.pbi_svgid), int(info.pbi_gid)),
                zombie=int(info.pbi_status) == 5,
            )
        return result

    def verify_pid(self, pid: int, uid: int, gid: int) -> Credentials:
        item = self.pid_credentials(pid)
        if any(value != uid for value in item.uids[:3]):
            raise ContainmentError(f"blocked child uid tuple is {item.uids}, expected {uid}")
        if any(value != gid for value in item.gids[:3]):
            raise ContainmentError(f"blocked child gid tuple is {item.gids}, expected {gid}")
        if self.name == "linux":
            if item.no_new_privs != 1:
                raise ContainmentError("blocked child does not have NO_NEW_PRIVS")
            if item.capabilities_clear is not True:
                raise ContainmentError("blocked child retains Linux capabilities")
        return item

    def domain_members(self, uid: int, *, live_only: bool = False) -> list[int]:
        return sorted(
            pid for pid, item in self.inventory().items()
            if uid in item.uids[:3] and (not live_only or not item.zombie)
        )


def clear_linux_privileges() -> None:
    libc = ctypes.CDLL(None, use_errno=True)

    class CapHeader(ctypes.Structure):
        _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]

    class CapData(ctypes.Structure):
        _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32), ("inheritable", ctypes.c_uint32)]

    header = CapHeader(0x20080522, 0)
    data = (CapData * 2)()
    if libc.capset(ctypes.byref(header), ctypes.byref(data)) != 0:
        raise OSError(ctypes.get_errno(), "capset")
    PR_CAP_AMBIENT = 47
    PR_CAP_AMBIENT_CLEAR_ALL = 4
    if libc.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0:
        err = ctypes.get_errno()
        if err not in (errno.EINVAL,):
            raise OSError(err, "prctl(PR_CAP_AMBIENT_CLEAR_ALL)")
    if libc.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_NO_NEW_PRIVS)")


def drop_credentials(uid: int, gid: int) -> None:
    os.setgroups([])
    if sys.platform.startswith("linux"):
        os.setresgid(gid, gid, gid)
        os.setresuid(uid, uid, uid)
        clear_linux_privileges()
    elif sys.platform == "darwin":
        os.setgid(gid)
        os.setuid(uid)
    else:
        raise OSError(errno.ENOTSUP, "unsupported credential platform")


def helper_signal(uid: int, gid: int, sig: int) -> tuple[bool, int]:
    """Signal/probe exactly one credential domain through a dropped helper."""
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        code = 0
        try:
            drop_credentials(uid, gid)
            os.kill(-1, sig)
        except OSError as exc:
            code = exc.errno or errno.EIO
        except BaseException:
            code = errno.EIO
        try:
            os.write(write_fd, str(code).encode("ascii"))
        finally:
            os._exit(0)
    os.close(write_fd)
    payload = os.read(read_fd, 32)
    os.close(read_fd)
    os.waitpid(pid, 0)
    code = int(payload or b"5")
    return code == 0, code


@dataclass
class Lease:
    uid: int
    gid: int
    path: pathlib.Path
    quarantined: bool = False


class LeasePool:
    def __init__(self, platform: CredentialPlatform, seed: str, directory: pathlib.Path) -> None:
        self.platform = platform
        self.directory = directory
        self._ensure_root_directory(self.directory)
        self.offset = int(hashlib.sha256(seed.encode()).hexdigest()[:8], 16) % (UID_MAX - UID_MIN + 1)
        self.allocated: set[int] = set()

    @staticmethod
    def _ensure_root_directory(directory: pathlib.Path) -> None:
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            pass
        metadata = directory.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_gid != 0:
            raise ContainmentError("credential lease namespace is not root-owned")
        os.chmod(directory, 0o700)

    def acquire(self) -> Lease:
        width = UID_MAX - UID_MIN + 1
        for index in range(width):
            uid = UID_MIN + ((self.offset + index) % width)
            if uid in self.allocated:
                continue
            if not self.platform.credential_absent(uid, uid):
                continue
            path = self.directory / f"uid-{uid}.lease"
            if path.with_suffix(".quarantine").exists():
                continue
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                continue
            with os.fdopen(fd, "w", encoding="ascii") as stream:
                stream.write(f"pid={os.getpid()} uid={uid}\n")
                stream.flush()
                os.fsync(stream.fileno())
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            # Re-prove after lock acquisition so another process cannot occupy it
            # between the first inventory and the root-owned lease.
            if not self.platform.credential_absent(uid, uid):
                path.unlink(missing_ok=True)
                continue
            self.allocated.add(uid)
            return Lease(uid, uid, path)
        raise ContainmentError("no unused UID/GID is available in the qualified lease range")

    def retire(self, lease: Lease, quarantine: bool) -> None:
        if quarantine:
            lease.quarantined = True
            target = lease.path.with_suffix(".quarantine")
            os.replace(lease.path, target)
            lease.path = target
        else:
            lease.path.unlink(missing_ok=True)
        directory_fd = os.open(self.directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    def finalize(self) -> None:
        pass


@dataclass
class Attempt:
    row: dict[str, Any]
    lease: Lease | None = None
    pid: int | None = None
    release_fd: int | None = None
    output_fd: int | None = None
    log_fd: int | None = None
    log_path: pathlib.Path | None = None
    started_mono: float | None = None
    deadline_mono: float | None = None
    wait_status: int | None = None
    deadline_expired: bool = False
    deadline_term_mono: float | None = None
    deadline_kill_sent: bool = False
    cleanup_ambiguous: bool = False
    tail: bytearray = field(default_factory=bytearray)


class LaneExecutor:
    def __init__(self, manifest: dict[str, Any]) -> None:
        self.manifest = manifest
        self.artifact_path = pathlib.Path(manifest["artifact"]).resolve()
        self.required = manifest.get("containment") == "required"
        self.platform: CredentialPlatform | None = None
        self.lease_pool: LeasePool | None = None
        self.preacquired_leases: dict[int, Lease] = {}
        self.selector = selectors.DefaultSelector()
        self.interrupted: int | None = None
        self.active: dict[int, Attempt] = {}
        self.run_start_mono = time.monotonic()
        self.run_start_wall = time.time()
        self.ordinary_deadline = self._to_monotonic(float(manifest["deadlines"]["ordinary_epoch"]))
        self.terminal_deadline = self._to_monotonic(float(manifest["deadlines"]["terminal_epoch"]))
        self.transient = pathlib.Path(tempfile.mkdtemp(prefix="fm-test-executor."))
        os.chmod(self.transient, 0o711)
        self.diagnostics = self.artifact_path.parent / f"{self.artifact_path.stem}.diagnostics"
        self.diagnostics.mkdir(parents=True, exist_ok=True)
        os.chmod(self.diagnostics, 0o755)
        self.doc = self._initial_document()
        self.schedule_waves = self._build_schedule_waves(self.doc["scripts"])
        self.wave_by_index = {
            row["index"]: wave_index
            for wave_index, wave in enumerate(self.schedule_waves)
            for row in wave
        }
        self._install_signal_handlers()

    def _to_monotonic(self, epoch: float) -> float:
        return self.run_start_mono + (epoch - self.run_start_wall)

    def _initial_document(self) -> dict[str, Any]:
        scripts = []
        planned = []
        for index, item in enumerate(self.manifest.get("scripts", []), 1):
            immutable = {
                "index": index,
                "path": item["path"],
                "family": item["family"],
                "attempt": 1,
                "expected_gate_skip": item.get("expected_gate_skip", "none"),
                "duration_baseline_ms": item.get("duration_baseline_ms"),
                "duration_budget_ms": item.get("duration_budget_ms"),
                "phase": item.get("phase", "serial"),
            }
            planned.append(dict(immutable))
            scripts.append({
                **immutable,
                "events": [event("planned")],
                "terminal": None,
                "duration_ms": 0,
                "exit": None,
                "gate_skip": False,
                "duration_budget_exceeded": False,
                "duration_baseline_measured": item.get("duration_baseline_ms") is not None,
                # Test-only cleanup fault switch. Production manifests never set
                # it; a fixture uses it to drive the real required-mode terminal
                # path (non-quiescence, unreadable probe) without needing an
                # unkillable process. Ignored entirely outside required mode.
                "test_fault": item.get("test_fault"),
            })
        return {
            "schema_version": SCHEMA_VERSION,
            "kind": "fm-test-lane",
            "run_id": self.manifest["run_id"],
            "selection": self.manifest["selection"],
            "duration_budget_mode": self.manifest.get("duration_budget_mode", "warn"),
            "started_at": iso_now(),
            "finished_at": None,
            "planned": planned,
            "scripts": scripts,
            "families": [],
            "containment": {
                "mode": "required" if self.required else "developer-non-enforcing",
                "enforcing": self.required,
                "platform": sys.platform,
                "qualified": False,
                "blocker": None,
                "quarantined_uids": [],
            },
            "deadlines": dict(self.manifest["deadlines"]),
            "run": {"complete": False, "result": "incomplete", "terminal": None},
            "summary": {
                "total": len(scripts), "attempted": 0, "failed": 0,
                "skipped_gate": 0, "duration_ms": 0,
                "duration_budget_exceeded": 0, "duration_budget_missing": 0,
            },
        }

    def _install_signal_handlers(self) -> None:
        def receive(sig: int, _frame: Any) -> None:
            if self.interrupted is None:
                self.interrupted = sig
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, receive)

    def publish(self) -> None:
        atomic_json(self.artifact_path, self.doc)

    def append(self, attempt: Attempt, name: str, **values: Any) -> None:
        attempt.row["events"].append(event(name, **values))
        self.publish()

    def unsupported(self, reason: str) -> int:
        self.doc["containment"]["blocker"] = reason
        self.doc["run"] = {
            "complete": False,
            "result": "containment_unsupported",
            "terminal": event("terminal", result="containment_unsupported", reason=reason),
        }
        self.doc["finished_at"] = iso_now()
        self.publish()
        print(f"fm-test-supervisor: containment refused before test execution: {reason}", file=sys.stderr)
        return 2

    def _build_schedule_waves(self, rows: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
        jobs = max(1, int(self.manifest["jobs"]))
        waves: list[list[dict[str, Any]]] = []
        parallel: list[dict[str, Any]] = []
        for row in rows:
            if row["phase"] == "serial":
                while parallel:
                    waves.append(parallel[:jobs])
                    parallel = parallel[jobs:]
                waves.append([row])
            else:
                parallel.append(row)
                if len(parallel) == jobs:
                    waves.append(parallel)
                    parallel = []
        if parallel:
            waves.append(parallel)
        return waves

    def _schedule(self, waves: list[list[dict[str, Any]]], start: float) -> tuple[float, list[tuple[dict[str, Any], float, float]]]:
        projected = start
        launches: list[tuple[dict[str, Any], float, float]] = []
        for wave in waves:
            executions: list[tuple[dict[str, Any], float, float]] = []
            for row in wave:
                projected += STARTUP_RESERVE
                baseline_ms = row["duration_baseline_ms"]
                baseline_seconds = float(baseline_ms) / 1000.0 if baseline_ms is not None else 0.0
                executions.append((row, projected, projected + baseline_seconds))
            wave_completion = max(completion for _row, _start, completion in executions) + CLEANUP_RESERVE * len(wave)
            launches.extend((row, baseline_start, wave_completion) for row, baseline_start, _completion in executions)
            projected = wave_completion
        return projected, launches

    def _validate_schedule_window(self, start: float) -> None:
        completion, launches = self._schedule(self.schedule_waves, start)
        if completion <= self.ordinary_deadline:
            return
        for row, baseline_start, wave_completion in launches:
            if wave_completion <= self.ordinary_deadline:
                continue
            baseline_ms = row["duration_baseline_ms"]
            if baseline_ms is None:
                continue
            baseline_seconds = float(baseline_ms) / 1000.0
            tail_reserve = wave_completion - (baseline_start + baseline_seconds)
            allowance = self.ordinary_deadline - baseline_start - tail_reserve
            raise ContainmentError(
                f"manifest schedule cannot fit {row['path']}: "
                f"baseline {baseline_seconds:.1f}s, allowance {max(0.0, allowance):.1f}s "
                "before the ordinary deadline"
            )

    def _release_preacquired_leases(self) -> None:
        if self.lease_pool is None:
            return
        for lease in list(self.preacquired_leases.values()):
            if lease.path.exists() and not lease.quarantined:
                self.lease_pool.retire(lease, quarantine=False)
        self.preacquired_leases.clear()

    def _remaining_schedule_reserve(self, row: dict[str, Any]) -> float:
        unfinished = [
            candidate for candidate in self.doc["scripts"]
            if candidate.get("terminal") is None
        ]
        completion, launches = self._schedule(self._build_schedule_waves(unfinished), 0.0)
        for candidate, baseline_start, _wave_completion in launches:
            if candidate is row:
                baseline_ms = candidate["duration_baseline_ms"]
                baseline_seconds = float(baseline_ms) / 1000.0 if baseline_ms is not None else 0.0
                return max(0.0, completion - (baseline_start + baseline_seconds))
        return completion

    def preflight(self) -> None:
        if not self.required:
            self.doc["containment"]["qualified"] = False
            self.doc["containment"]["blocker"] = "developer mode does not enforce descendant containment"
            self.publish()
            return
        if os.geteuid() != 0:
            raise ContainmentError("required containment needs noninteractive uid 0 execution")
        self.platform = CredentialPlatform()
        self.platform.inventory()
        scope = str(self.manifest.get("job_scope") or self.manifest["run_id"])
        LeasePool._ensure_root_directory(LEASE_DIRECTORY_ROOT)
        scope_directory = LEASE_DIRECTORY_ROOT / hashlib.sha256(scope.encode()).hexdigest()
        self.lease_pool = LeasePool(self.platform, self.manifest["run_id"], scope_directory)
        try:
            for row in self.doc["scripts"]:
                self.preacquired_leases[row["index"]] = self.lease_pool.acquire()
            self._validate_schedule_window(time.monotonic())
        except BaseException:
            self._release_preacquired_leases()
            raise
        self.doc["containment"]["qualified"] = True
        self.publish()

    def _private_root(self, row: dict[str, Any], lease: Lease | None) -> pathlib.Path:
        root = self.transient / f"attempt-{row['index']}"
        home = root / "home"
        temp = root / "tmp"
        home.mkdir(parents=True)
        temp.mkdir()
        os.chmod(root, 0o700)
        os.chmod(home, 0o700)
        os.chmod(temp, 0o700)
        if lease is not None:
            for path in (root, home, temp):
                os.chown(path, lease.uid, lease.gid)
        gitconfig = home / ".gitconfig"
        gitconfig.write_text(f"[safe]\n\tdirectory = {self.manifest['root']}\n", encoding="utf-8")
        if lease is not None:
            os.chown(gitconfig, lease.uid, lease.gid)
        return root

    @staticmethod
    def _allowed_env_key(key: str) -> bool:
        if any(part in key.upper() for part in SECRET_SUBSTRINGS):
            return False
        if key in ALLOWED_ENV_NAMES:
            return True
        return key.startswith(ALLOWED_ENV_PREFIXES)

    def _child_environment(self, private: pathlib.Path) -> dict[str, str]:
        # Default-deny: build the child environment from the explicit allowlist,
        # never from the ambient inheritance. Fleet routing and unknown ambient
        # variables are dropped because they are not on the list, not because
        # they were individually blocked.
        source = self.manifest.get("environment", {})
        env = {key: value for key, value in source.items() if self._allowed_env_key(key)}
        env["FM_BACKEND_DISABLE_CMUX_FALLBACK"] = "1"
        env["HOME"] = str(private / "home")
        env["TMPDIR"] = str(private / "tmp")
        env["TMP"] = str(private / "tmp")
        env["TEMP"] = str(private / "tmp")
        env["GIT_CONFIG_GLOBAL"] = str(private / "home" / ".gitconfig")
        env["FM_TEST_CONTAINMENT_MODE"] = "required" if self.required else "developer-non-enforcing"
        return env

    def start(self, row: dict[str, Any]) -> Attempt | None:
        attempt = Attempt(row)
        baseline_ms = row.get("duration_baseline_ms")
        baseline_seconds = float(baseline_ms) / 1000.0 if baseline_ms is not None else 0.0
        budget_ms = row.get("duration_budget_ms") or 30000
        lease: Lease | None = None
        started_committed = False
        try:
            if self.required:
                assert self.lease_pool is not None
                lease = self.preacquired_leases.pop(row["index"])
                attempt.lease = lease
                self.append(attempt, "lease_acquired", uid=lease.uid, gid=lease.gid)
            private = self._private_root(row, lease)
            read_output, write_output = os.pipe()
            read_ready, write_ready = os.pipe()
            read_release, write_release = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(read_output)
                os.close(read_ready)
                os.close(write_release)
                try:
                    if self.required:
                        assert lease is not None
                        drop_credentials(lease.uid, lease.gid)
                    else:
                        os.setsid()
                    ready = {
                        "pid": os.getpid(), "uid": os.getuid(), "euid": os.geteuid(),
                        "gid": os.getgid(), "egid": os.getegid(),
                    }
                    os.write(write_ready, (json.dumps(ready) + "\n").encode())
                    os.close(write_ready)
                    if os.read(read_release, 1) != b"R":
                        os._exit(126)
                    os.close(read_release)
                    os.dup2(write_output, 1)
                    os.dup2(write_output, 2)
                    os.close(write_output)
                    os.chdir(self.manifest["root"])
                    env = self._child_environment(private)
                    os.execve(self.manifest["bash"], [self.manifest["bash"], row["path"]], env)
                except BaseException as exc:
                    try:
                        os.write(write_ready, (json.dumps({"error": repr(exc)}) + "\n").encode())
                    except OSError:
                        pass
                    os._exit(126)
            os.close(write_output)
            os.close(write_ready)
            os.close(read_release)
            attempt.pid = pid
            attempt.release_fd = write_release
            attempt.output_fd = read_output
            os.set_blocking(read_output, False)
            ready_payload = b""
            os.set_blocking(read_ready, False)
            ready_limit = time.monotonic() + 3.0
            while b"\n" not in ready_payload and time.monotonic() < ready_limit:
                self._service_active()
                try:
                    chunk = os.read(read_ready, 4096)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    ready_payload += chunk
                    continue
                time.sleep(0.01)
            os.close(read_ready)
            ready = json.loads(ready_payload.splitlines()[0]) if ready_payload else {}
            if "error" in ready:
                raise ContainmentError(f"blocked child credential setup failed: {ready['error']}")
            if ready.get("pid") != pid:
                raise ContainmentError("blocked child readiness identity mismatch")
            if self.required:
                assert self.platform is not None and lease is not None
                self.platform.verify_pid(pid, lease.uid, lease.gid)
            log_path = self.diagnostics / f"{row['index']:03d}-{pathlib.Path(row['path']).name}.log"
            attempt.log_path = log_path
            attempt.log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            row["diagnostic_log"] = str(log_path)
            self.append(attempt, "prepared", uid=lease.uid if lease else os.getuid())
            self.selector.register(read_output, selectors.EVENT_READ, attempt)
            self.active[pid] = attempt
            attempt.started_mono = time.monotonic()
            reserved = self._remaining_schedule_reserve(row) if self.required else 0.0
            attempt.deadline_mono = min(
                attempt.started_mono + float(budget_ms) / 1000.0,
                self.ordinary_deadline - reserved,
            )
            if self.required and baseline_ms is not None and attempt.deadline_mono - attempt.started_mono < baseline_seconds:
                raise ContainmentError(f"startup exceeded the reserved window for {row['path']}")
            row["attempt_count"] = 1
            self.doc["summary"]["attempted"] += 1
            try:
                allowance = max(0.0, attempt.deadline_mono - attempt.started_mono)
                self.append(attempt, "started", allowance_ms=int(allowance * 1000))
                started_committed = True
            except AtomicJsonError as exc:
                started_committed = exc.published
                if not started_committed:
                    row.pop("attempt_count", None)
                    row["events"] = [item for item in row["events"] if item.get("name") != "started"]
                    self.doc["summary"]["attempted"] -= 1
                raise
            except BaseException:
                row.pop("attempt_count", None)
                row["events"] = [item for item in row["events"] if item.get("name") != "started"]
                self.doc["summary"]["attempted"] -= 1
                raise
            os.write(write_release, b"R")
            os.close(write_release)
            attempt.release_fd = None
            return attempt
        except BaseException as exc:
            reason = str(exc)
            if attempt.release_fd is not None:
                try:
                    os.close(attempt.release_fd)
                except OSError:
                    pass
                attempt.release_fd = None
            if started_committed:
                row["events"].append(event("containment_error", reason=reason))
                self.finish(attempt, "startup_failure")
                return None
            if attempt.pid is not None:
                self.active.pop(attempt.pid, None)
            if attempt.output_fd is not None:
                try:
                    self.selector.unregister(attempt.output_fd)
                except (KeyError, ValueError):
                    pass
            reason = str(exc)
            row["events"].append(event("readiness_refused", reason=reason))
            if lease is not None:
                quiet, _survivors = self._cleanup_domain(attempt, "readiness_refused")
            else:
                quiet = True
            if lease is None and attempt.pid is not None:
                try:
                    os.kill(attempt.pid, signal.SIGKILL)
                    os.waitpid(attempt.pid, 0)
                except OSError:
                    pass
            row["terminal"] = event("terminal", result="containment_refused", exit=126, attempted=False, reason=reason)
            row["exit"] = 126
            self.publish()
            if lease is not None and self.lease_pool is not None:
                self.lease_pool.retire(lease, quarantine=not quiet)
            return None

    def _drain(self, attempt: Attempt) -> None:
        if attempt.output_fd is None:
            return
        while True:
            try:
                chunk = os.read(attempt.output_fd, 65536)
            except BlockingIOError:
                return
            except OSError:
                chunk = b""
            if not chunk:
                try:
                    self.selector.unregister(attempt.output_fd)
                except (KeyError, ValueError):
                    pass
                os.close(attempt.output_fd)
                attempt.output_fd = None
                return
            if attempt.log_fd is not None:
                os.write(attempt.log_fd, chunk)
            attempt.tail.extend(chunk)
            if len(attempt.tail) > OUTPUT_TAIL_BYTES:
                del attempt.tail[:-OUTPUT_TAIL_BYTES]

    def _poll_wait(self, attempt: Attempt) -> bool:
        if attempt.wait_status is not None or attempt.pid is None:
            return attempt.wait_status is not None
        try:
            found, status = os.waitpid(attempt.pid, os.WNOHANG)
        except ChildProcessError:
            found, status = attempt.pid, 1 << 8
        if found == attempt.pid:
            attempt.wait_status = status
            return True
        return False

    @staticmethod
    def _exit_code(status: int | None) -> int:
        if status is None:
            return 1
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return 128 + os.WTERMSIG(status)
        return 1

    def _expire_attempt(self, attempt: Attempt) -> None:
        if attempt.deadline_expired:
            return
        attempt.deadline_expired = True
        attempt.deadline_term_mono = time.monotonic()
        self.append(attempt, "deadline_expired")
        if self.required and attempt.lease is not None:
            try:
                delivered, code = helper_signal(attempt.lease.uid, attempt.lease.gid, signal.SIGTERM)
            except BaseException:
                delivered, code = False, errno.EIO
            if not delivered:
                attempt.cleanup_ambiguous = True
            attempt.row["events"].append(event("domain_signaled", signal="TERM", delivered=delivered, errno=code))
        elif attempt.pid is not None:
            try:
                os.killpg(attempt.pid, signal.SIGTERM)
            except OSError:
                pass

    def _escalate_expired_attempt(self, attempt: Attempt, now: float, *, force: bool = False) -> None:
        if (
            not self.required
            or not attempt.deadline_expired
            or attempt.deadline_kill_sent
            or attempt.deadline_term_mono is None
            or (not force and now < attempt.deadline_term_mono + TERM_GRACE)
        ):
            return
        assert attempt.lease is not None
        try:
            delivered, code = helper_signal(attempt.lease.uid, attempt.lease.gid, signal.SIGKILL)
        except BaseException:
            delivered, code = False, errno.EIO
        attempt.deadline_kill_sent = True
        if not delivered:
            attempt.cleanup_ambiguous = True
        attempt.row["events"].append(event("domain_signaled", signal="KILL", delivered=delivered, errno=code))

    def _enforce_other_deadlines(self, current: Attempt) -> None:
        now = time.monotonic()
        others = [attempt for attempt in self.active.values() if attempt is not current]
        for other in others:
            if other.deadline_mono is not None and now >= other.deadline_mono:
                self._expire_attempt(other)
        now = time.monotonic()
        for other in others:
            self._escalate_expired_attempt(other, now)

    def _broadcast_expired_deadlines(self) -> None:
        if not self.required:
            return
        expired = [attempt for attempt in self.active.values() if attempt.deadline_expired and not attempt.deadline_kill_sent]
        if not expired:
            return
        grace = min(self.terminal_deadline, time.monotonic() + TERM_GRACE)
        while time.monotonic() < grace:
            now = time.monotonic()
            for attempt in list(self.active.values()):
                if attempt.deadline_mono is not None and now >= attempt.deadline_mono:
                    self._expire_attempt(attempt)
                self._drain(attempt)
                self._poll_wait(attempt)
            time.sleep(0.02)
        now = time.monotonic()
        for attempt in list(self.active.values()):
            if attempt.deadline_expired:
                self._escalate_expired_attempt(attempt, now, force=True)

    def _cleanup_domain(self, attempt: Attempt, reason: str) -> tuple[bool, list[int]]:
        if not self.required:
            # Explicitly non-enforcing developer behavior. This is never used by
            # required CI and does not claim descendants that leave the session.
            if attempt.pid is not None:
                try:
                    os.killpg(attempt.pid, signal.SIGTERM)
                except OSError:
                    pass
                time.sleep(0.05)
                try:
                    os.killpg(attempt.pid, signal.SIGKILL)
                except OSError:
                    pass
                try:
                    os.waitpid(attempt.pid, 0)
                except (OSError, ChildProcessError):
                    pass
            return True, []
        assert attempt.lease is not None and self.platform is not None and self.lease_pool is not None
        lease = attempt.lease
        diagnostics: list[int] = []
        ambiguous = attempt.cleanup_ambiguous

        def checked_helper(sig: int) -> tuple[bool, int]:
            nonlocal ambiguous
            try:
                return helper_signal(lease.uid, lease.gid, sig)
            except BaseException:
                ambiguous = True
                return False, errno.EIO

        try:
            diagnostics = self.platform.domain_members(lease.uid)
            attempt.row["events"].append(event("cleanup_diagnostics", reason=reason, member_pids=diagnostics))
        except InventoryError as exc:
            ambiguous = True
            attempt.row["events"].append(event("cleanup_diagnostics_unreadable", reason=str(exc)))
        if diagnostics:
            delivered, code = checked_helper(signal.SIGTERM)
            if not delivered:
                ambiguous = True
            attempt.row["events"].append(event("domain_signaled", signal="TERM", delivered=delivered, errno=code))
        grace = time.monotonic() + TERM_GRACE
        present = bool(diagnostics)
        last_code = 0
        while time.monotonic() < grace:
            self._enforce_other_deadlines(attempt)
            self._drain(attempt)
            self._poll_wait(attempt)
            present, last_code = checked_helper(0)
            if last_code not in (0, errno.ESRCH):
                ambiguous = True
            if not present and last_code == errno.ESRCH:
                break
            time.sleep(0.05)
        limit = min(self.terminal_deadline, time.monotonic() + QUIESCE_GRACE)
        while present and time.monotonic() < limit:
            self._enforce_other_deadlines(attempt)
            delivered, code = checked_helper(signal.SIGKILL)
            if not delivered:
                ambiguous = True
            attempt.row["events"].append(event("domain_signaled", signal="KILL", delivered=delivered, errno=code))
            self._drain(attempt)
            self._poll_wait(attempt)
            present, last_code = checked_helper(0)
            if last_code not in (0, errno.ESRCH):
                ambiguous = True
            if not present and last_code == errno.ESRCH:
                break
            time.sleep(0.05)
        fault = attempt.row.get("test_fault")
        try:
            if fault == "unreadable_probe":
                raise InventoryError("test_fault injected an unreadable quiescence probe")
            survivors = self.platform.domain_members(lease.uid, live_only=True)
        except InventoryError as exc:
            ambiguous = True
            attempt.row["events"].append(event("quiescence_unreadable", reason=str(exc)))
            survivors = diagnostics
        if fault == "nonquiescent":
            attempt.row["events"].append(event("nonquiescence_injected"))
            ambiguous = True
        quiet = not ambiguous and not present and last_code == errno.ESRCH and not survivors
        attempt.row["events"].append(event("quiescence", proved=quiet, survivors=survivors, probe_errno=last_code))
        if attempt.wait_status is None and attempt.pid is not None:
            try:
                _, attempt.wait_status = os.waitpid(attempt.pid, 0)
            except (OSError, ChildProcessError):
                pass
        if not quiet:
            self.doc["containment"]["quarantined_uids"].append(lease.uid)
        return quiet, survivors

    def finish(self, attempt: Attempt, cause: str) -> None:
        if attempt.deadline_expired:
            cause = "deadline"
        self._drain(attempt)
        root_exited = self._poll_wait(attempt)
        if cause == "deadline":
            self._expire_attempt(attempt)
        elif root_exited:
            self.append(attempt, "test_exited", exit=self._exit_code(attempt.wait_status))
        elif cause == "interrupted":
            self.append(attempt, "interruption_received", signal=self.interrupted)
        quiet, survivors = self._cleanup_domain(attempt, cause)
        self._drain(attempt)
        if attempt.output_fd is not None:
            try:
                self.selector.unregister(attempt.output_fd)
            except (KeyError, ValueError):
                pass
            os.close(attempt.output_fd)
            attempt.output_fd = None
        if attempt.log_fd is not None:
            os.fsync(attempt.log_fd)
            os.close(attempt.log_fd)
            attempt.log_fd = None
        diagnostics_fd = os.open(self.diagnostics, os.O_RDONLY)
        try:
            os.fsync(diagnostics_fd)
        finally:
            os.close(diagnostics_fd)
        duration_ms = int(max(0.0, time.monotonic() - (attempt.started_mono or time.monotonic())) * 1000)
        test_exit = self._exit_code(attempt.wait_status)
        output = bytes(attempt.tail).decode("utf-8", errors="replace")
        first = next((line for line in output.splitlines() if line.strip()), "")
        gate_skip = test_exit == 0 and first.startswith("skip:")
        required_token = self.manifest.get("fail_on_gate_skip") or ""
        required_skip = bool(required_token and f"skip: {required_token}" in output)
        budget = attempt.row.get("duration_budget_ms")
        exceeded = budget is not None and duration_ms > int(budget)
        if cause == "interrupted":
            result, public_exit = "interrupted", 128 + int(self.interrupted or signal.SIGTERM)
        elif cause == "deadline":
            result, public_exit = "timeout", 124
        elif not quiet:
            result, public_exit = "containment_ambiguous", 125
        elif required_skip:
            result, public_exit = "failed", 1
        elif test_exit == 0:
            result, public_exit = "passed", 0
        else:
            result, public_exit = "failed", test_exit
        attempt.row.update({
            "duration_ms": duration_ms,
            "exit": public_exit,
            "gate_skip": gate_skip,
            "duration_budget_exceeded": exceeded,
            "output_tail": output,
            "terminal": event(
                "terminal", result=result, exit=public_exit, test_exit=test_exit,
                attempted=True, quiescent=quiet, survivors=survivors,
            ),
        })
        attempt.row["events"].append(event("terminal", result=result, exit=public_exit))
        self.publish()  # Terminal evidence precedes lease/transient finalization.
        if attempt.lease is not None and self.lease_pool is not None:
            self.lease_pool.retire(attempt.lease, quarantine=not quiet)
        if attempt.pid is not None:
            self.active.pop(attempt.pid, None)

    def _launchable(self, pending: list[dict[str, Any]]) -> dict[str, Any] | None:
        if not pending:
            return None
        row = pending[0]
        if self.required:
            if self.active:
                active_wave = self.wave_by_index[next(iter(self.active.values())).row["index"]]
                if self.wave_by_index[row["index"]] != active_wave:
                    return None
            return pending.pop(0)
        jobs = max(1, int(self.manifest["jobs"]))
        if len(self.active) >= jobs:
            return None
        if row.get("phase") == "serial" and self.active:
            return None
        if any(active.row.get("phase") == "serial" for active in self.active.values()):
            return None
        return pending.pop(0)

    def finalize(self) -> int:
        rows = self.doc["scripts"]
        attempted_rows = [row for row in rows if row.get("attempt_count") == 1]
        terminals = [row for row in rows if row.get("terminal")]
        failed = sum(1 for row in terminals if row["terminal"]["result"] != "passed")
        skipped = sum(1 for row in terminals if row.get("gate_skip"))
        exceeded = sum(1 for row in terminals if row.get("duration_budget_exceeded"))
        missing = sum(1 for row in rows if not row.get("duration_baseline_measured"))
        complete = len(terminals) == len(rows) and len(attempted_rows) == len(rows)
        if self.interrupted is not None:
            complete = False
        if self.manifest.get("duration_budget_mode") == "enforce":
            failed += exceeded + missing
        result = "passed" if complete and failed == 0 else "failed"
        if self.interrupted is not None:
            result = "interrupted"
        families: dict[str, dict[str, Any]] = {}
        for row in terminals:
            item = families.setdefault(row["family"], {"name": row["family"], "count": 0, "duration_ms": 0, "failed": 0})
            item["count"] += 1
            item["duration_ms"] += row["duration_ms"]
            item["failed"] += int(row["terminal"]["result"] != "passed")
        self.doc["families"] = sorted(families.values(), key=lambda item: item["name"])
        self.doc["summary"] = {
            "total": len(rows), "attempted": len(attempted_rows), "failed": failed,
            "skipped_gate": skipped,
            "duration_ms": int((time.monotonic() - self.run_start_mono) * 1000),
            "duration_budget_exceeded": exceeded, "duration_budget_missing": missing,
        }
        self.doc["finished_at"] = iso_now()
        self.doc["run"] = {
            "complete": complete,
            "result": result,
            "terminal": event("terminal", result=result, interrupted_signal=self.interrupted),
        }
        self.publish()
        if self.lease_pool is not None:
            self._release_preacquired_leases()
            self.lease_pool.finalize()
        shutil.rmtree(self.transient, ignore_errors=True)
        if self.interrupted is not None:
            return 128 + self.interrupted
        return 0 if result == "passed" else 1

    def _service_active(self, timeout: float = 0.0) -> None:
        for key, _mask in self.selector.select(timeout=timeout):
            self._drain(key.data)
        active = list(self.active.values())
        now = time.monotonic()
        for attempt in active:
            if (
                not attempt.deadline_expired
                and attempt.deadline_mono is not None
                and now >= attempt.deadline_mono
                and not self._poll_wait(attempt)
            ):
                self._expire_attempt(attempt)
        self._broadcast_expired_deadlines()
        for attempt in active:
            if attempt.pid not in self.active:
                continue
            if attempt.deadline_expired:
                self.finish(attempt, "deadline")
            elif self._poll_wait(attempt):
                self.finish(attempt, "exit")

    def _broadcast_interruption(self) -> None:
        attempts = list(self.active.values())
        for attempt in attempts:
            assert attempt.lease is not None
            try:
                delivered, code = helper_signal(attempt.lease.uid, attempt.lease.gid, signal.SIGTERM)
            except BaseException:
                delivered, code = False, errno.EIO
            if not delivered:
                attempt.cleanup_ambiguous = True
            attempt.row["events"].append(event("domain_signaled", signal="TERM", delivered=delivered, errno=code))
        grace = min(self.terminal_deadline, time.monotonic() + TERM_GRACE)
        while time.monotonic() < grace:
            for attempt in attempts:
                self._drain(attempt)
                self._poll_wait(attempt)
            time.sleep(0.05)
        for attempt in attempts:
            assert attempt.lease is not None
            try:
                delivered, code = helper_signal(attempt.lease.uid, attempt.lease.gid, signal.SIGKILL)
            except BaseException:
                delivered, code = False, errno.EIO
            if not delivered:
                attempt.cleanup_ambiguous = True
            attempt.row["events"].append(event("domain_signaled", signal="KILL", delivered=delivered, errno=code))

    def run(self) -> int:
        self.publish()  # Complete planned manifest exists before any preflight/launch.
        try:
            self.preflight()
        except BaseException as exc:
            self._release_preacquired_leases()
            return self.unsupported(str(exc))
        pending = list(self.doc["scripts"])
        while pending or self.active:
            if self.interrupted is not None:
                if self.required:
                    self._broadcast_interruption()
                for attempt in list(self.active.values()):
                    self.finish(attempt, "interrupted")
                break
            while True:
                row = self._launchable(pending)
                if row is None:
                    break
                self.start(row)
            self._service_active(timeout=0.02)
            if not self.active and pending and time.monotonic() >= self.ordinary_deadline:
                for row in pending:
                    row["events"].append(event("deadline_unavailable"))
                    row["terminal"] = event("terminal", result="deadline_unavailable", exit=125, attempted=False)
                    row["exit"] = 125
                pending.clear()
                self.publish()
        return self.finalize()


def artifact_terminal_metrics(rows: list[dict[str, Any]]) -> dict[str, int]:
    return {
        "total": len(rows),
        "attempted": sum(1 for row in rows if row.get("attempt_count") == 1),
        "failed": sum(1 for row in rows if row["terminal"]["result"] != "passed"),
        "skipped_gate": sum(1 for row in rows if row.get("gate_skip") is True),
        "duration_budget_exceeded": sum(1 for row in rows if row.get("duration_budget_exceeded") is True),
        "duration_budget_missing": sum(1 for row in rows if row["duration_baseline_ms"] is None),
    }


def validate_artifact_document(doc: dict[str, Any]) -> tuple[bool, str]:
    if doc.get("schema_version") != SCHEMA_VERSION or doc.get("kind") != "fm-test-lane":
        return False, "unknown or mixed artifact schema"
    planned = doc.get("planned")
    rows = doc.get("scripts")
    if not isinstance(planned, list) or not isinstance(rows, list):
        return False, "planned/scripts inventories are missing"
    if any(not isinstance(row, dict) for row in planned + rows):
        return False, "planned/executed inventory mismatch"
    if any(any(field not in row for field in IMMUTABLE_PLANNED_FIELDS) for row in planned + rows):
        return False, "planned/executed inventory mismatch"
    identities = lambda values: [(v["path"], v["attempt"]) for v in values]
    if len(set(identities(planned))) != len(planned) or len(set(identities(rows))) != len(rows):
        return False, "duplicate planned or attempted identity"
    inventory = lambda values: [tuple(v[field] for field in IMMUTABLE_PLANNED_FIELDS) for v in values]
    if inventory(planned) != inventory(rows):
        return False, "planned/executed inventory mismatch"
    for row in rows:
        events = row.get("events")
        if not isinstance(events, list) or any(not isinstance(item, dict) for item in events):
            return False, f"invalid event inventory for {row.get('path')}"
        starts = [item for item in events if item.get("name") == "started"]
        terminals = [item for item in events if item.get("name") == "terminal"]
        if row.get("attempt_count") != 1 or len(starts) != 1:
            return False, f"missing or duplicate attempt for {row.get('path')}"
        terminal = row.get("terminal")
        if (
            not isinstance(terminal, dict)
            or not isinstance(terminal.get("result"), str)
            or len(terminals) != 1
        ):
            return False, f"missing or duplicate terminal for {row.get('path')}"
    run = doc.get("run")
    if not isinstance(run, dict) or run.get("complete") is not True:
        return False, "lane artifact is incomplete"
    metrics = artifact_terminal_metrics(rows)
    budget_mode = doc.get("duration_budget_mode")
    if budget_mode not in {"warn", "enforce"}:
        return False, "lane duration-budget policy is missing or invalid"
    summary = doc.get("summary")
    if not isinstance(summary, dict):
        return False, "lane summary is inconsistent with terminal evidence"
    for field in (
        "total", "attempted", "failed", "skipped_gate",
        "duration_budget_exceeded", "duration_budget_missing",
    ):
        if not isinstance(summary.get(field), int) or isinstance(summary.get(field), bool):
            return False, "lane summary is inconsistent with terminal evidence"
    for field in (
        "total", "attempted", "skipped_gate",
        "duration_budget_exceeded", "duration_budget_missing",
    ):
        if summary[field] != metrics[field]:
            return False, "lane summary is inconsistent with terminal evidence"
    policy_failed = metrics["failed"]
    if budget_mode == "enforce":
        policy_failed += metrics["duration_budget_exceeded"] + metrics["duration_budget_missing"]
    if summary["failed"] != policy_failed:
        return False, "lane summary is inconsistent with terminal evidence"
    expected_result = "passed" if summary["failed"] == 0 else "failed"
    if run.get("result") != expected_result:
        return False, "lane result is inconsistent with terminal evidence"
    return True, "ok"


def validate_artifact(path: pathlib.Path) -> tuple[bool, str]:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"invalid JSON: {exc}"
    return validate_artifact_document(doc)


def qualification_target(uid: int, gid: int, ready_fd: int, ignore_term: bool, session_escape: bool) -> None:
    drop_credentials(uid, gid)
    if session_escape:
        os.setsid()
    if ignore_term:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(ready_fd, b"R")
    os.close(ready_fd)
    while True:
        signal.pause()


def spawn_qualification_target(uid: int, gid: int, *, ignore_term: bool = False, session_escape: bool = False) -> int:
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        try:
            qualification_target(uid, gid, write_fd, ignore_term, session_escape)
        finally:
            os._exit(127)
    os.close(write_fd)
    if os.read(read_fd, 1) != b"R":
        raise ContainmentError("qualification target did not become ready")
    os.close(read_fd)
    return pid


def spawn_reparented_target(uid: int, gid: int) -> int:
    read_fd, write_fd = os.pipe()
    parent = os.fork()
    if parent == 0:
        os.close(read_fd)
        try:
            drop_credentials(uid, gid)
            descendant = os.fork()
            if descendant == 0:
                os.setsid()
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                os.write(write_fd, f"{os.getpid()}\n".encode("ascii"))
                os.close(write_fd)
                while True:
                    signal.pause()
            os._exit(0)
        finally:
            os._exit(127)
    os.close(write_fd)
    payload = os.read(read_fd, 32)
    os.close(read_fd)
    os.waitpid(parent, 0)
    if not payload.strip().isdigit():
        raise ContainmentError("reparenting qualification target did not become ready")
    return int(payload)


def spawn_fork_storm_target(uid: int, gid: int) -> int:
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        drop_credentials(uid, gid)

        def storm(_sig: int, _frame: Any) -> None:
            for _ in range(8):
                child = os.fork()
                if child == 0:
                    try:
                        os.setsid()
                    except OSError:
                        pass
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    while True:
                        signal.pause()

        signal.signal(signal.SIGTERM, storm)
        os.write(write_fd, b"R")
        os.close(write_fd)
        while True:
            signal.pause()
    os.close(write_fd)
    if os.read(read_fd, 1) != b"R":
        raise ContainmentError("fork-storm qualification target did not become ready")
    os.close(read_fd)
    return pid


def prove_domain_quiescent(uid: int, gid: int, timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        helper_signal(uid, gid, signal.SIGKILL)
        present, code = helper_signal(uid, gid, 0)
        if not present and code == errno.ESRCH:
            return True
        time.sleep(0.02)
    return False


def qualify(artifact: pathlib.Path) -> int:
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "kind": "fm-test-platform-qualification",
        "platform": sys.platform,
        "started_at": iso_now(),
        "complete": False,
        "passed": False,
        "checks": [],
    }
    atomic_json(artifact, result)
    targets: list[tuple[int, Lease]] = []
    leases: list[Lease] = []

    def cleanup_domains() -> list[str]:
        for pid, lease in targets:
            try:
                helper_signal(lease.uid, lease.gid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (OSError, ChildProcessError):
                pass
        return [
            f"uid {lease.uid} remained non-quiescent"
            for lease in leases
            if not prove_domain_quiescent(lease.uid, lease.gid)
        ]

    try:
        if os.geteuid() != 0:
            raise ContainmentError("platform qualification requires noninteractive uid 0")
        platform = CredentialPlatform()
        qualification_leases = pathlib.Path(tempfile.mkdtemp(prefix="fm-test-qualification-leases."))
        os.chmod(qualification_leases, 0o700)
        pool = LeasePool(platform, f"qualification-{os.getpid()}", qualification_leases)
        owned = pool.acquire()
        leases.append(owned)
        sentinel = pool.acquire()
        leases.append(sentinel)
        target = spawn_qualification_target(owned.uid, owned.gid, ignore_term=True, session_escape=True)
        other = spawn_qualification_target(sentinel.uid, sentinel.gid, ignore_term=True, session_escape=True)
        targets.extend(((target, owned), (other, sentinel)))
        platform.verify_pid(target, owned.uid, owned.gid)
        platform.verify_pid(other, sentinel.uid, sentinel.gid)
        result["checks"].append({"name": "credential-tuples", "passed": True})
        # Stale-PID non-authority: the sentinel is a live process under a
        # different leased UID, and its numeric PID is exactly the kind of stale
        # value a naive cleanup would signal. Sweep only the owned UID domain
        # through the credential-scoped helper (kill(-1) from that leased
        # identity), then prove the owned domain quiesced while the sentinel is
        # untouched. The sentinel survives because signaling is UID-scoped, never
        # PID-scoped: its live PID was available throughout and never targeted.
        delivered, code = helper_signal(owned.uid, owned.gid, signal.SIGKILL)
        if not delivered or code != 0:
            raise ContainmentError(f"credential-scoped KILL failed: errno={code}")
        os.waitpid(target, 0)
        targets = [(pid, lease) for pid, lease in targets if pid != target]
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            present, probe_code = helper_signal(owned.uid, owned.gid, 0)
            if not present and probe_code == errno.ESRCH:
                break
            time.sleep(0.02)
        else:
            raise ContainmentError("owned qualification domain did not quiesce")
        # The sentinel must still be exactly the same live different-UID process:
        # same numeric PID, unchanged credential tuple, not signaled.
        platform.verify_pid(other, sentinel.uid, sentinel.gid)
        result["checks"].append({
            "name": "signal-scope-stale-pid-nonauthority", "passed": True,
            "swept_uid": owned.uid, "stale_pid_diagnostic": other, "sentinel_uid": sentinel.uid,
        })

        reparented_lease = pool.acquire()
        leases.append(reparented_lease)
        reparented = spawn_reparented_target(reparented_lease.uid, reparented_lease.gid)
        targets.append((reparented, reparented_lease))
        platform.verify_pid(reparented, reparented_lease.uid, reparented_lease.gid)
        if not prove_domain_quiescent(reparented_lease.uid, reparented_lease.gid):
            raise ContainmentError("reparented setsid qualification domain did not quiesce")
        result["checks"].append({"name": "parent-exit-reparenting-setsid", "passed": True, "diagnostic_pid": reparented})

        storm_lease = pool.acquire()
        leases.append(storm_lease)
        storm = spawn_fork_storm_target(storm_lease.uid, storm_lease.gid)
        targets.append((storm, storm_lease))
        platform.verify_pid(storm, storm_lease.uid, storm_lease.gid)
        helper_signal(storm_lease.uid, storm_lease.gid, signal.SIGTERM)
        time.sleep(0.1)
        helper_signal(storm_lease.uid, storm_lease.gid, signal.SIGKILL)
        os.waitpid(storm, 0)
        if not prove_domain_quiescent(storm_lease.uid, storm_lease.gid):
            raise ContainmentError("TERM-handler fork-storm domain did not quiesce")
        result["checks"].append({"name": "term-handler-fork-storm-quiescence", "passed": True})

        if sys.platform.startswith("linux"):
            unshare = shutil.which("unshare")
            if not unshare:
                raise ContainmentError("unshare is required for true same-PID reuse qualification")
            command = [unshare, "--fork", "--pid", "--mount-proc", sys.executable, __file__, "_pid-reuse"]
            child = os.spawnv(os.P_WAIT, unshare, command)
            if child != 0:
                raise ContainmentError(f"true same-PID namespace qualification failed with exit {child}")
            result["checks"].append({"name": "true-same-numeric-pid-reuse", "passed": True})
        # Complete cleanup and prove every leased identity quiescent and retired
        # BEFORE publishing a passing result. A surviving, unreadable, or
        # non-quiescent domain must make qualification red here, never a pass
        # printed ahead of a best-effort finally that could swallow the failure.
        cleanup_errors = cleanup_domains()
        if cleanup_errors:
            raise ContainmentError(
                f"qualification cleanup failed: {', '.join(cleanup_errors)}"
            )
        targets.clear()
        for lease in leases:
            pool.retire(lease, quarantine=False)
        leases.clear()
        result["checks"].append({"name": "all-domains-quiescent-before-publish", "passed": True})
        result.update({"complete": True, "passed": True, "finished_at": iso_now()})
        atomic_json(artifact, result)
        print(f"FM_TEST_QUALIFICATION platform={sys.platform} passed=true")
        return 0
    except BaseException as exc:
        cleanup_errors = cleanup_domains()
        blocker = str(exc)
        if cleanup_errors:
            blocker = f"{blocker}; qualification cleanup failed: {', '.join(cleanup_errors)}"
        result.update({"complete": True, "passed": False, "blocker": blocker, "finished_at": iso_now()})
        atomic_json(artifact, result)
        print(f"fm-test-supervisor: platform qualification failed: {blocker}", file=sys.stderr)
        return 1
    finally:
        cleanup_errors = cleanup_domains()
        if "pool" in locals():
            for lease in leases:
                if lease.path.exists() and not lease.quarantined:
                    pool.retire(lease, quarantine=bool(cleanup_errors))
        if "qualification_leases" in locals():
            shutil.rmtree(qualification_leases, ignore_errors=True)


def pid_reuse_fixture() -> int:
    if os.geteuid() != 0 or not sys.platform.startswith("linux"):
        return 2
    platform = CredentialPlatform()
    lease_directory = pathlib.Path(tempfile.mkdtemp(prefix="fm-test-pid-reuse-leases."))
    pool = LeasePool(platform, f"pid-reuse-{os.getpid()}", lease_directory)
    leases: list[Lease] = []
    try:
        old = pool.acquire()
        leases.append(old)
        other = pool.acquire()
        leases.append(other)
        last_pid = pathlib.Path("/proc/sys/kernel/ns_last_pid")
        last_pid.write_text("4999\n", encoding="ascii")
        target = spawn_qualification_target(old.uid, old.gid)
        if target != 5000:
            raise ContainmentError(f"controlled target PID is {target}, expected 5000")
        helper_signal(old.uid, old.gid, signal.SIGKILL)
        os.waitpid(target, 0)
        last_pid.write_text("4999\n", encoding="ascii")
        sentinel = spawn_qualification_target(other.uid, other.gid, ignore_term=True)
        if sentinel != target:
            raise ContainmentError(f"numeric PID was not reused: old={target} replacement={sentinel}")
        helper_signal(old.uid, old.gid, signal.SIGKILL)
        platform.verify_pid(sentinel, other.uid, other.gid)
        helper_signal(other.uid, other.gid, signal.SIGKILL)
        os.waitpid(sentinel, 0)
        print(f"FM_TEST_PID_REUSE old_pid={target} replacement_pid={sentinel} different_uid=true survived=true")
        return 0
    except BaseException as exc:
        print(f"fm-test-supervisor: PID reuse fixture failed: {exc}", file=sys.stderr)
        return 1
    finally:
        for lease in leases:
            quiet = prove_domain_quiescent(lease.uid, lease.gid)
            if lease.path.exists() and not lease.quarantined:
                pool.retire(lease, quarantine=not quiet)
        shutil.rmtree(lease_directory, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    execute_parser = sub.add_parser("execute")
    execute_parser.add_argument("--manifest", required=True, type=pathlib.Path)
    validate_parser = sub.add_parser("validate-artifact")
    validate_parser.add_argument("artifact", type=pathlib.Path)
    qualify_parser = sub.add_parser("qualify")
    qualify_parser.add_argument("--artifact", required=True, type=pathlib.Path)
    sub.add_parser("_pid-reuse")
    args = parser.parse_args()
    if args.command == "execute":
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        return LaneExecutor(manifest).run()
    if args.command == "validate-artifact":
        valid, reason = validate_artifact(args.artifact)
        print(f"FM_TEST_ARTIFACT_VALID valid={'true' if valid else 'false'} reason={reason}")
        return 0 if valid else 1
    if args.command == "qualify":
        return qualify(args.artifact)
    return pid_reuse_fixture()


if __name__ == "__main__":
    raise SystemExit(main())
