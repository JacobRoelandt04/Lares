#!/usr/bin/env python3
"""write_file: write stdin to ONE path, atomically, and say what was written.

    python3 -I write.py --preflight -- <path>     (before the confirmation)
    python3 -I write.py -- <path>                 (content on stdin)

--preflight resolves the path the way the write will see it -- `~` expanded,
made absolute, every symlink in the parent FOLLOWED (os.path.realpath) --
and prints two lines:
    <resolved absolute path>
    size <N>        or        new
The registry runs it BEFORE the permission decision (round 15 repair), so
the directory the grant is keyed on, the path the confirmation shows and the
path the write goes to are the same real directory: a parent that is a link
into ~/.ssh is shown as ~/.ssh, never followed after the click.

The write is handed that resolved path. The parent is created (mkdir -p), the
bytes go to a temp file in it and are renamed over the target, and the reply
is one line:
    wrote N bytes to <path> sha256 <hex>
If the parent is no longer the real directory at write time (a link swapped
in between the confirmation and the click) nothing is written: exit 3 with
the reason. Nothing else is written anywhere. The path is the frozen argv
element; the content is the frozen stdin -- this script decides nothing.
"""
import hashlib
import os
import sys
import tempfile


def resolve(raw):
    home = os.environ.get("HOME", "")
    if raw == "~":
        raw = home
    elif raw.startswith("~/"):
        raw = home + raw[1:]
    if not raw.startswith("/"):
        raw = os.path.join(os.getcwd(), raw)
    parent, name = os.path.split(raw)
    if name in ("", ".", ".."):
        return None, None
    return os.path.realpath(parent), name


def preflight(raw):
    real_parent, name = resolve(raw)
    if real_parent is None:
        print("not a file path: %s" % raw, file=sys.stderr)
        return 2
    target = os.path.join(real_parent, name)
    # The target itself may be a link to a file elsewhere: the write replaces
    # the link's TARGET (rename over the link would drop the link), so that
    # is the path shown.
    if os.path.islink(target):
        target = os.path.realpath(target)
    print(target)
    try:
        st = os.stat(target)
        print("size %d" % st.st_size)
    except OSError:
        print("new")
    return 0


def write(raw):
    parent, name = os.path.split(raw)
    if not raw.startswith("/") or name in ("", ".", ".."):
        print("not an absolute file path: %s" % raw, file=sys.stderr)
        return 2
    try:
        os.makedirs(parent, exist_ok=True)
        real_parent = os.path.realpath(parent)
        if real_parent != parent:
            print("refused: %s is now a link to %s; the path confirmed is not the path it would write to" % (parent, real_parent), file=sys.stderr)
            return 3
        target = os.path.join(parent, name)
        if os.path.islink(target):
            print("refused: %s is now a link to %s; the path confirmed is not the path it would write to" % (target, os.path.realpath(target)), file=sys.stderr)
            return 3
        data = sys.stdin.buffer.read()
        fd, tmp = tempfile.mkstemp(prefix="." + name + ".", dir=parent)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            # mkstemp makes the file 0600; a written file is an ordinary file,
            # so it takes the mode a shell's `>` would have given it.
            um = os.umask(0)
            os.umask(um)
            os.chmod(tmp, 0o666 & ~um)
            os.replace(tmp, target)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as e:
        print("write failed: %s" % e, file=sys.stderr)
        return 1
    print("wrote %d bytes to %s sha256 %s" % (len(data), target, hashlib.sha256(data).hexdigest()))
    return 0


def main():
    args = sys.argv[1:]
    pre = False
    if args and args[0] == "--preflight":
        pre = True
        args = args[1:]
    if args and args[0] == "--":
        args = args[1:]
    if len(args) != 1:
        print("usage: write.py [--preflight] -- <path>", file=sys.stderr)
        return 2
    return preflight(args[0]) if pre else write(args[0])


if __name__ == "__main__":
    sys.exit(main())
