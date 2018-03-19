#!/bin/bash
#
# Wrapper Script for atl-backup script
# VER=0.1                                                 # Version Number

# Directory to save log files into
BACKUPLOGDIR="$HOME/.cache"

# Email Address to send mail to? (user@domain.com)
MAILADDR="logmon@theaveragegeek.com"
ERRMAILADDR="me@theaveragegeek.com"

# Location of backup script
SCRIPTPATH=$HOME/bin/atl-backup.sh
VERBOSITY="" #Run quiet by default. -vv for debug logging

#Script begins

# Good habits
set -o nounset
set -o noglob
set -o pipefail
# Dev habits
#set -o xtrace
#set -o nounset
#set -o noglob
#set -o pipefail


HOST="$(hostname)"                                      # Hostname for LOG information
LOGFILE=$BACKUPLOGDIR/$HOST-atl-backup.log              # Logfile Name


# Create required directories
if [[ ! -e "$BACKUPLOGDIR" ]]; then                # Check Backup Directory exists.
	mkdir -p "$BACKUPLOGDIR"
fi


# Execute backup
: > $LOGFILE
if [[ -z "$VERBOSITY" ]]; then
	$SCRIPTPATH -e -l=$LOGFILE
	CMDSTATUS=$?
else
	$SCRIPTPATH -e $VERBOSITY -l=$LOGFILE
	CMDSTATUS=$?
fi

#Alert primary if script fails, else send log to logging address

if [[ $CMDSTATUS -ne 0 ]]; then
	mutt $ERRMAILADDR -s "ERROR - Atlassian Application Backup for $HOST - $(date +%Y%m%d)" -a $LOGFILE
	STATUS=1
elif [[ $CMDSTATUS -eq 0 ]]; then
	mutt $MAILADDR -s "Atlassian Application Backup for $HOST - $(date +%Y%m%d)" -a $LOGFILE
	STATUS=0
fi

# Clean up Logfile
eval rm -f "$LOGFILE"

exit $STATUS
