"""Staged pip installs with rollback (pure standard library, no Chaquopy imports).

pip is pointed at a fresh staging directory; only after it exits successfully are the
results merged into the real site directory. Any failure -- pip's own, or while merging --
leaves the site directory exactly as it was, so a failed or interrupted install can no
longer leave half-installed packages behind that block the next attempt.

Merge rules (mirroring ``pip --target`` where it makes sense):
  * top-level entry missing in the site dir            -> moved in
  * entry exists, ``upgrade`` requested                -> old one backed up, new one moved in
  * entry exists but no installed distribution owns it -> leftover of an earlier failed
                                                          install: replaced
  * dist-info / egg-info that already exists           -> skipped (same distribution)
  * other existing directories (namespace packages,
    ``chaquopy/``, ``bin/``)                            -> files merged, never overwritten
"""
import contextlib
import csv
import os
import shutil
import tempfile
import time

STAGING_PREFIX = "pip_staging_"
BACKUP_PREFIX = ".pip_backup_"
# Shared directories that are always merged file by file, never replaced as a whole.
_SHARED_DIRS = {"bin", "chaquopy", "__pycache__"}


def _is_meta_dir(name):
    return name.endswith((".dist-info", ".egg-info"))


def _project_of(meta_name):
    base = meta_name.rsplit(".", 1)[0]
    return base.split("-", 1)[0].replace("-", "_").replace(".", "_").lower()


def sweep_stale_staging(parent, max_age_seconds=600):
    """Remove staging directories left behind by a crashed install."""
    try:
        entries = os.listdir(parent)
    except OSError:
        return
    now = time.time()
    for entry in entries:
        if not entry.startswith(STAGING_PREFIX):
            continue
        path = os.path.join(parent, entry)
        try:
            if now - os.path.getmtime(path) > max_age_seconds:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


@contextlib.contextmanager
def staging_dir(site_dir):
    """A fresh empty directory next to ``site_dir`` (same filesystem), always removed."""
    parent = os.path.dirname(os.path.abspath(site_dir))
    sweep_stale_staging(parent)
    path = tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=parent)
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def owned_top_levels(site_dir):
    """(names, complete): top-level names owned by installed distributions.

    ``complete`` is False when some distribution has neither RECORD nor top_level.txt, in
    which case ownership cannot be judged and nothing is treated as a leftover.
    """
    owned, complete = set(), True
    try:
        entries = os.listdir(site_dir)
    except OSError:
        return owned, False
    for entry in entries:
        if not _is_meta_dir(entry):
            continue
        meta = os.path.join(site_dir, entry)
        found = False
        record = os.path.join(meta, "RECORD")
        if os.path.isfile(record):
            found = True
            try:
                with open(record, newline="", encoding="utf-8") as handle:
                    for row in csv.reader(handle):
                        if row and row[0] and not row[0].startswith(("..", "/")):
                            owned.add(row[0].split("/", 1)[0])
            except (OSError, UnicodeDecodeError):
                complete = False
        top_level = os.path.join(meta, "top_level.txt")
        if os.path.isfile(top_level):
            found = True
            try:
                with open(top_level, encoding="utf-8") as handle:
                    owned.update(line.strip() for line in handle if line.strip())
            except (OSError, UnicodeDecodeError):
                complete = False
        if not found:
            complete = False
    return owned, complete


class _Transaction:
    """Undo journal for the merge."""

    def __init__(self, parent):
        self.backup_root = tempfile.mkdtemp(prefix=BACKUP_PREFIX, dir=parent)
        self._undo = []
        self._backup_count = 0

    def created(self, path):
        self._undo.append(("remove", path, None))

    def move_aside(self, path):
        self._backup_count += 1
        backup = os.path.join(self.backup_root, "%d_%s" % (self._backup_count, os.path.basename(path)))
        os.replace(path, backup)
        self._undo.append(("restore", path, backup))

    def rollback(self):
        for kind, path, backup in reversed(self._undo):
            try:
                if kind == "remove":
                    if os.path.isdir(path) and not os.path.islink(path):
                        shutil.rmtree(path, ignore_errors=True)
                    elif os.path.lexists(path):
                        os.remove(path)
                else:
                    if os.path.isdir(path) and not os.path.islink(path):
                        shutil.rmtree(path, ignore_errors=True)
                    elif os.path.lexists(path):
                        os.remove(path)
                    os.replace(backup, path)
            except OSError:
                pass
        self.finish()

    def finish(self):
        shutil.rmtree(self.backup_root, ignore_errors=True)


def _move(src, dst):
    try:
        os.replace(src, dst)
    except OSError:
        shutil.move(src, dst)


def _merge_dirs(src, dst, tx):
    """Copy files of ``src`` into existing ``dst``; never overwrite an existing file."""
    for name in sorted(os.listdir(src)):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isdir(s) and not os.path.islink(s):
            if os.path.isdir(d) and not os.path.islink(d):
                _merge_dirs(s, d, tx)
            elif not os.path.lexists(d):
                _move(s, d)
                tx.created(d)
        elif not os.path.lexists(d):
            _move(s, d)
            tx.created(d)


def merge_staging(staging, site_dir, upgrade=False):
    """Merge ``staging`` into ``site_dir`` atomically (all or nothing).

    Returns {"installed": [...], "replaced": [...], "skipped": [...]} (top-level names).
    On any error everything done so far is undone and the exception is re-raised.
    """
    os.makedirs(site_dir, exist_ok=True)
    owned, complete = owned_top_levels(site_dir)
    existing_meta = [e for e in os.listdir(site_dir) if _is_meta_dir(e)]
    tx = _Transaction(os.path.dirname(os.path.abspath(site_dir)))
    result = {"installed": [], "replaced": [], "skipped": []}
    try:
        for name in sorted(os.listdir(staging)):
            src, dst = os.path.join(staging, name), os.path.join(site_dir, name)
            meta = _is_meta_dir(name)
            if not os.path.lexists(dst):
                if meta and not upgrade and any(
                        _project_of(e) == _project_of(name) for e in existing_meta):
                    # Files of this project are kept (no upgrade), so keep its metadata too.
                    result["skipped"].append(name)
                    continue
                _move(src, dst)
                tx.created(dst)
                result["installed"].append(name)
                continue
            shared = name in _SHARED_DIRS
            leftover = complete and not meta and not shared and name not in owned
            if (upgrade and not shared) or leftover:
                tx.move_aside(dst)
                _move(src, dst)
                tx.created(dst)
                result["replaced"].append(name)
            elif meta:
                result["skipped"].append(name)
            elif os.path.isdir(src) and os.path.isdir(dst) and not os.path.islink(dst):
                _merge_dirs(src, dst, tx)
                result["installed"].append(name)
            else:
                result["skipped"].append(name)
        if upgrade:
            # Drop older dist-info of the same project so versions don't pile up.
            fresh = {_project_of(n): n for n in result["installed"] + result["replaced"] if _is_meta_dir(n)}
            for old in existing_meta:
                project = _project_of(old)
                if project in fresh and old != fresh[project] and os.path.lexists(os.path.join(site_dir, old)):
                    tx.move_aside(os.path.join(site_dir, old))
    except BaseException:
        tx.rollback()
        raise
    tx.finish()
    return result
