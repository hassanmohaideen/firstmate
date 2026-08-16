#!/usr/bin/env python3
"""Firstmate credential-domain lane executor.

Public interface:
  fm-test-supervisor.py execute --manifest MANIFEST
  fm-test-supervisor.py validate-artifact ARTIFACT
  fm-test-supervisor.py qualify --artifact ARTIFACT

The execute command is the sole owner of test attempts, deadlines, credentials,
the child-environment allowlist, signaling, cleanup, and schema-v2 evidence.
Required containment needs uid 0. The explicitly labeled developer mode is
non-enforcing and never qualifies credential-contained CI.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import fcntl
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
TERMINAL_PUBLISH_RESERVE_PER_ATTEMPT = 15.0
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


def atomic_json(
    path: pathlib.Path, value: dict[str, Any], *, directory_fd: int | None = None,
) -> None:
    temporary_name: str | None = None
    published = False
    close_directory = False
    try:
        if directory_fd is None:
            path.parent.mkdir(parents=True, exist_ok=True)
            directory_fd = os.open(path.parent, os.O_RDONLY)
            close_directory = True
        counter = getattr(atomic_json, "counter", 0) + 1
        atomic_json.counter = counter
        temporary_name = f".{path.name}.tmp.{os.getpid()}.{counter}"
        payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
        fd = os.open(
            temporary_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644,
            dir_fd=directory_fd,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(
            temporary_name, path.name,
            src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
        )
        published = True
        os.fsync(directory_fd)
    except BaseException as exc:
        raise AtomicJsonError(exc, published) from exc
    finally:
        if temporary_name is not None and directory_fd is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        if close_directory and directory_fd is not None:
            os.close(directory_fd)


def invoking_uid() -> int:
    value = os.environ.get("SUDO_UID")
    if value is None:
        return os.getuid()
    try:
        uid = int(value)
    except ValueError as exc:
        raise ContainmentError("SUDO_UID is not a valid uid") from exc
    if uid < 0:
        raise ContainmentError("SUDO_UID is not a valid uid")
    return uid


def normalized_privileged_artifact(path: pathlib.Path | str) -> pathlib.Path:
    unresolved = pathlib.Path(os.path.abspath(path))
    current = pathlib.Path(unresolved.anchor)
    components = unresolved.parts[1:]
    for index, component in enumerate(components):
        current /= component
        try:
            info = os.lstat(current)
        except FileNotFoundError as exc:
            if index == len(components) - 1:
                break
            raise ContainmentError(
                f"privileged artifact parent does not exist: {current}"
            ) from exc
        if stat.S_ISLNK(info.st_mode):
            raise ContainmentError(
                f"privileged artifact path contains a symlink: {current}"
            )
    return unresolved


def open_verified_output_directory(artifact: pathlib.Path) -> int:
    parent = artifact.parent
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    current = os.open("/", flags)
    try:
        for component in parent.parts[1:]:
            next_fd = os.open(component, flags, dir_fd=current)
            os.close(current)
            current = next_fd
        if os.fstat(current).st_uid != invoking_uid():
            raise ContainmentError(
                f"artifact directory is not owned by invoking uid {invoking_uid()}: {parent}"
            )
        for name in (artifact.name, f"{artifact.stem}.diagnostics"):
            try:
                info = os.stat(name, dir_fd=current, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(info.st_mode):
                raise ContainmentError(f"privileged output path contains a symlink: {parent / name}")
        return current
    except BaseException:
        os.close(current)
        raise


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
    exiting: bool = False
    supplementary_gids: tuple[int, ...] = ()
    identity: str = ""


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

    def inventory(self, deadline: float | None = None) -> dict[int, Credentials]:
        if self.name == "linux":
            return self._linux_inventory(deadline)
        return self._darwin_inventory(deadline)

    @staticmethod
    def _linux_pid_credentials(pid: int) -> Credentials:
        try:
            fields: dict[str, str] = {}
            for line in pathlib.Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    fields[key] = value.strip()
            stat_payload = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
            stat_fields = stat_payload[stat_payload.rfind(")") + 2:].split()
            identity = stat_fields[19]
            uids = tuple(int(v) for v in fields["Uid"].split())
            gids = tuple(int(v) for v in fields["Gid"].split())
            supplementary_gids = tuple(int(v) for v in fields["Groups"].split())
            caps = all(int(fields.get(k, "0"), 16) == 0 for k in ("CapInh", "CapPrm", "CapEff", "CapAmb"))
            return Credentials(
                pid, uids, gids, int(fields.get("NoNewPrivs", "0")), caps,
                fields.get("State", "").startswith("Z"), False, supplementary_gids,
                identity,
            )
        except (KeyError, ValueError, OSError) as exc:
            raise InventoryError(f"could not inspect /proc/{pid}/status: {exc}") from exc

    @classmethod
    def _linux_inventory(cls, deadline: float | None = None) -> dict[int, Credentials]:
        result: dict[int, Credentials] = {}
        proc = pathlib.Path("/proc")
        if not proc.is_dir():
            raise InventoryError("/proc is unavailable")
        unreadable: list[str] = []
        for entry in proc.iterdir():
            if deadline is not None and time.monotonic() >= deadline:
                raise InventoryError("credential inventory exceeded its deadline")
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

    def _darwin_inventory(self, deadline: float | None = None) -> dict[int, Credentials]:
        count = int(self._libproc.proc_listpids(1, 0, None, 0))
        if count <= 0:
            err = ctypes.get_errno()
            raise InventoryError(f"proc_listpids sizing failed: errno={err}")
        capacity = max(1024, count // ctypes.sizeof(ctypes.c_int) + 256)
        for _ in range(8):
            if deadline is not None and time.monotonic() >= deadline:
                raise InventoryError("credential inventory exceeded its deadline")
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
            if deadline is not None and time.monotonic() >= deadline:
                raise InventoryError("credential inventory exceeded its deadline")
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
            # Linux inventories every live process's /proc supplementary groups and fails
            # closed before leasing a GID held there. macOS has no public API for enumerating
            # another running process's supplementary groups, so the accepted Option A keeps
            # containment with this residual risk: (1) the leased GID is an unassigned-high
            # system GID on ephemeral clean runners; (2) the child setgroups([]) clears its own
            # supplementary groups; (3) private roots are mode 0700 with no group permission
            # bits, so no group-permissioned cross-channel exists even if another process
            # shared the GID.
            result[pid] = Credentials(
                pid,
                (int(info.pbi_ruid), int(info.pbi_uid), int(info.pbi_svuid), int(info.pbi_uid)),
                (int(info.pbi_rgid), int(info.pbi_gid), int(info.pbi_svgid), int(info.pbi_gid)),
                zombie=int(info.pbi_status) == 5,
                # PROC_FLAG_INEXIT: the kernel has committed this process to
                # exit, so it has no remaining executable context from which
                # descendants can escape. Darwin may retain this state briefly
                # after a credential-scoped KILL and waitpid.
                exiting=bool(int(info.pbi_flags) & 0x4),
                identity=f"{int(info.pbi_start_tvsec)}:{int(info.pbi_start_tvusec)}",
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
                exiting=bool(int(info.pbi_flags) & 0x4),
                identity=f"{int(info.pbi_start_tvsec)}:{int(info.pbi_start_tvusec)}",
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

    def domain_members(
        self, uid: int, *, live_only: bool = False, deadline: float | None = None,
    ) -> list[int]:
        return sorted(
            pid for pid, item in self.inventory(deadline).items()
            if uid in item.uids[:3] and (not live_only or not (item.zombie or item.exiting))
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


# The signal-0 probe runs in an unprivileged helper dropped to the exact leased
# UID, which can signal every same-UID process. ESRCH and EPERM therefore both
# prove that no signalable leased-domain member remains; EPERM accounts only for
# other-UID host processes. Treating EPERM as ambiguous would quarantine every
# normally empty domain on a multi-user host.
EMPTY_DOMAIN_PROBE_ERRNOS = (errno.ESRCH, errno.EPERM)


def domain_probe_empty(present: bool, code: int) -> bool:
    return not present and code in EMPTY_DOMAIN_PROBE_ERRNOS


def helper_signal(uid: int, gid: int, sig: int) -> tuple[bool, int]:
    """Signal/probe exactly one credential domain through a dropped helper."""
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        code = 0
        try:
            drop_credentials(uid, gid)
            if sig not in (0, signal.SIGKILL, signal.SIGSTOP):
                # Darwin includes the sender in kill(-1, signal).  Keep the
                # dropped helper alive for catchable domain signals so it can
                # report the kernel operation instead of racing its own death.
                # The target domain still receives the requested signal.
                signal.signal(sig, signal.SIG_IGN)
            os.kill(-1, sig)
            if sig == 0:
                # kill(-1, 0) is allowed to count the caller itself.  Normalize
                # that platform-dependent behavior inside the unprivileged
                # helper by inspecting the same credential domain and excluding
                # only this helper.  PIDs remain inventory diagnostics; signals
                # are still issued solely through the kernel's UID scope.
                # A zombie has no executable context and cannot create descendants.
                # Darwin can expose a just-killed helper/target as a zombie briefly
                # even after waitpid has completed, so counting zombies here makes
                # an empty credential domain spuriously non-quiescent on macOS.
                members = CredentialPlatform().domain_members(uid, live_only=True)
                code = 0 if any(member != os.getpid() for member in members) else errno.ESRCH
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
    _waited, status = os.waitpid(pid, 0)
    if not payload and sig != 0 and os.WIFSIGNALED(status) and os.WTERMSIG(status) == sig:
        # Darwin includes the caller in kill(-1, signal).  In that case the
        # helper's signal death is itself durable kernel evidence that the
        # credential-scoped operation succeeded, rather than an EIO report.
        return True, 0
    code = int(payload or str(errno.EIO).encode("ascii"))
    return code == 0, code


@dataclass
class Lease:
    uid: int
    gid: int
    path: pathlib.Path
    owner_token: str
    lock_fd: int
    quarantined: bool = False


class LeasePool:
    def __init__(self, platform: CredentialPlatform, seed: str, directory: pathlib.Path) -> None:
        self.platform = platform
        self.metadata_directory = directory
        self._ensure_root_directory(self.metadata_directory)
        self.directory = LEASE_DIRECTORY_ROOT
        if self.directory != self.metadata_directory:
            self._ensure_root_directory(self.directory)
        self.offset = int(hashlib.sha256(seed.encode()).hexdigest()[:8], 16) % (UID_MAX - UID_MIN + 1)
        self.allocated: set[int] = set()
        owner = self.platform.pid_credentials(os.getpid())
        if not owner.identity:
            raise ContainmentError("credential lease owner has no stable process identity")
        self.owner_pid = os.getpid()
        self.owner_identity = owner.identity
        self.owner_token = hashlib.sha256(
            f"{self.owner_pid}:{self.owner_identity}:{seed}".encode()
        ).hexdigest()

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

    def _sync_directory(self) -> None:
        directory_fd = os.open(self.directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    @staticmethod
    def _read_lock_fd(fd: int) -> dict[str, Any] | None:
        try:
            metadata = os.fstat(fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_gid != 0:
                return None
            if metadata.st_size > 4096:
                return None
            os.lseek(fd, 0, os.SEEK_SET)
            value = json.loads(os.read(fd, 4097).decode("ascii"))
            if not isinstance(value, dict):
                return None
            return value
        except (OSError, UnicodeError, json.JSONDecodeError):
            return None

    def _reclaim_stale_lock(self, path: pathlib.Path, uid: int) -> bool:
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(path, flags)
        except OSError:
            return False
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (BlockingIOError, OSError):
                return False
            value = self._read_lock_fd(fd)
            if value is None or value.get("version") != 1 or value.get("uid") != uid:
                return False
            owner_pid = value.get("owner_pid")
            owner_identity = value.get("owner_identity")
            if not isinstance(owner_pid, int) or owner_pid <= 0 or not isinstance(owner_identity, str):
                return False
            try:
                inventory = self.platform.inventory(deadline=time.monotonic() + 1.0)
            except InventoryError:
                return False
            owner = inventory.get(owner_pid)
            if owner is not None and (not owner.identity or owner.identity == owner_identity):
                return False
            path_metadata = path.lstat()
            lock_metadata = os.fstat(fd)
            if (path_metadata.st_dev, path_metadata.st_ino) != (lock_metadata.st_dev, lock_metadata.st_ino):
                return False
            path.unlink()
            self._sync_directory()
            return True
        except OSError:
            return False
        finally:
            os.close(fd)

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
                fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                if not self._reclaim_stale_lock(path, uid):
                    continue
                try:
                    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
                except FileExistsError:
                    continue
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            record = {
                "version": 1,
                "uid": uid,
                "owner_pid": self.owner_pid,
                "owner_identity": self.owner_identity,
                "owner_token": self.owner_token,
            }
            payload = (json.dumps(record, sort_keys=True) + "\n").encode("ascii")
            os.write(fd, payload)
            os.fsync(fd)
            self._sync_directory()
            if not self.platform.credential_absent(uid, uid):
                path.unlink(missing_ok=True)
                os.close(fd)
                self._sync_directory()
                continue
            self.allocated.add(uid)
            return Lease(uid, uid, path, self.owner_token, fd)
        raise ContainmentError("no unused UID/GID is available in the qualified lease range")

    def retire(self, lease: Lease, quarantine: bool) -> None:
        value = self._read_lock_fd(lease.lock_fd)
        try:
            path_metadata = lease.path.lstat()
            lock_metadata = os.fstat(lease.lock_fd)
        except OSError as exc:
            raise ContainmentError(f"credential lease disappeared for uid {lease.uid}") from exc
        if (
            value is None
            or value.get("owner_token") != lease.owner_token
            or (path_metadata.st_dev, path_metadata.st_ino) != (lock_metadata.st_dev, lock_metadata.st_ino)
        ):
            raise ContainmentError(f"credential lease ownership changed for uid {lease.uid}")
        if quarantine:
            lease.quarantined = True
            target = lease.path.with_suffix(".quarantine")
            os.replace(lease.path, target)
            lease.path = target
        else:
            lease.path.unlink()
        os.close(lease.lock_fd)
        lease.lock_fd = -1
        self._sync_directory()

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
    budget_deadline_derived: bool = False
    wait_status: int | None = None
    completion_observed_mono: float | None = None
    deadline_expired: bool = False
    deadline_term_mono: float | None = None
    deadline_kill_sent: bool = False
    cleanup_ambiguous: bool = False
    tail: bytearray = field(default_factory=bytearray)
    first_meaningful_seen: bool = False
    first_meaningful_gate_skip: bool = False
    line_prefix: bytearray = field(default_factory=bytearray)
    line_has_content: bool = False
    required_skip_seen: bool = False
    token_overlap: bytes = b""
    cleanup_state: str | None = None
    cleanup_cause: str | None = None
    cleanup_next_mono: float = 0.0
    cleanup_present: bool = False
    cleanup_probe_errno: int = 0
    cleanup_quiet: bool = False
    cleanup_survivors: list[int] = field(default_factory=list)
    cleanup_unattempted: bool = False
    cleanup_reason: str | None = None


class LaneExecutor:
    def __init__(self, manifest: dict[str, Any]) -> None:
        self.manifest = manifest
        self.required = manifest.get("containment") == "required"
        self.output_directory_fd: int | None = None
        self.diagnostics_fd: int | None = None
        if self.required and os.geteuid() == 0:
            self.artifact_path = normalized_privileged_artifact(manifest["artifact"])
            self.output_directory_fd = open_verified_output_directory(self.artifact_path)
        else:
            self.artifact_path = pathlib.Path(manifest["artifact"]).resolve()
        self.platform: CredentialPlatform | None = None
        self.lease_pool: LeasePool | None = None
        self.preacquired_leases: dict[int, Lease] = {}
        self.residual_cleanup_attempts: list[Attempt] = []
        self.selector = selectors.DefaultSelector()
        self.interrupted: int | None = None
        self.active: dict[int, Attempt] = {}
        self.terminal_publications: list[Attempt] = []
        self.max_active_seen = 1
        self.run_start_mono = time.monotonic()
        self.run_start_wall = time.time()
        self.ordinary_deadline = self._to_monotonic(float(manifest["deadlines"]["ordinary_epoch"]))
        self.terminal_deadline = self._to_monotonic(float(manifest["deadlines"]["terminal_epoch"]))
        self.cleanup_deadline = self._to_monotonic(float(manifest["deadlines"]["cleanup_epoch"]))
        self.transient = pathlib.Path(tempfile.mkdtemp(prefix="fm-test-executor."))
        os.chmod(self.transient, 0o711)
        self.diagnostics = self.artifact_path.parent / f"{self.artifact_path.stem}.diagnostics"
        if self.output_directory_fd is None:
            self.diagnostics.mkdir(parents=True, exist_ok=True)
            os.chmod(self.diagnostics, 0o755)
        else:
            try:
                os.mkdir(self.diagnostics.name, 0o755, dir_fd=self.output_directory_fd)
            except FileExistsError:
                pass
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
            self.diagnostics_fd = os.open(
                self.diagnostics.name, flags, dir_fd=self.output_directory_fd,
            )
            os.fchmod(self.diagnostics_fd, 0o755)
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

    def _publication_reserve(self) -> float:
        if not self.required:
            return TERMINAL_PUBLISH_RESERVE_PER_ATTEMPT
        concurrent = min(
            max(1, int(self.manifest["jobs"])),
            max(1, len(self.doc["scripts"])),
        )
        return TERMINAL_PUBLISH_RESERVE_PER_ATTEMPT * (concurrent + 1)

    def _cleanup_limit(self) -> float:
        return min(self.terminal_deadline - self._publication_reserve(), self.cleanup_deadline)

    def _execution_deadline(self) -> float:
        return min(self.ordinary_deadline, self._cleanup_limit())

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
                "required_gate_skip_seen": False,
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
        atomic_json(self.artifact_path, self.doc, directory_fd=self.output_directory_fd)

    def close_output_directories(self) -> None:
        if self.diagnostics_fd is not None:
            os.close(self.diagnostics_fd)
            self.diagnostics_fd = None
        if self.output_directory_fd is not None:
            os.close(self.output_directory_fd)
            self.output_directory_fd = None

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
        execution_deadline = self._execution_deadline()
        completion, launches = self._schedule(self.schedule_waves, start)
        if completion <= execution_deadline:
            return
        for row, baseline_start, wave_completion in launches:
            if wave_completion <= execution_deadline:
                continue
            baseline_ms = row["duration_baseline_ms"]
            if baseline_ms is None:
                continue
            baseline_seconds = float(baseline_ms) / 1000.0
            tail_reserve = wave_completion - (baseline_start + baseline_seconds)
            allowance = execution_deadline - baseline_start - tail_reserve
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
        unfinished_waves = [
            unfinished
            for wave in self.schedule_waves
            if (unfinished := [candidate for candidate in wave if candidate.get("terminal") is None])
        ]
        completion, launches = self._schedule(unfinished_waves, 0.0)
        for candidate, baseline_start, _wave_completion in launches:
            if candidate is row:
                baseline_ms = candidate["duration_baseline_ms"]
                baseline_seconds = float(baseline_ms) / 1000.0 if baseline_ms is not None else 0.0
                return max(0.0, completion - (baseline_start + baseline_seconds))
        return completion

    def _qualify_host_primitives(self) -> None:
        assert self.platform is not None
        assert self.lease_pool is not None
        lease = self.lease_pool.acquire()
        target: int | None = None
        quiet = False
        cleanup_ambiguous = False
        failure: BaseException | None = None
        try:
            target = spawn_qualification_target(
                lease.uid, lease.gid, ignore_term=True, session_escape=True,
            )
            self.platform.verify_pid(target, lease.uid, lease.gid)
            delivered, code = helper_signal(lease.uid, lease.gid, signal.SIGTERM)
            if not delivered or code != 0:
                raise ContainmentError(f"lane-host credential-scoped TERM failed: errno={code}")
            self.platform.verify_pid(target, lease.uid, lease.gid)
            present, code = helper_signal(lease.uid, lease.gid, 0)
            if not present or code != 0:
                raise ContainmentError(f"lane-host credential-domain probe failed: errno={code}")
            delivered, code = helper_signal(lease.uid, lease.gid, signal.SIGKILL)
            if not delivered or code != 0:
                raise ContainmentError(f"lane-host credential-scoped KILL failed: errno={code}")
            if not bounded_reap(target, 2.0):
                raise ContainmentError("lane-host qualification target did not exit after KILL")
            quiet, ambiguous = prove_domain_quiescent(lease.uid, lease.gid, timeout=2.0)
            cleanup_ambiguous |= ambiguous
            if ambiguous:
                raise ContainmentError("lane-host qualification domain cleanup was ambiguous")
            if not quiet:
                raise ContainmentError("lane-host qualification domain did not quiesce")
        except BaseException as exc:
            failure = exc
            cleanup_ambiguous = True
        finally:
            if not quiet:
                try:
                    delivered, code = helper_signal(lease.uid, lease.gid, signal.SIGKILL)
                    if not delivered and code not in EMPTY_DOMAIN_PROBE_ERRNOS:
                        cleanup_ambiguous = True
                except BaseException:
                    cleanup_ambiguous = True
                if target is not None and not bounded_reap(target, 1.0):
                    cleanup_ambiguous = True
                try:
                    quiet, ambiguous = prove_domain_quiescent(lease.uid, lease.gid, timeout=1.0)
                    cleanup_ambiguous |= ambiguous
                except BaseException:
                    quiet = False
                    cleanup_ambiguous = True
                if not quiet:
                    cleanup_ambiguous = True
            self.lease_pool.retire(lease, quarantine=cleanup_ambiguous or not quiet)
        if failure is not None:
            raise ContainmentError(f"lane-host primitive qualification failed: {failure}") from failure

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
        self.lease_pool = LeasePool(
            self.platform, self.manifest["run_id"], LEASE_DIRECTORY_ROOT,
        )
        try:
            self._qualify_host_primitives()
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
        budget_ms = row.get("duration_budget_ms")
        enforce_budget = self.manifest.get("duration_budget_mode") == "enforce"
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
            log_flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
            if self.diagnostics_fd is None:
                attempt.log_fd = os.open(log_path, log_flags, 0o644)
            else:
                attempt.log_fd = os.open(
                    log_path.name, log_flags, 0o644, dir_fd=self.diagnostics_fd,
                )
            row["diagnostic_log"] = str(log_path)
            self.append(attempt, "prepared", uid=lease.uid if lease else os.getuid())
            self.selector.register(read_output, selectors.EVENT_READ, attempt)
            self.active[pid] = attempt
            self.max_active_seen = max(self.max_active_seen, len(self.active))
            attempt.started_mono = time.monotonic()
            reserved = self._remaining_schedule_reserve(row) if self.required else 0.0
            scheduling_deadline = self._execution_deadline() if self.required else self.ordinary_deadline
            attempt.deadline_mono = scheduling_deadline - reserved
            if enforce_budget and budget_ms is not None:
                budget_deadline = attempt.started_mono + float(budget_ms) / 1000.0
                attempt.budget_deadline_derived = budget_deadline <= attempt.deadline_mono
                attempt.deadline_mono = min(budget_deadline, attempt.deadline_mono)
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
                if attempt.pid is not None:
                    self.active[attempt.pid] = attempt
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
            attempt.cleanup_unattempted = True
            attempt.cleanup_reason = reason
            if attempt.pid is not None:
                self.active[attempt.pid] = attempt
                if attempt.output_fd is not None:
                    try:
                        self.selector.get_key(attempt.output_fd)
                    except KeyError:
                        self.selector.register(attempt.output_fd, selectors.EVENT_READ, attempt)
                self._begin_cleanup(attempt, "readiness_refused")
            else:
                attempt.cleanup_quiet = lease is None
                attempt.cleanup_state = "terminalize"
                self._advance_cleanup(attempt, time.monotonic())
            return None

    def _scan_output(self, attempt: Attempt, chunk: bytes, *, eof: bool = False) -> None:
        required_token = self.manifest.get("fail_on_gate_skip") or ""
        if required_token and not attempt.required_skip_seen:
            needle = f"skip: {required_token}".encode()
            searchable = attempt.token_overlap + chunk
            attempt.required_skip_seen = needle in searchable
            attempt.token_overlap = searchable[-max(0, len(needle) - 1):]
        if attempt.first_meaningful_seen:
            return
        for byte in chunk:
            if byte == 10:
                if attempt.line_has_content:
                    attempt.first_meaningful_seen = True
                    attempt.first_meaningful_gate_skip = bytes(attempt.line_prefix).startswith(b"skip:")
                    return
                attempt.line_prefix.clear()
                attempt.line_has_content = False
                continue
            if len(attempt.line_prefix) < 5:
                attempt.line_prefix.append(byte)
            if byte not in b" \t\r\v\f":
                attempt.line_has_content = True
        if eof and attempt.line_has_content:
            attempt.first_meaningful_seen = True
            attempt.first_meaningful_gate_skip = bytes(attempt.line_prefix).startswith(b"skip:")

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
                self._scan_output(attempt, b"", eof=True)
                try:
                    self.selector.unregister(attempt.output_fd)
                except (KeyError, ValueError):
                    pass
                os.close(attempt.output_fd)
                attempt.output_fd = None
                return
            if attempt.log_fd is not None:
                os.write(attempt.log_fd, chunk)
            self._scan_output(attempt, chunk)
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
            if attempt.completion_observed_mono is None:
                attempt.completion_observed_mono = time.monotonic()
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
        if attempt.completion_observed_mono is None:
            attempt.completion_observed_mono = attempt.deadline_mono or time.monotonic()
        attempt.row["events"].append(event("deadline_expired"))
        self._begin_cleanup(attempt, "deadline")

    def _begin_cleanup(self, attempt: Attempt, cause: str) -> None:
        if attempt.cleanup_state is not None:
            if attempt.deadline_expired:
                attempt.cleanup_cause = "deadline"
            return
        if attempt.deadline_expired:
            cause = "deadline"
        if attempt.completion_observed_mono is None:
            attempt.completion_observed_mono = time.monotonic()
        attempt.cleanup_cause = cause
        if cause == "exit":
            attempt.row["events"].append(event("test_exited", exit=self._exit_code(attempt.wait_status)))
        elif cause == "interrupted":
            attempt.row["events"].append(event("interruption_received", signal=self.interrupted))
        if self.required:
            attempt.cleanup_state = "term" if cause in {"deadline", "interrupted"} else "probe"
        else:
            attempt.cleanup_state = "developer_term"
        attempt.cleanup_next_mono = time.monotonic()

    def _checked_helper(self, attempt: Attempt, sig: int) -> tuple[bool, int]:
        assert attempt.lease is not None
        try:
            delivered, code = helper_signal(attempt.lease.uid, attempt.lease.gid, sig)
        except BaseException:
            delivered, code = False, errno.EIO
        if code not in (0, *EMPTY_DOMAIN_PROBE_ERRNOS):
            attempt.cleanup_ambiguous = True
        if sig != 0 and not delivered and code not in EMPTY_DOMAIN_PROBE_ERRNOS:
            attempt.cleanup_ambiguous = True
        return delivered, code

    def _queue_terminalization(self, attempt: Attempt) -> None:
        if attempt.cleanup_state == "publication_queued":
            return
        attempt.cleanup_state = "publication_queued"
        self.terminal_publications.append(attempt)

    def _publish_one_terminal(self) -> None:
        if not self.terminal_publications:
            return
        attempt = self.terminal_publications.pop(0)
        # Publication stays synchronous because this privileged executor forks;
        # threads would make fork-time library locks unsafe. Deadline enforcement
        # therefore has jitter bounded by one terminal fsync publication, not a
        # sub-millisecond bound. The scaled publication reserve lands all terminal
        # evidence by T0+450, and the mandated 120-second job margin absorbs this
        # accepted sub-second enforcement jitter before the T0+600 ceiling.
        self._terminalize_attempt(attempt)

    def _terminalize_attempt(self, attempt: Attempt) -> None:
        cause = "deadline" if attempt.deadline_expired else str(attempt.cleanup_cause)
        self._drain(attempt)
        self._poll_wait(attempt)
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
        if self.diagnostics_fd is None:
            diagnostics_fd = os.open(self.diagnostics, os.O_RDONLY)
            try:
                os.fsync(diagnostics_fd)
            finally:
                os.close(diagnostics_fd)
        else:
            os.fsync(self.diagnostics_fd)
        quiet = attempt.cleanup_quiet
        survivors = attempt.cleanup_survivors
        if attempt.cleanup_unattempted:
            result, public_exit = "containment_refused", 126
            attempt.row["terminal"] = event(
                "terminal", result=result, exit=public_exit, attempted=False,
                reason=attempt.cleanup_reason, quiescent=quiet, survivors=survivors,
            )
            attempt.row["exit"] = public_exit
        else:
            completion_mono = attempt.completion_observed_mono
            if attempt.deadline_expired and attempt.deadline_mono is not None:
                completion_mono = attempt.deadline_mono
            if completion_mono is None:
                completion_mono = attempt.started_mono or time.monotonic()
            duration_ms = int(max(0.0, completion_mono - (attempt.started_mono or completion_mono)) * 1000)
            test_exit = self._exit_code(attempt.wait_status)
            required_skip = attempt.required_skip_seen
            budget = attempt.row.get("duration_budget_ms")
            exceeded = budget is not None and duration_ms > int(budget)
            if cause == "deadline" and attempt.deadline_expired and attempt.budget_deadline_derived:
                exceeded = True
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
                "gate_skip": test_exit == 0 and attempt.first_meaningful_gate_skip,
                "required_gate_skip_seen": required_skip,
                "duration_budget_exceeded": exceeded,
                "output_tail": bytes(attempt.tail).decode("utf-8", errors="replace"),
                "terminal": event(
                    "terminal", result=result, exit=public_exit, test_exit=test_exit,
                    attempted=True, quiescent=quiet, survivors=survivors,
                ),
            })
        attempt.row["events"].append(event("terminal", result=result, exit=public_exit))
        self.publish()
        if attempt.lease is not None and self.lease_pool is not None:
            self.lease_pool.retire(attempt.lease, quarantine=not quiet)
            if not quiet:
                if attempt.lease.uid not in self.doc["containment"]["quarantined_uids"]:
                    self.doc["containment"]["quarantined_uids"].append(attempt.lease.uid)
                attempt.cleanup_state = "residual_probe"
                attempt.cleanup_next_mono = time.monotonic()
                self.residual_cleanup_attempts.append(attempt)
        if attempt.pid is not None:
            self.active.pop(attempt.pid, None)
        if quiet or attempt.lease is None:
            attempt.cleanup_state = "done"

    def _advance_cleanup(self, attempt: Attempt, now: float) -> None:
        state = attempt.cleanup_state
        if state is None or state in {"done", "publication_queued"} or now < attempt.cleanup_next_mono:
            return
        if state == "developer_term":
            if attempt.pid is not None:
                try:
                    os.killpg(attempt.pid, signal.SIGTERM)
                except OSError:
                    pass
            attempt.cleanup_state = "developer_kill"
            attempt.cleanup_next_mono = now + 0.05
            return
        if state == "developer_kill":
            if attempt.pid is not None:
                try:
                    os.killpg(attempt.pid, signal.SIGKILL)
                except OSError:
                    pass
            attempt.cleanup_quiet = True
            attempt.cleanup_state = "terminalize"
            return
        if state == "terminalize":
            self._queue_terminalization(attempt)
            return
        if not self.required or attempt.lease is None:
            attempt.cleanup_quiet = True
            attempt.cleanup_state = "terminalize"
            return
        if now >= self._cleanup_limit() and state not in {"residual_probe", "residual_kill"}:
            attempt.cleanup_ambiguous = True
            attempt.cleanup_survivors = [attempt.pid] if attempt.pid is not None and not self._poll_wait(attempt) else []
            attempt.row["events"].append(event("quiescence", proved=False, survivors=attempt.cleanup_survivors))
            attempt.cleanup_state = "terminalize"
            return
        if state == "probe":
            present, code = self._checked_helper(attempt, 0)
            if attempt.row.get("test_fault") == "unreadable_probe":
                present, code = False, errno.EIO
                attempt.cleanup_ambiguous = True
                attempt.row["events"].append(event("quiescence_unreadable", reason="test_fault injected an unreadable quiescence probe"))
            attempt.cleanup_present = present
            attempt.cleanup_probe_errno = code
            attempt.row["events"].append(event("cleanup_probe", reason=attempt.cleanup_cause, present=present, errno=code))
            if domain_probe_empty(present, code):
                if attempt.row.get("test_fault") == "nonquiescent":
                    attempt.cleanup_ambiguous = True
                    attempt.row["events"].append(event("nonquiescence_injected"))
                attempt.cleanup_quiet = not attempt.cleanup_ambiguous
                attempt.row["events"].append(event("quiescence", proved=attempt.cleanup_quiet, survivors=[], probe_errno=code))
                attempt.cleanup_state = "terminalize"
            else:
                attempt.cleanup_state = "term"
            return
        if state == "term":
            delivered, code = self._checked_helper(attempt, signal.SIGTERM)
            attempt.row["events"].append(event("domain_signaled", signal="TERM", delivered=delivered, errno=code))
            attempt.cleanup_state = "kill"
            attempt.cleanup_next_mono = min(self._cleanup_limit(), now + TERM_GRACE)
            return
        if state == "kill":
            delivered, code = self._checked_helper(attempt, signal.SIGKILL)
            attempt.deadline_kill_sent = attempt.deadline_expired
            attempt.row["events"].append(event("domain_signaled", signal="KILL", delivered=delivered, errno=code))
            attempt.cleanup_state = "quiescence_probe"
            attempt.cleanup_next_mono = now + 0.05
            return
        if state == "quiescence_probe":
            present, code = self._checked_helper(attempt, 0)
            attempt.cleanup_present = present
            attempt.cleanup_probe_errno = code
            if domain_probe_empty(present, code):
                attempt.cleanup_quiet = not attempt.cleanup_ambiguous
                attempt.row["events"].append(event("quiescence", proved=attempt.cleanup_quiet, survivors=[], probe_errno=code))
                attempt.cleanup_state = "terminalize"
            else:
                attempt.cleanup_state = "kill"
                attempt.cleanup_next_mono = now + 0.05
            return
        if state == "residual_probe":
            if now >= self.cleanup_deadline:
                attempt.cleanup_state = "done"
                return
            present, code = self._checked_helper(attempt, 0)
            if domain_probe_empty(present, code):
                attempt.cleanup_state = "done"
            else:
                attempt.cleanup_state = "residual_kill"
            return
        if state == "residual_kill":
            if now >= self.cleanup_deadline:
                attempt.cleanup_state = "done"
                return
            self._checked_helper(attempt, signal.SIGKILL)
            attempt.cleanup_state = "residual_probe"
            attempt.cleanup_next_mono = now + 0.05

    def finish(self, attempt: Attempt, cause: str) -> None:
        self._begin_cleanup(attempt, cause)

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
        budget_mode = self.manifest.get("duration_budget_mode", "warn")
        failed = artifact_failed_script_count(rows, budget_mode)
        skipped = sum(1 for row in terminals if row.get("gate_skip"))
        exceeded = sum(1 for row in terminals if row.get("duration_budget_exceeded"))
        missing = sum(1 for row in rows if not row.get("duration_baseline_measured"))
        complete = len(terminals) == len(rows) and len(attempted_rows) == len(rows)
        if self.interrupted is not None:
            complete = False
        policy_failed = any(row["terminal"]["result"] != "passed" for row in terminals)
        if budget_mode == "enforce":
            policy_failed = policy_failed or exceeded > 0 or missing > 0
        result = "passed" if complete and not policy_failed else "failed"
        if self.interrupted is not None:
            result = "interrupted"
        families: dict[str, dict[str, Any]] = {}
        for row in terminals:
            item = families.setdefault(row["family"], {"name": row["family"], "count": 0, "duration_ms": 0, "failed": 0})
            item["count"] += 1
            item["duration_ms"] += row["duration_ms"]
            item["failed"] += int(
                row["terminal"]["result"] != "passed"
                or (
                    budget_mode == "enforce"
                    and (row.get("duration_budget_exceeded") or not row.get("duration_baseline_measured"))
                )
            )
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
        for attempt in active:
            self._drain(attempt)
            root_exited = self._poll_wait(attempt)
            observed = attempt.completion_observed_mono
            deadline_elapsed = (
                attempt.deadline_mono is not None
                and (
                    (observed is not None and observed >= attempt.deadline_mono)
                    or (not root_exited and time.monotonic() >= attempt.deadline_mono)
                )
            )
            if attempt.cleanup_state is None and not attempt.deadline_expired and deadline_elapsed:
                self._expire_attempt(attempt)
            elif attempt.cleanup_state is None and root_exited:
                self._begin_cleanup(attempt, "exit")
        for attempt in active:
            if attempt.pid in self.active:
                self._advance_cleanup(attempt, time.monotonic())
        for attempt in list(self.residual_cleanup_attempts):
            self._advance_cleanup(attempt, time.monotonic())
            if attempt.cleanup_state == "done":
                self.residual_cleanup_attempts.remove(attempt)
        self._publish_one_terminal()

    def _broadcast_interruption(self) -> None:
        now = time.monotonic()
        for attempt in list(self.active.values()):
            if attempt.cleanup_state is None:
                self._begin_cleanup(attempt, "interrupted")
            elif not attempt.deadline_expired:
                attempt.cleanup_cause = "interrupted"
            if self.required and attempt.lease is not None:
                delivered, code = self._checked_helper(attempt, signal.SIGTERM)
                attempt.row["events"].append(event("domain_signaled", signal="TERM", delivered=delivered, errno=code))
                attempt.cleanup_state = "kill"
                attempt.cleanup_next_mono = min(self._cleanup_limit(), now + TERM_GRACE)
            else:
                self._advance_cleanup(attempt, now)

    def run(self) -> int:
        self.publish()  # Complete planned manifest exists before any preflight/launch.
        try:
            self.preflight()
        except BaseException as exc:
            self._release_preacquired_leases()
            return self.unsupported(str(exc))
        pending = list(self.doc["scripts"])
        interruption_broadcast = False
        while pending or self.active or self.residual_cleanup_attempts or self.terminal_publications:
            if self.interrupted is not None:
                pending.clear()
                if not interruption_broadcast:
                    self._broadcast_interruption()
                    interruption_broadcast = True
            while self.interrupted is None:
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


def artifact_failed_script_count(rows: list[dict[str, Any]], budget_mode: str) -> int:
    return sum(
        1
        for row in rows
        if (isinstance(row.get("terminal"), dict) and row["terminal"].get("result") != "passed")
        or (
            budget_mode == "enforce"
            and (row.get("duration_budget_exceeded") is True or row["duration_baseline_ms"] is None)
        )
    )


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
        terminal = row.get("terminal")
        if (
            not isinstance(terminal, dict)
            or not isinstance(terminal.get("result"), str)
            or len(terminals) != 1
        ):
            return False, f"missing or duplicate terminal for {row.get('path')}"
        attempted = row.get("attempt_count") == 1 and len(starts) == 1
        if terminal.get("attempted") is not attempted:
            return False, f"terminal attempt state is inconsistent for {row.get('path')}"
        if not attempted:
            return False, f"missing or duplicate attempt for {row.get('path')}"
    run = doc.get("run")
    if not isinstance(run, dict) or run.get("complete") is not True:
        return False, "lane artifact is incomplete"
    if any(
        row.get("required_gate_skip_seen") is True
        and (row["terminal"]["result"] == "passed" or run.get("result") != "failed")
        for row in rows
    ):
        return False, "required gate skip is inconsistent with terminal evidence"
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
    failed_scripts = artifact_failed_script_count(rows, budget_mode)
    if summary["failed"] != failed_scripts:
        return False, "lane summary is inconsistent with terminal evidence"
    policy_failed = metrics["failed"] > 0
    if budget_mode == "enforce":
        policy_failed = policy_failed or metrics["duration_budget_exceeded"] > 0 or metrics["duration_budget_missing"] > 0
    expected_result = "failed" if policy_failed else "passed"
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
    # An ignored disposition survives fork and exec.  CI launchers and sudo are
    # allowed to ignore job-control signals, so make the fixture's TERM behavior
    # explicit instead of accidentally inheriting the qualification caller's.
    signal.signal(signal.SIGTERM, signal.SIG_IGN if ignore_term else signal.SIG_DFL)
    drop_credentials(uid, gid)
    if session_escape:
        os.setsid()
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


def bounded_reap(pid: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            found, _status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return True
        if found == pid:
            return True
        time.sleep(0.01)
    return False


def prove_domain_quiescent(uid: int, gid: int, timeout: float = 3.0) -> tuple[bool, bool]:
    deadline = time.monotonic() + timeout
    ambiguous = False
    while time.monotonic() < deadline:
        delivered, code = helper_signal(uid, gid, signal.SIGKILL)
        if not delivered and code not in EMPTY_DOMAIN_PROBE_ERRNOS:
            ambiguous = True
        present, code = helper_signal(uid, gid, 0)
        if domain_probe_empty(present, code):
            return True, ambiguous
        if not present or code != 0:
            ambiguous = True
        time.sleep(0.02)
    return False, ambiguous


def qualify(artifact: pathlib.Path) -> int:
    try:
        artifact = normalized_privileged_artifact(artifact)
        output_directory_fd = open_verified_output_directory(artifact)
    except (ContainmentError, OSError) as exc:
        print(f"fm-test-supervisor: qualification output refused: {exc}", file=sys.stderr)
        return 2
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "kind": "fm-test-platform-qualification",
        "platform": sys.platform,
        "started_at": iso_now(),
        "complete": False,
        "passed": False,
        "checks": [],
    }
    atomic_json(artifact, result, directory_fd=output_directory_fd)
    targets: list[tuple[int, Lease]] = []
    leases: list[Lease] = []
    cleanup_ambiguities: dict[int, str] = {}

    def cleanup_domains() -> list[str]:
        errors: list[str] = []

        def ambiguous(lease: Lease, message: str) -> None:
            cleanup_ambiguities.setdefault(lease.uid, message)
            errors.append(message)
        for pid, lease in targets:
            try:
                # Prefer a catchable credential-scoped signal.  In particular,
                # Darwin's kill(-1, SIGKILL) may kill the dropped sender before
                # it can durably report completion.  Escalate only domains that
                # deliberately ignore TERM (the fork-storm fixtures).
                delivered, code = helper_signal(lease.uid, lease.gid, signal.SIGTERM)
                if not delivered and code not in EMPTY_DOMAIN_PROBE_ERRNOS:
                    ambiguous(lease, f"uid {lease.uid} TERM failed: errno={code}")
                if not bounded_reap(pid, 0.25):
                    delivered, code = helper_signal(lease.uid, lease.gid, signal.SIGKILL)
                    if not delivered and code not in EMPTY_DOMAIN_PROBE_ERRNOS:
                        ambiguous(lease, f"uid {lease.uid} KILL failed: errno={code}")
                    if not bounded_reap(pid, 1.0):
                        ambiguous(lease, f"uid {lease.uid} target did not exit")
            except BaseException as exc:
                ambiguous(lease, f"uid {lease.uid} cleanup failed: {exc}")
        for lease in leases:
            try:
                quiet, probe_ambiguous = prove_domain_quiescent(lease.uid, lease.gid)
            except BaseException as exc:
                ambiguous(lease, f"uid {lease.uid} quiescence probe failed: {exc}")
                continue
            if probe_ambiguous:
                ambiguous(lease, f"uid {lease.uid} quiescence cleanup was ambiguous")
            if not quiet:
                # Bounded Darwin non-quiescence diagnostics so a post-billing CI
                # run can distinguish zombie-reaping (pbi_status) from kill(-1)
                # delivery scope or the setgid/setuid drop: dump each surviving
                # member's pid, credential tuple, and zombie/exiting flags plus
                # the credential-scoped signal-0 probe errno.
                present, probe_errno = helper_signal(lease.uid, lease.gid, 0)
                try:
                    members = [
                        {
                            "pid": pid, "uids": item.uids, "gids": item.gids,
                            "zombie": item.zombie,
                            "exiting": getattr(item, "exiting", None),
                        }
                        for pid, item in platform.inventory().items()
                        if lease.uid in item.uids[:3]
                    ]
                except InventoryError as exc:
                    members = f"inventory unreadable: {exc}"
                ambiguous(
                    lease,
                    f"uid {lease.uid} remained non-quiescent "
                    f"(probe present={present} errno={probe_errno} members={members})",
                )
        return errors

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
        target = spawn_qualification_target(owned.uid, owned.gid, session_escape=True)
        other = spawn_qualification_target(sentinel.uid, sentinel.gid, session_escape=True)
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
        delivered, code = helper_signal(owned.uid, owned.gid, signal.SIGTERM)
        if not delivered or code != 0:
            cleanup_ambiguities.setdefault(owned.uid, f"credential-scoped TERM failed: errno={code}")
            raise ContainmentError(f"credential-scoped TERM failed: errno={code}")
        if not bounded_reap(target, 2.0):
            cleanup_ambiguities.setdefault(owned.uid, "owned qualification target did not exit after TERM")
            raise ContainmentError("owned qualification target did not exit after TERM")
        targets = [(pid, lease) for pid, lease in targets if pid != target]
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            present, probe_code = helper_signal(owned.uid, owned.gid, 0)
            if domain_probe_empty(present, probe_code):
                break
            time.sleep(0.02)
        else:
            cleanup_ambiguities.setdefault(owned.uid, "owned qualification domain did not quiesce")
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
        quiet, ambiguous = prove_domain_quiescent(reparented_lease.uid, reparented_lease.gid)
        if ambiguous:
            cleanup_ambiguities.setdefault(
                reparented_lease.uid, "reparented setsid qualification cleanup was ambiguous"
            )
            raise ContainmentError("reparented setsid qualification cleanup was ambiguous")
        if not quiet:
            cleanup_ambiguities.setdefault(
                reparented_lease.uid, "reparented setsid qualification domain did not quiesce"
            )
            raise ContainmentError("reparented setsid qualification domain did not quiesce")
        result["checks"].append({"name": "parent-exit-reparenting-setsid", "passed": True, "diagnostic_pid": reparented})

        storm_lease = pool.acquire()
        leases.append(storm_lease)
        storm = spawn_fork_storm_target(storm_lease.uid, storm_lease.gid)
        targets.append((storm, storm_lease))
        platform.verify_pid(storm, storm_lease.uid, storm_lease.gid)
        term_delivered, term_code = helper_signal(storm_lease.uid, storm_lease.gid, signal.SIGTERM)
        if not term_delivered or term_code != 0:
            cleanup_ambiguities.setdefault(
                storm_lease.uid, f"fork-storm credential-scoped TERM failed: errno={term_code}"
            )
            raise ContainmentError(f"fork-storm credential-scoped TERM failed: errno={term_code}")
        time.sleep(0.1)
        kill_delivered, kill_code = helper_signal(storm_lease.uid, storm_lease.gid, signal.SIGKILL)
        if not kill_delivered or kill_code != 0:
            cleanup_ambiguities.setdefault(
                storm_lease.uid, f"fork-storm credential-scoped KILL failed: errno={kill_code}"
            )
            raise ContainmentError(f"fork-storm credential-scoped KILL failed: errno={kill_code}")
        if not bounded_reap(storm, 2.0):
            cleanup_ambiguities.setdefault(storm_lease.uid, "fork-storm target did not exit after KILL")
            raise ContainmentError("fork-storm target did not exit after KILL")
        quiet, ambiguous = prove_domain_quiescent(storm_lease.uid, storm_lease.gid)
        if ambiguous:
            cleanup_ambiguities.setdefault(storm_lease.uid, "TERM-handler fork-storm cleanup was ambiguous")
            raise ContainmentError("TERM-handler fork-storm cleanup was ambiguous")
        if not quiet:
            cleanup_ambiguities.setdefault(storm_lease.uid, "TERM-handler fork-storm domain did not quiesce")
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
        atomic_json(artifact, result, directory_fd=output_directory_fd)
        print(f"FM_TEST_QUALIFICATION platform={sys.platform} passed=true")
        return 0
    except BaseException as exc:
        cleanup_errors = cleanup_domains()
        blocker = str(exc)
        if cleanup_errors:
            blocker = f"{blocker}; qualification cleanup failed: {', '.join(cleanup_errors)}"
        result.update({"complete": True, "passed": False, "blocker": blocker, "finished_at": iso_now()})
        atomic_json(artifact, result, directory_fd=output_directory_fd)
        print(f"fm-test-supervisor: platform qualification failed: {blocker}", file=sys.stderr)
        return 1
    finally:
        cleanup_errors = cleanup_domains()
        if "pool" in locals():
            for lease in leases:
                if lease.path.exists() and not lease.quarantined:
                    pool.retire(lease, quarantine=lease.uid in cleanup_ambiguities)
        if "qualification_leases" in locals():
            shutil.rmtree(qualification_leases, ignore_errors=True)
        os.close(output_directory_fd)


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
        delivered, code = helper_signal(old.uid, old.gid, signal.SIGKILL)
        if not delivered or code != 0:
            raise ContainmentError(f"old credential-domain KILL failed: errno={code}")
        if not bounded_reap(target, 2.0):
            raise ContainmentError("old credential-domain target did not exit after KILL")
        last_pid.write_text("4999\n", encoding="ascii")
        sentinel = spawn_qualification_target(other.uid, other.gid, ignore_term=True)
        if sentinel != target:
            raise ContainmentError(f"numeric PID was not reused: old={target} replacement={sentinel}")
        delivered, code = helper_signal(old.uid, old.gid, signal.SIGKILL)
        if not domain_probe_empty(delivered, code):
            raise ContainmentError(
                f"old credential domain remained signalable after PID reuse: errno={code}"
            )
        platform.verify_pid(sentinel, other.uid, other.gid)
        delivered, code = helper_signal(other.uid, other.gid, signal.SIGKILL)
        if not delivered or code != 0:
            raise ContainmentError(f"replacement credential-domain KILL failed: errno={code}")
        if not bounded_reap(sentinel, 2.0):
            raise ContainmentError("replacement credential-domain target did not exit after KILL")
        print(f"FM_TEST_PID_REUSE old_pid={target} replacement_pid={sentinel} different_uid=true survived=true")
        return 0
    except BaseException as exc:
        print(f"fm-test-supervisor: PID reuse fixture failed: {exc}", file=sys.stderr)
        return 1
    finally:
        for lease in leases:
            try:
                quiet, ambiguous = prove_domain_quiescent(lease.uid, lease.gid)
            except BaseException:
                quiet, ambiguous = False, True
            if lease.path.exists() and not lease.quarantined:
                pool.retire(lease, quarantine=ambiguous or not quiet)
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
        try:
            executor = LaneExecutor(manifest)
        except (ContainmentError, OSError) as exc:
            print(f"fm-test-supervisor: containment refused before test execution: {exc}", file=sys.stderr)
            return 2
        try:
            return executor.run()
        finally:
            executor.close_output_directories()
    if args.command == "validate-artifact":
        valid, reason = validate_artifact(args.artifact)
        print(f"FM_TEST_ARTIFACT_VALID valid={'true' if valid else 'false'} reason={reason}")
        return 0 if valid else 1
    if args.command == "qualify":
        return qualify(args.artifact)
    return pid_reuse_fixture()


if __name__ == "__main__":
    raise SystemExit(main())
