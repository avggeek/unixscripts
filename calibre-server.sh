#!/bin/bash
#Script to run Calibre content server

#Variables
BOOKLIBRARY="/media/ebooks/Calibre Library/"
CALIBREPATH="/usr/bin/calibre-server"
#Script
until `nice -n5 $CALIBREPATH --auto-reload --with-library "$BOOKLIBRARY"`; do
	echo "calibre-server crashed with exit code $?. Respawning.." >&2
	sleep 5
done
