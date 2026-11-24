#!/bin/sh
# Mirror the notes to the external drive.
set -eu
rsync -a --delete "$HOME/Documents/Notes/" "/run/media/$USER/backup/Notes/"
echo "notes backed up"
