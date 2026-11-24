#!/usr/bin/env python3
"""setup_colour_check.py <setup on a terminal> <setup to a file>: `lares setup`'s colour (the user's ask, 2026-11-23), judged.

  - with the colour codes and the terminal's \\r taken off, the terminal's text is the file's, byte for byte (only colour was added)
  - every command line of a step text (six spaces, then sudo / grep / sed / lares / timeshift / proton-drive / for) is coloured whole
  - a coloured span never starts inside a row's status and label, a heading or a step's title (only commands are coloured)
  - at least one command inside a row's words is coloured (D-Bus activation's `systemctl --user mask`, in the probe's world)
Prints one line naming what is wrong; exits 0 when nothing is."""
import re
import sys

ON, OFF = "\x1b[1;34m", "\x1b[0m"
tty = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
plain = open(sys.argv[2], encoding="utf-8", errors="replace").read()
if re.sub(r"\x1b\[[0-9;]*m", "", tty) != plain:
    sys.exit("the terminal's text, colour taken off, is not the file's")
if ON not in tty:
    sys.exit("nothing is coloured on a terminal")
for line in tty.split("\n"):
    bare = re.sub(r"\x1b\[[0-9;]*m", "", line)
    if re.match(r"^      (sudo |grep |sed |lares |timeshift |proton-drive |for )", bare) and line != "      " + ON + bare[6:] + OFF:
        sys.exit("a step's command line is not coloured whole: " + bare[:100])
    i = line.find(ON)
    if i < 0:
        continue
    if re.match(r"^  \S", bare) and i < 33:
        sys.exit("colour inside a row's status or label: " + bare[:100])
    if re.match(r"^(\S|    \S)", bare):
        sys.exit("a heading or a step's words coloured: " + bare[:100])
if not re.search(re.escape(ON) + r"systemctl --user mask \S+" + re.escape(OFF), tty):
    sys.exit("a command inside a row's words is not coloured (systemctl --user mask)")
