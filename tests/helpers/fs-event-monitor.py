#!/usr/bin/env python3
import argparse
import ctypes
import errno
import hashlib
import os
import select
import stat
import struct
import sys


def entries(roots):
    pending = list(roots)
    while pending:
        path = pending.pop()
        yield path
        try:
            with os.scandir(path) as children:
                for child in children:
                    if child.is_dir(follow_symlinks=False):
                        pending.append(child.path)
                    else:
                        yield child.path
        except (NotADirectoryError, PermissionError, FileNotFoundError):
            pass


def monitor_inotify(roots, ready, events, stop):
    libc = ctypes.CDLL(None, use_errno=True)
    init = getattr(libc, "inotify_init1", None)
    add = getattr(libc, "inotify_add_watch", None)
    if init is None or add is None:
        return 77
    init.argtypes = [ctypes.c_int]
    init.restype = ctypes.c_int
    add.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    add.restype = ctypes.c_int
    fd = init(os.O_NONBLOCK | os.O_CLOEXEC)
    if fd < 0:
        return 77
    mask = 0x00000FCE | 0x02000000
    watched = 0
    try:
        for path in entries(roots):
            encoded = os.fsencode(path)
            if add(fd, encoded, mask) >= 0:
                watched += 1
            elif ctypes.get_errno() not in (errno.ELOOP, errno.ENOENT):
                raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()), path)
        if not watched:
            return 77
        open(ready, "xb").close()
        with open(events, "ab", buffering=0) as output:
            while True:
                readable, _, _ = select.select([fd], [], [], 0.05)
                if readable:
                    while True:
                        try:
                            data = os.read(fd, 65536)
                        except BlockingIOError:
                            break
                        if not data:
                            break
                        offset = 0
                        while offset + 16 <= len(data):
                            wd, event_mask, cookie, length = struct.unpack_from("iIII", data, offset)
                            name = data[offset + 16:offset + 16 + length].rstrip(b"\0")
                            output.write((f"{wd}:{event_mask:x}:{cookie}:".encode() + name + b"\n"))
                            offset += 16 + length
                if os.path.exists(stop):
                    return 0
    finally:
        os.close(fd)


def monitor_kqueue(roots, ready, events, stop):
    if not hasattr(select, "kqueue"):
        return 77
    descriptors = []
    kq = select.kqueue()
    flags = getattr(os, "O_EVTONLY", os.O_RDONLY) | getattr(os, "O_NOFOLLOW", 0)
    notes = (select.KQ_NOTE_DELETE | select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND |
             select.KQ_NOTE_ATTRIB | select.KQ_NOTE_LINK | select.KQ_NOTE_RENAME |
             select.KQ_NOTE_REVOKE)
    try:
        changes = []
        for path in entries(roots):
            try:
                fd = os.open(path, flags)
            except OSError as error:
                if error.errno in (errno.ELOOP, errno.ENOENT, errno.EACCES):
                    continue
                raise
            descriptors.append(fd)
            changes.append(select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                         flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                         fflags=notes))
        if not changes:
            return 77
        kq.control(changes, 0, 0)
        open(ready, "xb").close()
        with open(events, "ab", buffering=0) as output:
            while True:
                for event in kq.control(None, max(1, len(descriptors)), 0.05):
                    output.write(f"{event.ident}:{event.fflags:x}\n".encode())
                if os.path.exists(stop):
                    return 0
    finally:
        kq.close()
        for fd in descriptors:
            os.close(fd)


def snapshot(root):
    records = []
    for path in entries([root]):
        identity = os.lstat(path)
        mode = identity.st_mode
        relative = "." if path == root else path[len(root) + 1:]
        detail = ""
        if stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with open(path, "rb") as source:
                for block in iter(lambda: source.read(131072), b""):
                    digest.update(block)
            kind = "file"
            detail = digest.hexdigest()
        elif stat.S_ISDIR(mode):
            kind = "directory"
        elif stat.S_ISLNK(mode):
            kind = "symlink"
            detail = os.fsencode(os.readlink(path)).hex()
        elif stat.S_ISFIFO(mode):
            kind = "fifo"
        elif stat.S_ISSOCK(mode):
            kind = "socket"
        elif stat.S_ISBLK(mode):
            kind = "block"
            detail = str(identity.st_rdev)
        elif stat.S_ISCHR(mode):
            kind = "character"
            detail = str(identity.st_rdev)
        else:
            kind = "unknown"
        birth_ns = getattr(identity, "st_birthtime_ns", None)
        if birth_ns is None and hasattr(identity, "st_birthtime"):
            birth_ns = round(identity.st_birthtime * 1_000_000_000)
        records.append("|".join((os.fsencode(relative).hex(), kind,
                                 format(stat.S_IMODE(mode), "04o"),
                                 str(identity.st_uid), str(identity.st_gid),
                                 str(identity.st_dev), str(identity.st_ino),
                                 str(identity.st_mtime_ns), str(identity.st_ctime_ns),
                                 "-" if birth_ns is None else str(birth_ns), detail)))
    print("\n".join(sorted(records)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--snapshot")
    parser.add_argument("--ready")
    parser.add_argument("--events")
    parser.add_argument("--stop")
    parser.add_argument("roots", nargs="*")
    args = parser.parse_args()
    if args.snapshot:
        snapshot(args.snapshot)
        return 0
    backend = "kqueue" if hasattr(select, "kqueue") else "inotify" if sys.platform.startswith("linux") else ""
    if args.probe:
        if backend == "kqueue":
            probe = select.kqueue()
            probe.close()
        elif backend == "inotify":
            libc = ctypes.CDLL(None, use_errno=True)
            init = getattr(libc, "inotify_init1", None)
            if init is None:
                return 77
            init.argtypes = [ctypes.c_int]
            init.restype = ctypes.c_int
            descriptor = init(os.O_NONBLOCK | os.O_CLOEXEC)
            if descriptor < 0:
                return 77
            os.close(descriptor)
        else:
            return 77
        print(backend)
        return 0
    if not backend or not args.ready or not args.events or not args.stop or not args.roots:
        return 77
    if backend == "kqueue":
        return monitor_kqueue(args.roots, args.ready, args.events, args.stop)
    return monitor_inotify(args.roots, args.ready, args.events, args.stop)


if __name__ == "__main__":
    sys.exit(main())
