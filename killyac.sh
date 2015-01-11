#!/bin/bash
#Script to kill YACReader Library running in a "headless" VNC session

# User/Home for script. While this might seem like it allows for the script to run by another user,
# it actually won't work as the script does not use su/sudo. This is mostly to overcome the script being
# added to cron.d where it would run under root.
USER="yac"

# TODO: Have logging / debug version of commands that are controlled through a --debug switch passed on
# the command line.
# Display Number
DISPID="5"

# Script starts here. Unless you are comfortable with what the script is doing
# No further changes required!
#set -x #Uncomment to turn debugging on

# Kill running YACReader Library sessions
echo "Killing any running sessions of YACReader Library"
# This will kill all Xvfb sessions for the defined user, so if you have other Xvfb sessions you need active
# Consider running YACReader Library under a different user that will not clash
pgrep -u "$USER" Xvfb | xargs kill -- #This one-liner has the added benefit of terminating VNC, the WM & YACReader as well. Nice!

#set +x #Turn debugging off