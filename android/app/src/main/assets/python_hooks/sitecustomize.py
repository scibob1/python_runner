"""Python Runner Debian guest startup hook.

Workaround for an intermittent ``OSError: [Errno 38] Function not implemented`` that
getcwd() hits under proot on the HarmonyOS test device. CPython's import machinery calls
``posix.getcwd()`` as soon as ``''`` is on ``sys.path`` (``python -c`` / ``-m``), so one
failed call aborts the whole interpreter at its first non-builtin import.

This file runs from ``site`` before ``''`` is added to ``sys.path``. It wraps getcwd so that
ENOSYS is retried, then falls back to ``/proc/self/cwd``. Only builtin modules are
imported here (no path lookup, hence no getcwd).

TEMP-DIAG: ``_note`` prints a line to stderr when a retry/fallback happened. Remove it
(and this notice) once the investigation is over.
"""
import errno
import posix
import sys
import time

_RETRIES = 30


def _note(message):
    try:
        sys.stderr.write("[TEMP-DIAG] sitecustomize: %s\n" % message)
    except Exception:
        pass


def _make(orig, as_bytes):
    def getcwd_retry():
        last = None
        for attempt in range(_RETRIES):
            try:
                value = orig()
            except OSError as exc:
                if exc.errno != errno.ENOSYS:
                    raise
                last = exc
                time.sleep(0.005 * (attempt + 1))
                continue
            if attempt:
                _note("getcwd recovered after %d retries" % attempt)
            return value
        try:
            value = posix.readlink(b"/proc/self/cwd" if as_bytes else "/proc/self/cwd")
            _note("getcwd used /proc/self/cwd fallback")
            return value
        except OSError:
            _note("getcwd gave up after %d retries" % _RETRIES)
            raise last

    return getcwd_retry


try:
    _orig_getcwd = posix.getcwd
    _orig_getcwdb = posix.getcwdb
    posix.getcwd = _make(_orig_getcwd, False)
    posix.getcwdb = _make(_orig_getcwdb, True)
    _os = sys.modules.get("os")
    if _os is not None:
        _os.getcwd = posix.getcwd
        _os.getcwdb = posix.getcwdb
except Exception as _exc:  # never break interpreter start-up
    _note("install failed: %r" % (_exc,))
