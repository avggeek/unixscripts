#!/bin/bash
#Script to kill Calibre Library running in a "headless" VNC session

# User/Home for script. While this might seem like it allows for the script to run by another user,
# it actually won't work as the script does not use su/sudo. This is mostly to overcome the script being
# added to cron.d where it would run under root.
USER="nas"

# TODO: Have logging / debug version of commands that are controlled through a --debug switch passed on
# the command line.
# Display Number
DISPID="6"

# Script starts here. Unless you are comfortable with what the script is doing
# No further changes required!
#set -x #Uncomment to turn debugging on

# Kill running Calibre Library sessions
echo "Killing any running sessions of Calibre Library"
#This one-liner will terminate the entire process tree for a running instance of the Calibre Library. Nice!
ps -o pgid,cmd -U "$USER" | awk -v disp="[X]vfb :$DISPID" '$0 ~ disp { print $1 }' | xargs pkill -TERM -g

#set +x #Turn debugging off