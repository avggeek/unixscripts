#!/bin/bash

# Script to backup PostgreSQL databases as well as Atlassian application data folders to Amazon S3.
# Mostly taken from /usr/share/doc/s3ql/examples/s3ql_backup.sh, https://wiki.postgresql.org/wiki/Automated_Backup_on_Linux
# and https://gist.github.com/cm6051/a7a67c30b2ef3f52f8c5. Shout-out to the many SO commenters who provided working
# Bash examples for me to learn from.

# Dependencies:  S3QL, Borgbackup, rysnc, presence of ~/.s3ql/authinfo2 and ~/.pgpass files under user running the job.
#                Password files should be set have file permissions set to 0400 for safety

#Good habits
#set -o errexit
#set -o nounset
#set -o noglob
#set -o pipefail
#Dev habits
set -o xtrace
set -o nounset
set -o noglob
set -o pipefail


#User-defined Script Variables
PGPASSFILE="" #will default to ~/.pgpass if empty
S3QLAUTHFILE="" #will default to ~/.s3ql/authinfo2 if empty
PGBACKUP_DIR=/var/backups/postgresql
PGBACKUPS_TO_KEEP=30
BORGBACKUP_DIR=/var/backups/borg
BORGTIP=atlbackup.borg
BORGBACKUP_SRC="/var/atlassian/application-data"
BORGEXCLUDE_DIR="/var/atlassian/application-data/jira/log /var/atlassian/application-data/stash/log"
# Keep 30 end of day, 4 additional end of week archives, and an end of month archive for every month:
BORGBACKUPS_TO_KEEP="--keep-daily=30 --keep-weekly=4 --keep-monthly=-1"


# Script flow
# main {
# check_dependencies
# check_dirs
# dump_database (Verbose & non-verbose mode)
# mount_s3 (incl. fsck, verbose & non-verbose)
# borg_backup (incl. create archive, verbose & non-verbose)
# borg_prune
# unmount_s3
# ALLBACKUP_END
# exit_status
#}
#main() {
#    foo
#    bar
#    baz
#}
#
#foo() {
#}

main () {
      check_dependencies
      check_dirs
      ALLBACKUP_START="$(date +%s)"
      dump_database
      ALLBACKUP_END="$(date +%s)"
}

##
## Simple logging mechanism for Bash
##
## Author: Michael Wayne Goodman <goodman.m.w@gmail.com>
## Thanks: Jul for the idea to add a datestring. See:
## http://www.goodmami.org/2011/07/simple-logging-in-bash-scripts/#comment-5854
##
## License: Public domain; do as you wish
##

exec 3>&2 # logging stream (file descriptor 3) defaults to STDERR
verbosity=3 # default to show warnings
silent_lvl=0
crt_lvl=1
err_lvl=2
wrn_lvl=3
dbg_lvl=4
inf_lvl=5

notify() { log $silent_lvl "NOTE: $1"; } # Always prints
critical() { log $crt_lvl "CRITICAL: $2"; }
error() { log $err_lvl "ERROR: $1"; }
warn() { log $wrn_lvl "WARNING: $1"; }
debug() { log $dbg_lvl "DEBUG: $1"; }
inf() { log $inf_lvl "INFO: $1"; } # "info" is already a command
log() {
    if [[ $verbosity -ge "$1" ]]; then
        datestring=$(date +'%Y-%m-%d %H:%M:%S')
        # Expand escaped characters, wrap at 70 chars, indent wrapped lines
        echo -e "$datestring $2" | fold -w70 -s | sed '2~1s/^/  /' >&3
    fi
}

usage() {
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo "Options:"
    echo "  -h      : display this help message"
    echo "  -q      : decrease verbosity level (can be repeated: -qq, -qqq)"
    echo "  -v      : increase verbosity level (can be repeated: -vv, -vvv)"
    echo "  -l FILE : redirect logging to FILE instead of STDERR"
}

while getopts "hqvl:" opt; do
    case "$opt" in
       h) usage; exit 0 ;;
       q) (( verbosity = verbosity - 1 )) ;;
       v) (( verbosity = verbosity + 1 )) ;;
       l) exec 3>>$OPTARG ;;
       *) error "Invalid options: $1"; usage; exit 1 ;;
    esac
done
shift $((OPTIND-1))
args="$@"

# EXAMPLE: notify "This logging system uses the standard verbosity level mechanism to choose which messages to print. Command line arguments customize this value, as well as where logging messages should be directed (from the default of STDERR). Long messages will be split at spaces to wrap at a character limit, and wrapped lines are indented. Wrapping and indenting can be modified in the code."
# CRITICAL ERROR example: critical "" "Abort"

# Calculate elapsed time
elapsedtime=-1
calc_elapsed_time () {

  local  __inputvar=$1
  ((h=__inputvar/3600))
  ((m=(__inputvar%3600)/60))
  ((s=__inputvar%60))
  elapsedtime=$(printf "%02d:%02d:%02d" $h $m $s)
}

check_dependencies () {
  # Find Home Directory. All required auth files are relative to this directory.
  USER_HOME="$(getent passwd "$USER" | cut -d: -f6)"
  # Check if required files exist
  if [[ ! -f "${PGPASSFILE:-$USER_HOME/.pgpass}" ]]; then { critical "" "PostgreSQL configuration file is not available. Aborting."; exit 1; } else :; fi
  if [[ ! -f "${S3QLAUTHFILE:-$USER_HOME/.s3ql/authinfo2}" ]]; then { critical "" "S3QL Authorization file is not available. Aborting."; exit 1; } else :; fi
  # TODO: Add check for S3QL/authinfo2

  # Check if required executables exist in user's $PATH
  hash pg_dumpall 2>/dev/null || { critical "" "Script requires pg_dumpall but it is not available in $USER's PATH. Aborting."; exit 1; }
  hash borg 2>/dev/null || { critical "" "Script requires borg but it is not available in $USER's PATH. Aborting."; exit 1; }
  #hash mount.s3ql 2>/dev/null || { critical "" "Script requires S3QL tools but they are not available in $USER's PATH. Aborting."; exit 1; }

}

check_dirs () {
  # Check if target directories for Borg backup exist
  for dir in $BORGBACKUP_SRC; do if [[ ! -d "$dir" ]]; then { critical "" "Target directory(ies) for Borg backup $dir is(are) missing" ; exit 1; } fi; done
  # Before attempting to create Backup directories, check if parent directories are writeable
  PGBACKUP_PARENT=$(dirname "${PGBACKUP_DIR}")
  if [[ ! -w "$PGBACKUP_PARENT" ]]; then warning "Directory where PostgreSQL backups are to be stored are not writeable by $USER. Unless $PGBACKUP_DIR already exists and is writeable, the script will fail trying to create the directory/backup files"; else :; fi
  BORGBACKUP_PARENT=$(dirname "${BORGBACKUP_DIR}")
  if [[ ! -w "$BORGBACKUP_PARENT" ]]; then warning "Directory where Borg backup files are to be stored are not writeable by $USER. Unless $BORGBACKUP_DIR already exists and is writeable, the script will fail trying to create the directory/backup files"; else :; fi

  # Create backup directories
  if [[ ! -d "$PGBACKUP_DIR" ]]; then { notify "Creating PostgreSQL Backup directory as it does not exist" ; mkdir -p "$PGBACKUP_DIR"; }; fi;
  if [[ ! -d "$BORGBACKUP_DIR" ]]; then { notify "Creating Borg backup directory as it does not exist" ; mkdir -p "$BORGBACKUP_DIR"; }; fi;
}

dump_database () {
  # Start by backing up PostgreSQL databases
  # Check for variables else set them
  if [[ -z ${PGHOST:-} ]]; then PGHOSTNAME="localhost"; else PGHOSTNAME="$PGHOST":; fi;
  if [[ -z ${PGPORT:-} ]]; then PGHOSTPORT="5432"; else PGHOSTPORT="$PGPORT":; fi;
  debug "About to connect to PostgreSQL instance running at $PGHOSTNAME:$PGHOSTPORT"

  # If verbosity is set to debug or higher then all programs called by the backup script will run in verbose mode.
  if [[ $verbosity -gt "$wrn_lvl" ]]; then #i.e. -vv
    #Dump all PostgreSQL databases
    PGBACKUP_START="$(date +%s)"
    PGBACKUP_LOG="$( { pg_dumpall --host="$PGHOSTNAME" --port="$PGHOSTPORT" \
                    --verbose --clean -w > $PGBACKUP_DIR/atldbbackup.sql.inprogress; } 2>&1 1>&3 )"
    PGBACKUP_STATUS=$?
    PGBACKUP_DONE="$(($(date +%s)-PGBACKUP_START))"
    calc_elapsed_time "$PGBACKUP_DONE"
      if [[ $PGBACKUP_STATUS -eq 0 ]]; then
        notify "PostgreSQL Database dump creation has completed successfully. Time taken was $elapsedtime. Verbose log output from PostgreSQL dump follows"
        echo -e "$PGBACKUP_LOG" | fold -w70 -s | sed '2~1s/^/  /' >&3
      else
        critical "" "PostgreSQL Database dump has failed. Time taken was $elapsedtime. Verbose log output from PostgreSQL dump follows"
        echo -e "$PGBACKUP_LOG" | fold -w70 -s | sed '2~1s/^/  /' >&3
      fi

    #Move and rename Database dump file
    if [[ $PGBACKUP_STATUS -eq 0 ]]; then
    # Switch to PGBACKUP_DIR && rename the atldbbackup.sql.inprogress file to atldbbackup.sql
    # Compression will be handled when creating the Borg backup file
    # This will also be wrapped in the $((command) 2>&1 1>&3) syntax to capture any errors during this process.
      PGBACKUPMV_LOG="$( { cd "$PGBACKUP_DIR" && mv -v atldbbackup.sql.inprogress atldbbackup.sql 2>&1; } )"
      PGBACKUPMV_STATUS=$?
      if [[ $PGBACKUPMV_STATUS -eq 0 ]]; then
        notify "PostgreSQL Backup file creation has completed successfully. Verbose log output follows"
        echo -e "$PGBACKUPMV_LOG" | fold -w70 -s | sed '2~1s/^/  /' >&3
      else
        critical "" "PostgreSQL Database dump has completed but creation of the backup file has failed. Log follows"
        echo -e "$PGBACKUPMV_LOG" | fold -w70 -s | sed '2~1s/^/  /' >&3
      fi
    fi
  fi

    # If verbosity is set warning or lower then all programs called by the backup script will run in default mode and command output is not captured.
  if [[ $verbosity -le "$wrn_lvl" ]]; then #i.e. -q or qq
    #Dump all PostgreSQL databases
    PGBACKUP_START="$(date +%s)"
    pg_dumpall --host="$PGHOSTNAME" --port="$PGHOSTPORT" --clean -w > $PGBACKUP_DIR/atldbbackup.sql.inprogress
    PGBACKUP_STATUS=$?
    PGBACKUP_DONE="$(($(date +%s)-PGBACKUP_START))"
    calc_elapsed_time "$PGBACKUP_DONE"
      if [[ $PGBACKUP_STATUS -eq 0 ]]; then
        notify "PostgreSQL Backup file creation has completed successfully. Time taken was $elapsedtime."
      else
        critical "" "PostgreSQL Database dump has failed. Time taken was $elapsedtime. Please re-run the script in verbose mode to turn on error messages"
      fi

    #Move and rename Database dump file
    if [[ $PGBACKUP_STATUS -eq 0 ]]; then
    # Switch to PGBACKUP_DIR && rename the atldbbackup.sql.inprogress file to atldbbackup.sql
    # Compression will be handled when creating the Borg backup file
    # This will also be wrapped in the $((command) 2>&1 1>&3) syntax to capture any errors during this process.
      cd "$PGBACKUP_DIR" && mv -v atldbbackup.sql.inprogress atldbbackup.sql
      PGBACKUPMV_STATUS=$?
        if [[ $PGBACKUPMV_STATUS -eq 0 ]]; then
          notify "PostgreSQL Backup file creation has completed successfully."
        else
          critical "" "PostgreSQL Database dump has completed but creation of the backup file has failed. Please re-run the script in verbose mode to turn on error messages"
        fi
    fi
  fi
}

#mount_s3 () {
  # S3QL requires the S3 Bucket to S3QL formatted before it can work with it. Since the mfks.s3ql command will re-prompt for the encryption
  # password on creation, the filesystem creation cannot be automated. There is also no "info" command available to gracefull check for the presence of a
  # S3QL filesystem. The best remaining option therefore is to try to run fsck and parse the error codes. "18" indicates the lack of a S3QL filesystem
  # Any other error code from this step will be simply redirected to the error log.
#}
  # Check if borg archive exists else create it for the first time
  # There can be multiple index files, but by checking for the existence of a "index.1" file guarantees that the archive exists
  # Checking for a hardcoded filename is not ideal, but this avoids having to add a for-do-done loop on top of an if-else loop
  #if [[ ! -e "$BORGBACKUP_DIR/$BORGTIP/index.1" ]]; then
  #  inf "The specific archive does not exist. Going to create it for the first time"
  #  # Borg requires an encryption password by default.
  #  # Script defaults to "repokey" mode, where the password will be stored in the backup repository
  #  inf "You will be prompted to input the encryption password for the repository. DO NOT LOSE the password and back up the repository config file!"
  #  inf "If you did not execute the script as N | ./script for the first time running it, press enter one more time after entering the repository password"
  #  BORGARCHCREATE_LOG="$((borg init -e repokey --verbose "$BORGBACKUP_DIR"/"$BORGTIP") 2>&1 1>&3)"
  #  debug "Running in verbose mode or greater. Verbose log output from creation of borg archive follows"
  #  echo -e "$BORGARCHCREATE_LOG" | fold -w70 -s | sed '2~1s/^/  /' >&3
  #else
  #  inf "The specified archive exists. Starting the archive creation process"
  #fi

  #Fsck the S3 mount, then mount the S3 bucket
  #If mount fails, exit violently
  #Create the archive directly on S3
  #Prune old backups
  #Unmount S3 mount

main
exit

