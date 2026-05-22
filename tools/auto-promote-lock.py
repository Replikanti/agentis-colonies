#!/usr/bin/env python3
"""auto-promote-lock.py - Acquire an exclusive advisory lock on an inherited FD.

Extracted from tools/auto-promote.sh in #245 to replace the `flock -n` binary
call (from util-linux, not present on stock macOS).

The parent shell opens the lock file with `exec 200>"$LOCK_FILE"` and invokes
this helper with the FD number plus the lock-file path. We call
fcntl.flock(LOCK_EX | LOCK_NB) on that FD. POSIX flock locks are associated
with the open file description, so the lock persists as long as any FD
pointing to that OFD stays open. This helper exits after acquiring the lock;
the parent shell keeps its FD open until the auto-promote run completes,
which keeps the lock held without a supervisor process.

Works on Linux (OFD-based flock) and macOS (BSD flock - same OFD semantics per
flock(2): "This lock is removed on close(2) of the last file descriptor that
references the open file").

On acquire, the helper writes its PID into the lock file. On contention, it
reads the prior holder's PID and checks whether the process is alive
(`os.kill(pid, 0)`) and -- on Linux -- whether `/proc/<pid>/cmdline` still
references an auto-promote.sh or agentis process. If the holder is dead or
its PID has been recycled into an unrelated process, the helper steals the
lock instead of returning contention. This recovers the "lock orphaned by a
spawned daemon FD that survived the parent shell" failure mode from #728.

Exit 0 on successful acquire (including steal), 1 on real contention, 2 on
bad usage.

Args (positional):
    1: fd        - integer FD number inherited from the parent shell
    2: lock_path - filesystem path to the lock file (same path the parent
                   shell opened with `exec 200>"$LOCK_FILE"`)
"""
import errno
import fcntl
import os
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write('Usage: %s <fd> <lock_file_path>\n' % sys.argv[0])
        return 2
    try:
        fd = int(sys.argv[1])
    except ValueError:
        sys.stderr.write('Not an integer FD: %s\n' % sys.argv[1])
        return 2
    lock_path = sys.argv[2]
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
            raise
        # Real contention from the kernel's point of view. Probe whether the
        # PID recorded in the lock file still belongs to a live auto-promote
        # process; if not, steal.
        if not try_steal_stale(fd, lock_path):
            return 1
    # Acquired (either cleanly or after a steal). Write our PID for future
    # staleness checks.
    write_pid_into_lock(fd)
    return 0


def try_steal_stale(fd, lock_path):
    """Read the lock-file PID; if the holder is dead or recycled, steal."""
    try:
        with open(lock_path, 'r') as f:
            content = f.read().strip()
        pid = int(content)
    except (OSError, ValueError):
        # No PID written or unparseable -- treat as stale and try to steal.
        # This also covers the legacy case where a pre-#728 holder never wrote
        # its PID into the file.
        return retry_after_truncate(fd, lock_path)
    if is_holder_dead(pid):
        sys.stderr.write(
            '[lock] stale lock detected (PID %d dead/recycled); stealing\n'
            % pid
        )
        return retry_after_truncate(fd, lock_path)
    return False


def is_holder_dead(pid):
    """Return True if the PID is dead or has been recycled into something
    unrelated to auto-promote.sh / agentis.
    """
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        # PID exists but owned by another user. In our deployment the lock
        # file is per-user, so this implies a recycled PID owned by some
        # system process -- treat as recycled (steal-safe).
        return True
    # PID is alive. On Linux, check /proc/<pid>/cmdline to confirm it's
    # actually an auto-promote.sh or agentis process. If the PID has been
    # recycled into e.g. gnome-shell, treat as dead.
    try:
        with open('/proc/%d/cmdline' % pid, 'rb') as f:
            cmdline = f.read().replace(b'\x00', b' ').decode('utf-8', 'replace')
    except OSError:
        # /proc not available (non-Linux) or race with process exit. We
        # can't disprove liveness so we conservatively treat as alive --
        # except for the os.kill side which already passed, so on macOS
        # we just assume the PID is genuinely the holder.
        return False
    if 'auto-promote.sh' not in cmdline and 'agentis' not in cmdline:
        return True
    return False


def retry_after_truncate(fd, lock_path):
    """Truncate the lock file (clearing the stale PID) and retry the flock.

    We do NOT unlink the lock file -- other processes might be racing to
    open() it and unlinking would create a new inode that doesn't share
    our flock state.
    """
    try:
        os.ftruncate(fd, 0)
    except OSError:
        pass
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def write_pid_into_lock(fd):
    """Write our PID + newline into the lock file via the inherited FD."""
    try:
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, (str(os.getpid()) + '\n').encode('utf-8'))
        try:
            os.fsync(fd)
        except OSError:
            # fsync on a non-regular file (e.g. testing against /dev/null)
            # is non-fatal -- the truncate + write already persisted what
            # we need.
            pass
    except OSError as e:
        # Write failure is non-fatal: the lock is held; staleness detection
        # in future invocations will just fall through to the truncate path.
        sys.stderr.write('[lock] warning: could not write PID: %s\n' % e)


if __name__ == '__main__':
    sys.exit(main())
