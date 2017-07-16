#!/bin/bash
#Script to launch YACReader Library into a "headless" VNC session
#Heavily inspired by http://askubuntu.com/a/196353

# User/Home for script. While this might seem like it allows for the script to run by another user,
# it actually won't work as the script does not use su/sudo. This is mostly to overcome the script being
# added to cron.d where it would run under root.
USER="yac"
USER_HOME=$(getent passwd $USER | cut -d: -f6)
# Directory to save log files into
LOGDIR="$USER_HOME/.vnc/log"
# Log files
# TODO: Have logging / debug version of commands that are controlled through a --debug switch passed on
# the command line.
LOGIFLE="$LOGDIR/yacvnc.log"
# Display Number
DISPID="5"
# Resolution,Depth etc.
DISPRES="1200x800x24+32"
# IP Range allowed. Default allows the 192.168.0.0/16 block
IPRANGE="192.168."
# VNC Port
VNCPORT="5900"
DISPPORT=$((VNCPORT + DISPID))
# Window Manager to actually draw the frame for YACReader Library.
# Use metacity, compiz, fluxbox etc. if you prefer. Script defaults to XFWM 4 (XFCE 4)
WMGR="xfwm4"

# Script starts here. Unless you are comfortable with what the script is doing
# No further changes required!
#set -x #Uncomment to turn debugging on
# Create required directories
	if [ ! -e "$LOGDIR" ]                # Check Backup Directory exists.
	then
	mkdir -p "$LOGDIR"
	fi

# Refresh log files
: > "$LOGIFLE"

# Find Executables. This should ideally not be required because the PATH set for cron
# in /etc/environment should include these executables. But this also acts as a dependency check.
# Fails https://github.com/koalaman/shellcheck/wiki/SC2015 though.
YACWINNAME="YACReader Library"
WMCTRLEXEC="$(command -v wmctrl)" && command -v wmctrl >/dev/null 2>&1 || { echo >&2 "The script requires wmctrl but it's not installed. Aborting." | tee -a "$LOGIFLE"; unset WMCTRLEXEC; exit 1; }
XVFBEXEC="$(command -v Xvfb)" && command -v Xvfb >/dev/null 2>&1 || { echo >&2 "The script requires Xvfb but it's not installed. Aborting." | tee -a "$LOGIFLE"; unset XVFBEXEC; exit 1; }
VNCEXEC="$(command -v x11vnc)" && command -v x11vnc >/dev/null 2>&1 || { echo >&2 "The script requires x11vnc but it's not installed. Aborting." | tee -a "$LOGIFLE"; unset VNCEXEC; exit 1; }
WMEXEC="$(command -v "$WMGR")" && command -v "$WMGR" >/dev/null 2>&1 || { echo >&2 "The Window Manager specified does not appear to be a valid choice. Aborting." | tee -a "$LOGIFLE"; unset WMEXEC; unset WMGR; exit 1; }
YACEXEC="$(command -v YACReaderLibrary)" && command -v YACReaderLibrary >/dev/null 2>&1 || { echo >&2 "The script requires YACReader Library but it's not installed. Aborting." | tee -a "$LOGIFLE"; unset YACEXEC; exit 1; }

#Setup the Framebuffer display and Window Manager
echo "Starting the display" | tee -a "$LOGIFLE"
#The RANDR extension was added so that VNC stops complaining.
"$XVFBEXEC" :"$DISPID" -screen 0 "$DISPRES" -ac +extension RANDR &>/dev/null & #We are specifying Bash for the interpreter, so no POSIX Compliance here!
	echo "Waiting for 10 seconds to allow Xvfb to initalize" | tee -a "$LOGIFLE"
	sleep 2
	/bin/echo -ne '####                    (20%)\r'
	sleep 2
	/bin/echo -ne '########                (40%)\r'
	sleep 2
	/bin/echo -ne '############            (60%)\r'
	sleep 2
	/bin/echo -ne '################        (80%)\r'
	sleep 2
	/bin/echo -ne '####################    (100%)\r'
	/bin/echo -ne '\n'
DISPLAY=:"$DISPID" "$WMEXEC" &>/dev/null &

#Start VNC into the Xvfb display
echo "Starting VNC" | tee -a "$LOGIFLE"
# Few options to explain:
# Since the default command restricts access by IP Range inside a typical Home LAN, no password is set
# If you do want to set a password, first run x11vnc -storepasswd which will create ~/.vnc/passwd
# Then change -nopw to -usepw
# If you need additional logging, you can replace -quiet with -logfile /path/to/vncerr.log
"$VNCEXEC" -display :"$DISPID" -rfbport "$DISPPORT" -noipv6 -noxdamage -ncache_cr -nolookup --nopw --allow "$IPRANGE" -quiet -noclipboard -bg --forever >/dev/null 2>&1

#Launch YACReader Library and maximize it
echo "Starting YACReader Library" | tee -a "$LOGIFLE"
DISPLAY=:"$DISPID" "$YACEXEC" &>/dev/null &
	echo "Waiting for 2 seconds to allow YAC Reader Library to load" | tee -a "$LOGIFLE"
	sleep 2
DISPLAY=:"$DISPID" "$WMCTRLEXEC" -r "$YACWINNAME" -b add,fullscreen

#set +x #Turn debugging off