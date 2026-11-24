#!/usr/bin/env python3
"""Print one line per change of a sysfs attribute that raises POLLPRI.

    sysfs_pollpri.py /sys/class/leds/asus::kbd_backlight/brightness_hw_changed

The kernel tells userspace that firmware changed an LED (the Fn key) by
sysfs_notify() on `brightness_hw_changed`; inotify never sees it, only
poll(POLLPRI) does. Each wake-up prints the attribute's new content (one
integer) and flushes, so a reader on a pipe gets it at once.

stdlib only. Exits 0 when its stdout closes (the reader is gone).

The first poll() of a freshly opened sysfs attribute returns at once with the
state that was already there, so the attribute is read to the end first and
that initial event is swallowed: nothing is printed until something changes.

TWO THINGS THE KERNEL DOES THAT A READER MUST SURVIVE (without them the shell has no
helper running at all and the keyboard-brightness OSD sometimes does not show):

  * `brightness_hw_changed` answers read() with ENODATA ("No data available")
    until the firmware has changed the LED once since boot. Reading it to arm the
    poll must not take that OSError for a crash: a helper that exited at every start
    before the first Fn press leaves a shell started after boot with no helper, and
    the Fn key that would make the attribute readable cannot be heard. An
    ENODATA read is "nothing has changed yet": the poll is armed all the same
    (the kernel counts the read) and the first real change prints.
  * Any other failure of the attribute (the device unregistered and came back, EIO,
    ENODEV, a path that is not there YET at login) is not a traceback and an exit
    that nothing notices. The attribute is reopened with a growing pause (0.5 s up
    to 10 s) for as long as the reader is there; a change that happened while it was
    gone is not printed (a value nobody can vouch for), the next one is.
"""
import errno
import os
import select
import sys
import time

RETRY_FIRST = 0.5
RETRY_MAX = 10.0


def read_value(fd):
    """The attribute's content, or None when the kernel has nothing to say yet (ENODATA)."""
    os.lseek(fd, 0, os.SEEK_SET)
    try:
        return os.read(fd, 64).decode("ascii", "replace").strip()
    except OSError as e:
        if e.errno == errno.ENODATA:
            return None
        raise


class Watcher:
    """One attribute, watched. A test replaces this module's os, select, time and sys."""

    def __init__(self, path, out=None, err=None):
        self.path = path
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.warned = False

    def _warn(self, why):
        if not self.warned:
            self.warned = True
            self.err.write("sysfs_pollpri: %s: %s; trying again\n" % (self.path, why))
            self.err.flush()

    def _close(self, fd):
        if fd is None:
            return
        try:
            os.close(fd)
        except OSError:
            pass

    def _open(self):
        """The armed poller and its fd, waiting for the attribute as long as it takes."""
        pause = RETRY_FIRST
        while True:
            fd = None
            try:
                fd = os.open(self.path, os.O_RDONLY)
                poller = select.poll()
                poller.register(fd, select.POLLPRI | select.POLLERR)
                read_value(fd)
                poller.poll(0)          # the initial event
                return fd, poller
            except OSError as e:
                self._close(fd)
                self._warn(e.strerror or str(e))
                time.sleep(pause)
                pause = min(RETRY_MAX, pause * 2)

    def run(self):
        fd, poller = self._open()
        while True:
            try:
                events = poller.poll()
                if not events:
                    continue
                value = read_value(fd)
            except InterruptedError:
                continue
            except OSError as e:
                # the attribute went (the device was unregistered): reopen it
                self._close(fd)
                self._warn(e.strerror or str(e))
                time.sleep(RETRY_FIRST)
                fd, poller = self._open()
                continue
            if value is None:
                continue
            try:
                self.out.write(value + "\n")
                self.out.flush()
            except (BrokenPipeError, ValueError):
                return 0


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: sysfs_pollpri.py <sysfs attribute>\n")
        return 2
    return Watcher(argv[1]).run()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(0)
