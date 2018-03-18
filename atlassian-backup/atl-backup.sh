#!/bin/bash

# Script to backup PostgreSQL databases as well as Atlassian application data folders to Amazon S3.
# Mostly taken from /usr/share/doc/s3ql/examples/s3ql_backup.sh, https://wiki.postgresql.org/wiki/Automated_Backup_on_Linux
# and https://gist.github.com/cm6051/a7a67c30b2ef3f52f8c5. Shout-out to the many SO commenters who provided working
# Bash examples for me to learn from.
# VER=0.12                                                 # (Release name "aka Good Enough")

# Dependencies:  S3QL, Borgbackup, presence of ~/.s3ql/authinfo2 and ~/.pgpass files under user running the job.
#                Borg backup archives are assumed to be created in repokey (password) mode.
#                Password files should have file permissions set to 0600 for safety


# User-defined Script Variables
S3QLMNT="/var/backups/s3qlmnt"
S3QLPASSFILE="" #will default to ~/.s3ql/authinfo2 if empty
S3QLCACHEDIR="" #will default to ~/.s3ql if empty
S3QLCACHESIZE="" #To be specified in KiB. will default to 4GB if empty.
S3QLMNTDATE="" #will default to ~/.config/s3qlmntdate.log if empty
PGPASSFILE="" #will default to ~/.pgpass if empty
#PGBACKUP_DIR="/var/backups/postgresql"
PGBACKUP_DIR="$S3QLMNT/postgresql"
PGBACKUPS_TO_KEEP=30 #days
BORG_CONFIG_DIR="$HOME/.config/borg" #As per Borg defaults
BORGPASSFILE="" #will default to $BORG_CONFIG_DIR/pass/$BORGTIP if empty
#BORGBACKUP_DIR="/var/backups/borg"
BORGBACKUP_DIR="$S3QLMNT/borg"
BORGTIP=atlbackup
BORGBACKUP_SRC="/var/atlassian/application-data"
# Enter a series of comma-separated folder paths. Paths can have spaces in them.
BORGEXCLUDE_DIR="/var/atlassian/application-data/*/log/*,/var/atlassian/application-data/*/export/*,/var/atlassian/application-data/*/analytics-logs/*"
# Keep 30 end of day, 4 additional end of week archives, and an end of month archive for every month:
BORGBACKUPS_TO_KEEP="--keep-daily=30"

# Script starts here! Do not make any changes unless you are absolutely sure of what you are doing!

# Good habits
set -o nounset
set -o noglob
set -o pipefail
# Dev habits
#set -o xtrace
#set -o nounset
#set -o noglob
#set -o pipefail


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
        # Expand escaped characters, wrap at 80 chars, indent wrapped lines
        echo -e "$datestring $2" | fold -w80 -s | sed '2~1s/^/                    /' >&3
    fi
}


# EXAMPLE: notify "This logging system uses the standard verbosity level mechanism to choose which messages to print. Command line arguments customize this value, as well as where logging messages should be directed (from the default of STDERR). Long messages will be split at spaces to wrap at a character limit, and wrapped lines are indented. Wrapping and indenting can be modified in the code."
# CRITICAL ERROR example: critical "" "Abort"

usage() {
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo "Options:"
    echo "  -h      : display this help message"
    echo "  -e      : Execute the backup script"
    echo "  -s      : Run setup for the backup script"
    echo "  -v      : increase verbosity level (can be repeated .i.e. -vv for debug logging)"
    echo "  -l=FILE : redirect logging to FILE"
}

#Parameter checks
if [[ $# -eq 0 ]]; then
     echo "No arguments provided. Please use one of the following valid arguments. Arguments are not positional."
     usage; exit 1 ;
fi
if [[ $# -gt 3 ]]; then
    echo "Too many arguments provided. Script requires no more than 3 parameters"
    usage; exit 1 ;
fi

# Script layout breaks the verbosity parameter, so this is the only workaround that I can think of :-(
if [[ $# -gt 1 ]] && [[ ${1:-""} == -vv* || ${2:-""} == -vv* || ${3:-""} == -vv* ]]; then
    verbosity=$(( verbosity+1 ))
fi


# Redirect log messages to log file specified on the command line. Multiple Or conditions and 
# If loops since I'm letting arguments not be positional.
if [[ $# -gt 1 ]] && [[ ${1:-""} == -l=* || ${2:-""} == -l=* || ${3:-""} == -l=* ]]; then
    inf "Logging enabled";
    if [[ $1 == -l=* ]]; then LOGINPUT="$1"; elif [[ $2 == -l=* ]]; then LOGINPUT="$2"; elif [[ $3 == -l=* ]]; then LOGINPUT="$3"; fi
    IFS="=" read LOG LOGNAME <<< "$LOGINPUT"
    unset IFS
    exec 4<> "${LOGNAME}"
    exec 3>&4
fi

#if [[ $# -gt 1 ]] && [[ ${1:-""} == -l* || ${2:-""} == -l* || ${3:-""} == -l* ]]; then
#    debug "Log file will be closed now. Any error after this will print to STDOUT"
#    exec 4<&-
#fi


# Figure out where in the filesystem we are
SCRIPTPATH=$(dirname "$(readlink -f "$0")")

setup() {
  notify "Setup now starting"

  # Check for presence of S3QL authentication file, else create the file.
  if [[ ! -f "${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}" ]] 
    then  inf "S3QL authinfo does not exist. Script will now prompt for details to create this file. \
Note that the file created works for S3 backend only."
          read -p "Enter S3 Bucket Name: " S3BUCKET
          read -p "Enter IAM Access Key ID: " S3USER
          read -p "Enter IAM Access Key Secret: " -s S3PASS
          read -p "Enter filesystem encryption passphrase: " -s S3FSPASS
          # TODO: Add comparision check to ensure password is not typed wrongly
          local S3QLPASSDIR=$(dirname "${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}")
          { notify "Creating S3QL config directory as it does not exist"; \
          mkdir -p "$S3QLPASSDIR"; touch "$S3QLPASSDIR/authinfo2"; }
          printf '[s3]\nstorage-url: s3://%s/\nbackend-login: %s\nbackend-password: %s\nfs-passphrase: %s\n '\
           "$S3BUCKET" "$S3USER" "$S3PASS" "$S3FSPASS" > "${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}"
          if [[ $? -eq 0 ]]; then { chmod 0600 "${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}"; \
            notify "S3QL Authentication file successsfully created."; }; \
          else { critical "" "S3QL Authentication file creation failed. Aborting."; exit 1; }; fi
   else
    :
  fi

  # Make S3QL filesystem
  declare authinfo_array
  local S3QLAUTHFILE="${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}"
  readarray -s 1 authinfo_array < "$S3QLAUTHFILE"
  IFS=": " read parameter S3BUCKET <<< ${authinfo_array:0}
  IFS=": " read parameter S3USER <<< ${authinfo_array:1}
  IFS=": " read parameter S3PASS <<< ${authinfo_array:2}
  IFS=": " read parameter S3FSPASS <<< ${authinfo_array:3}
  unset IFS
  local CACHEDIR="${S3QLCACHEDIR:-$HOME/.s3ql/}"
  local CACHESIZE="${S3QLCACHESIZE:-3906250}"
  hash mkfs.s3ql 2>/dev/null || { critical "" "S3QL tools cannot be found in $USER's PATH. Aborting."; exit 1; }
  
  debug "Going to check if an S3QL filesystem exists at the specified location before trying to create one"
  s3qladm --debug --authfile "$S3QLAUTHFILE" upgrade "$S3BUCKET" &> /tmp/s3qlcheck-$(date +%Y%m%d).log
  local S3QLCHECK_LOG="$(</tmp/s3qlcheck-$(date +%Y%m%d).log)" && rm /tmp/s3qlcheck-$(date +%Y%m%d).log
  local S3QLCHECK_STATUS=$?
  
  if [[ $S3QLCHECK_STATUS -eq 18 ]]; then
        debug "No S3QL filesystem exists at specified bucket. Proceeding to create the S3QL filesystem"
        { S3QL_FSCREATE_LOG=$(expect -f "$SCRIPTPATH/tool/s3ql-create.exp" \
        "$CACHEDIR" "$S3BUCKET" "$S3USER" "$S3PASS" "$S3FSPASS") 2>&1 1>&3;}
        local S3QLFS_CREATE_STATUS=$?
        if [[ $S3QLFS_CREATE_STATUS -eq 0 ]]; then
          # Set the creation date of the S3QL FS as the first "mount" date, 
          # to be used to determine when fsck.s3ql should run
          printf '%(%Y%m%d)T' > "${S3QLMNTDATE:-$HOME/.cache/s3qlmntdate.log}"
          notify "FS created successfully.  Verbose log output from mkfs program follows. \
This will include the decryption key - please save it somewhere safe!"
          echo -e "$S3QL_FSCREATE_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
        else
          error "FS creation has failed. Verbose log output from mkfs program follows"
          echo -e "$S3QL_FSCREATE_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
        fi
  elif [[ $S3QLCHECK_STATUS -eq 0 ]]; then
    notify "The bucket defined in $S3QLAUTHFILE already has an S3QL compatible filesystem. Nothing further to do."
    local S3QLFS_CREATE_STATUS=0
  elif [[ $S3QLCHECK_STATUS -ne 0 || $S3QLCHECK_STATUS -ne 18 ]]; then
    error "There is a problem in checking whether the bucket defined in $S3QLAUTHFILE has \
an S3QL compatible filesystem. Log follows"
    echo -e "$S3QLCHECK_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
    local S3QLFS_CREATE_STATUS=99
  fi

  # Mount S3QL filesystem before proceeding to create Backup folders.
  debug "Mounting the S3QL filesystem at $S3QLMNT"
  if [[ $S3QLFS_CREATE_STATUS -eq 0 ]]; then
      mount.s3ql --debug --cachedir "$CACHEDIR" --cachesize "$CACHESIZE" --authfile \
      "$S3QLAUTHFILE" "$S3BUCKET" "$S3QLMNT" &> /tmp/s3qlmnt-$(date +%Y%m%d).log
      local S3QLMNT_STATUS=$?
      local S3QLMNT_LOG="$(</tmp/s3qlmnt-$(date +%Y%m%d).log)" && rm /tmp/s3qlmnt-$(date +%Y%m%d).log

      if [[ $S3QLMNT_STATUS -eq 0 ]]; then
        notify "S3QL filesystem was mounted successfully."
      elif [[ $S3QLMNT_STATUS -ne 0 ]]; then
        error "Mounting S3QL filesystem failed. Verbose log output follows. Aborting the rest of the setup script."
        echo -e "$S3QLMNT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
        exit 1
      fi
  elif [[ $S3QLFS_CREATE_STATUS -ne 0 ]]; then
      error "Creating S3QL filesystem failed. Aborting the rest of the setup script."
      exit 1
  fi

  # Create PostgreSQL backup directory
  # Before attempting to create Backup directories, check if parent directories are writeable
  local PGBACKUP_PARENT=$(dirname "${PGBACKUP_DIR}")
  if [[ ! -w "$PGBACKUP_PARENT" ]]; then warn "Directory where PostgreSQL backups are to be stored \
are not writeable by $USER. Unless $PGBACKUP_DIR already exists and is writeable, the script will \
fail trying to create the directory/backup files"; else :; fi
  # Create backup directories in S3QL mount
  if [[ ! -d "$PGBACKUP_DIR" ]]; then { notify "Creating PostgreSQL Backup directory as it does not \
exist" ; mkdir -p "$PGBACKUP_DIR"; }; fi;
  local CMDSTATUS=$?
  if [[ $CMDSTATUS -eq 0 ]]; then notify "PostgreSQL Backup directory successfully created"; \
  elif [[ $CMDSTATUS -ne 0 ]]; then error "Told you creating the PostgreSQL Backup directory was going \
to fail"; fi

  # Create borg backup directory in S3QL mount
  local BORGBACKUP_PARENT=$(dirname "${BORGBACKUP_DIR}")
  if [[ ! -w "$BORGBACKUP_PARENT" ]]; then warn "Directory where Borg backup files are to be stored \
are not writeable by $USER. Unless $BORGBACKUP_DIR already exists and is writeable, the script \
will fail trying to create the directory/backup files"; else :; fi
  if [[ ! -d "$BORGBACKUP_DIR" ]]; then \
    { notify "Creating Borg backup directory as it does not exist" ; mkdir -p "$BORGBACKUP_DIR"; }; fi;
  local CMDSTATUS=$?
  if [[ $CMDSTATUS -eq 0 ]]; then notify "Borg backup directory successfully created"; \
  elif [[ $CMDSTATUS -ne 0 ]]; then error "Told you creating the Borg backup directory was going \
to fail"; fi

  # Create borg archive
  if [[ ! -d "$BORGBACKUP_DIR" ]]; then { critical "" "Creation of Borg backup archive requires Borg \
directory to created in S3QL mount point. Aborting."; exit 1; }; fi;
  # Check for presence of helper script and other dependencies first
  hash expect 2>/dev/null || { error "Creation of Borg backup archive requires \
expect program to available but it cannot be found in $USER's PATH. Aborting."; exit 1; }
  if [[ ! -f "$SCRIPTPATH/tool/borg-create.exp" ]]; then { error "Helper script to create Borg archive \
is not in the expected location - $SCRIPTPATH/tool/borg-create.exp. Aborting."; exit 1; }; fi;
  # Check if borg archive exists else create it for the first time
  # Checking for a hardcoded filename is not ideal, but this avoids having to add a 
  # for-do-done loop on top of an if-else loop
  if [[ ! -f "$BORGBACKUP_DIR/$BORGTIP/nonce" ]]; 
    then notify "The specific archive does not exist. Going to create it for the first time" 
    read -p "Enter Borg archive encryption password:" -s READPASS
    ## TODO: Add comparision check to ensure password is not typed wrongly
    # Suppress Borg display passphrase for verification messages
    export BORG_DISPLAY_PASSPHRASE=N
    # Archive creation in wrapped in a modified version of $((command) 2>&1 1>&3) syntax to capture any errors during this process.
    { cd "$BORGBACKUP_DIR"; BORGINIT_LOG=$(expect -f "$SCRIPTPATH/tool/borg-create.exp" "$BORGTIP" "$READPASS") 2>&1;}
    local BORGINIT_STATUS=$?
    if [[ $BORGINIT_STATUS -eq 0 ]]; then
      #Store the Borg encryption password since the archive has been created
      local PASSFILE="${BORGPASSFILE:-$BORG_CONFIG_DIR/pass/$BORGTIP}"
      printf '%s' "$READPASS" > "$PASSFILE"
      chmod 0600 "$PASSFILE"
      notify "Borg archive has created successfully.  Verbose log output from Borg program follows"
      echo -e "$BORGINIT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
    else
      critical "" "Borg archive creation has failed. Verbose log output from Borg program follows"
      echo -e "$BORGINIT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
    fi
  else
    :
  fi

  # Unmount the filesystem now that all folders have been created
  inf "Now unmounting the S3QL filesystem at $S3QLMNT"
  s3qlctrl --debug flushcache "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log
  s3qlctrl --debug upload-meta "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log
  umount.s3ql --debug "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log
  local S3QLUMNT_STATUS=$?
  local S3QLUMNT_LOG="$(</tmp/s3qlumnt-$(date +%Y%m%d).log)" && rm /tmp/s3qlumnt-$(date +%Y%m%d).log

      if [[ $S3QLUMNT_STATUS -eq 0 ]]; then
        notify "S3QL filesystem was unmounted successfully."
      elif [[ $S3QLUMNT_STATUS -ne 0 ]]; then
        critical "" "Unmounting S3QL filesystem failed."
      fi

}


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
  # Check if required files exist
  if [[ ! -f "${PGPASSFILE:-$HOME/.pgpass}" ]]; then { critical "" "PostgreSQL configuration file is \
not available in specified location. Aborting."; exit 1; } else :; fi
  if [[ ! -f "${BORGPASSFILE:-$BORG_CONFIG_DIR/pass/$BORGTIP}" ]]; then { critical "" "Borg encryption \
keyfile password is not available in specified location. Maybe run the script in setup mode? \
Aborting."; exit 1; } else :; fi
  if [[ ! -f "${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}" ]]; then { critical "" "S3QL authentication file \
is not available in specified location. Maybe run the script in setup mode? Aborting."; exit 1; } else :; fi

}

check_dirs () (
  #Check if required directories exist
  if [[ ! -d "$PGBACKUP_DIR" ]]; then { critical "" "Directory to store PostgreSQL dump does not \
exist or is not mounted. Aborting."; exit 1; }; fi;
  if [[ ! -d "$BORGBACKUP_DIR" ]]; then { critical "" "Directory to store borg archives does not \
exist or is not mounted. Aborting."; exit 1; }; fi;
  # Check if required executables exist in user's $PATH
  hash pg_dumpall 2>/dev/null || { error "Script requires pg_dumpall program to be \
available but cannot be found in $USER's PATH. Aborting."; exit 1; }
  hash borg 2>/dev/null || { error "Script requires borg program to be available but \
cannot be found in $USER's PATH. Aborting."; exit 1; }
  hash mount.s3ql 2>/dev/null || { error "Script requires S3QL tools but they are not available in \
$USER's PATH. Aborting."; exit 1; }

  # Check if target directories for Borg to backup exist
  for dir in $BORGBACKUP_SRC; do if [[ ! -d "$dir" ]]; then { critical "" "Target directory(ies) for \
Borg to backup $dir is(are) missing" ; exit 1; } fi; done

)

mount_s3 () {
  # Create a file to record when the S3QL filesystem was last mounted if it does not exist
  if [[ ! -f "${S3QLMNTDATE:-$HOME/.cache/s3qlmntdate.log}" ]]; then { inf "Deciding that the S3QL \
filesystem was mounted for the first time right now" ; printf '%(%Y%m%d)T' > \
"${S3QLMNTDATE:-$HOME/.cache/s3qlmntdate.log}" ; }; else :; fi

  local S3QLAUTHFILE="${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}"
  local CACHEDIR="${S3QLCACHEDIR:-$HOME/.s3ql/}"
  local CACHESIZE="${S3QLCACHESIZE:-3906250}"
  readarray -s 1 authinfo_array < "$S3QLAUTHFILE"
  IFS=": " read parameter S3BUCKET <<< ${authinfo_array:0}
  unset IFS

  # S3QL requires the S3 Bucket to S3QL formatted before it can work with it. 
  # There is no "info" command available to gracefully check for the presence of a
  # S3QL filesystem. The best remaining option therefore is to try to run s3qladm upgrade and 
  # parse the error codes. s3qladm upgrade will exit with error code 0 if
  # the filesystem is already at the latest compatible version (which should have happened at the 
  # time of FS creation). "18" indicates the lack of a S3QL filesystem
  # Any other error code from this step will be simply redirected to the error log
  debug "Going to check for a S3QL compatible filesystem now"
  local S3QLCHECKS_START="$(date +%s)"

  # All programs will run in verbose mode by default. Depending on the verbosity parameter & 
  # exit codes, the logging output will change.

  # s3ql programs seem to generate output that cannot be captured in a variable even after redirecting
  # STDOUT & STDERR. For these programs, fall back to capturing output in a file and then loading the
  # file to a variable.
  s3qladm --debug --authfile "$S3QLAUTHFILE" upgrade "$S3BUCKET" &> /tmp/s3qlcheck-$(date +%Y%m%d).log
  local S3QLCHECK_LOG="$(</tmp/s3qlcheck-$(date +%Y%m%d).log)" && rm /tmp/s3qlcheck-$(date +%Y%m%d).log
  local S3QLCHECK_STATUS=$?
  
      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLCHECK_STATUS -eq 0 ]]; then #i.e. -vv
        debug "S3QL filesystem exists at specified bucket. Proceeding to mount the S3QL filesystem"
        local S3QLCHECKRTN=0
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLCHECK_STATUS -eq 18 ]]; then
        critical "The bucket defined in $S3QLAUTHFILE does not have an S3QL compatible filesystem. \
Either run mkfs.s3ql if you are not using S3 or execute the script in setup mode. Log follows"
        echo -e "$S3QLCHECK_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
        local S3QLCHECKRTN=18
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLCHECK_STATUS -ne 0 || $S3QLCHECK_STATUS -ne 18 ]]; then
        critical "" "There is a problem in checking whether the bucket defined in $S3QLAUTHFILE has \
an S3QL compatible filesystem. Log follows"
        echo -e "$S3QLCHECK_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
        local S3QLCHECKRTN=99
      fi

      # If verbosity is set warning or lower then command output is not printed.
      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLCHECK_STATUS -eq 0 ]]; then #i.e. -q or qq
        notify "S3QL filesystem exists at specified bucket. Proceeding to mount the S3QL filesystem"
        local S3QLCHECKRTN=0
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLCHECK_STATUS -eq 18 ]]; then
        critical "The bucket defined in $S3QLAUTHFILE does not have an S3QL compatible filesystem. \
Either run mkfs.s3ql if you are not using S3 or execute the script in setup mode"
        local S3QLCHECKRTN=18
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLCHECK_STATUS -ne 0 || $S3QLCHECK_STATUS -ne 18 ]]; then
        critical "" "There is a problem in checking whether the bucket defined in $S3QLAUTHFILE has an \
S3QL compatible filesystem. Please re-run the script in verbose mode to turn on error messages"
        local S3QLCHECKRTN=99
      fi
  
  #Abort! Abort! Abort!
  if [[ $S3QLCHECKRTN -eq 18 ]]; then
    # Since all backup targets will be on the S3QL filesystem - 
    # for every check, this function will return an exit code 
    # The exit code must be checked by every other function called by main()
    critical "" "S3QL compatible filesystem does not exist. Exiting"
    export S3QL_STATUS=18
    return 18
  elif [[ $S3QLCHECKRTN -eq 99 ]]; then
    critical "" "Presence of S3QL compatible filesystem could not be determined. Exiting"
    export S3QL_STATUS=99
    return 99
  elif [[ $S3QLCHECKRTN -ne 0 ]]; then
    critical "" "A problem occured when checking for a S3QL compatible filesystem. Exiting"
    export S3QL_STATUS=1
    return 1
  fi

  # Check when the S3QL filesytsem was last fsck'ed and run fsck if that was more than 29 days ago. 
  # (Warning starts on day 30)
  debug "Going to check if fsck must be run on the S3QL filesystem now"
  local LASTMNTDATE=$(($(date -f "${S3QLMNTDATE:-$HOME/.cache/s3qlmntdate.log}" +%s)))
  local MNTLAPSEDDAYS=$(( ($(date +%s) - ($LASTMNTDATE) )/(24*3600) ))
  if [[ $MNTLAPSEDDAYS -gt 29 ]]; then
    fsck.s3ql --force --debug --authfile "$S3QLAUTHFILE" --cachedir "$CACHEDIR" "$S3BUCKET" &> \
    /tmp/s3qlfsck-$(date +%Y%m%d).log
    local S3QLFSCK_STATUS=$?
    local S3QLFSCK_LOG="$(</tmp/s3qlfsck-$(date +%Y%m%d).log)" && rm /tmp/s3qlfsck-$(date +%Y%m%d).log
    local S3QLCHECKS_DONE="$(($(date +%s)-S3QLCHECKS_START))"
    calc_elapsed_time "$S3QLCHECKS_DONE"
  else
    local S3QLFSCK_STATUS=50
    local S3QLFSCK_LOG=""
  fi

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLFSCK_STATUS -eq 0 ]]; then
        #Update timestamp for when fsck was last run
        printf '%(%Y%m%d)T' > "${S3QLMNTDATE:-$HOME/.cache/s3qlmntdate.log}"
        debug "fsck of S3QL filesystem has completed successfully. Time taken was $elapsedtime. Verbose log output follows"
        echo -e "$S3QLFSCK_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLFSCK_STATUS -eq 50 ]]; then
        notify "fsck of S3QL filesystem was not required as it was last run less than 30 days ago."
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLFSCK_STATUS -ne 0 || $S3QLFSCK_STATUS -ne 50 ]]; then
        critical "" "fsck of S3QL filesystem failed. Time taken was $elapsedtime. Verbose log output follows"
        echo -e "$S3QLFSCK_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLFSCK_STATUS -eq 0 ]]; then
        #Update timestamp for when fsck was last run
        printf '%(%Y%m%d)T' > "${S3QLMNTDATE:-$HOME/.cache/s3qlmntdate.log}"
        notify "fsck of S3QL filesystem has completed successfully."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLFSCK_STATUS -eq 50 ]]; then
        inf "fsck of S3QL filesystem was not required as it was last run less than 30 days ago."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLFSCK_STATUS -ne 0  || $S3QLFSCK_STATUS -ne 50 ]]; then
        critical "" "fsck of S3QL filesystem failed. Please re-run the script in verbose mode to turn on error messages"
      fi

  # All checks done. Now to actually mount the S3QL filesystem
  # PYSCHE! Before we actually mount the filesystem, let's check if it's already mounted for some reason hmmm?
  # We are not actually interested in the output of this command, only the exit code.
  debug "Check if the S3QL filesystem is mounted for some reason."
  s3qlstat "$S3QLMNT" &> /dev/null
  local S3QLSTAT_STATUS=$?

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLSTAT_STATUS -eq 0 ]]; then
        export S3QL_STATUS=0
        warn "S3QL filesystem is already mounted. Perhaps the script did not unmount correctly last time? \
Please run fsck. If an external script is mounting the filesystem, keeping the backup always mounted is not recommended."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLSTAT_STATUS -ne 0 ]]; then
        inf "S3QL filesystem is currently not mounted."
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLSTAT_STATUS -eq 0 ]]; then
        export S3QL_STATUS=0
        warn "S3QL filesystem is already mounted. Perhaps the script did not unmount correctly last time? \
Please re-run the script in verbose mode to check and also run fsck. If an external script is mounting the \
filesystem, keeping the backup always mounted is not recommended."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLSTAT_STATUS -ne 0 ]]; then
        inf "S3QL filesystem is currently not mounted."
      fi

  debug "All checks complete. Time to mount the S3QL filesystem at $S3QLMNT"
  mount.s3ql --debug --cachedir "$CACHEDIR" --cachesize "$CACHESIZE" --authfile \
  "$S3QLAUTHFILE" "$S3BUCKET" "$S3QLMNT" &> /tmp/s3qlmnt-$(date +%Y%m%d).log
  local S3QLMNT_STATUS=$?
  local S3QLMNT_LOG="$(</tmp/s3qlmnt-$(date +%Y%m%d).log)" && rm /tmp/s3qlmnt-$(date +%Y%m%d).log

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLMNT_STATUS -eq 0 ]]; then
        export S3QL_STATUS=0
        debug "S3QL filesystem was mounted successfully. Verbose log output follows"
        echo -e "$S3QLMNT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLMNT_STATUS -ne 0 ]]; then
        export S3QL_STATUS=1
        critical "" "Mounting S3QL filesystem failed. Verbose log output follows"
        echo -e "$S3QLMNT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLMNT_STATUS -eq 0 ]]; then
        export S3QL_STATUS=0
        notify "S3QL filesystem was mounted successfully."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLMNT_STATUS -ne 0 ]]; then
        export S3QL_STATUS=1
        critical "" "Mounting S3QL filesystem failed. Please re-run the script in verbose mode to turn on error messages"
      fi

}


dump_database () {
  #Check that S3QL mount point exists, else exit
  if [[ $S3QL_STATUS -eq 0 ]]; then
    debug "S3QL mount point exists. Proceeding with Database backup."
  elif [[ $S3QL_STATUS -ne 0 ]]; then
    critical "" "S3QL filesystem error. Not proceeding with Database backup "
    export PGSQL_STATUS=1
    return
  fi

  # Start by backing up PostgreSQL databases
  # Check for variables else set them
  if [[ -z ${PGHOST:-} ]]; then local PGHOSTNAME="localhost"; else local PGHOSTNAME="$PGHOST":; fi;
  if [[ -z ${PGPORT:-} ]]; then local PGHOSTPORT="5432"; else local PGHOSTPORT="$PGPORT":; fi;
  debug "About to connect to PostgreSQL instance running at $PGHOSTNAME:$PGHOSTPORT"

  local PGBACKUP_START="$(date +%s)"
  local PGBACKUP_LOG="$( { pg_dumpall --host="$PGHOSTNAME" --port="$PGHOSTPORT" \
                  --verbose --clean -w > $PGBACKUP_DIR/atldbbackup.sql.inprogress; } 2>&1 1>&3 )"
  local PGBACKUP_STATUS=$?
  local PGBACKUP_DONE="$(($(date +%s)-$PGBACKUP_START))"
  calc_elapsed_time "$PGBACKUP_DONE"
  
      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $PGBACKUP_STATUS -eq 0 ]]; then #i.e. -vv
          notify "PostgreSQL Database dump creation has completed successfully. Time taken was $elapsedtime. \
Verbose log output from PostgreSQL dump follows"
          echo -e "$PGBACKUP_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $PGBACKUP_STATUS -ne 0 ]]; then 
          critical "" "PostgreSQL Database dump has failed. Time taken was $elapsedtime. \
Verbose log output from PostgreSQL dump follows"
          echo -e "$PGBACKUP_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $PGBACKUP_STATUS -eq 0 ]]; then
          inf "PostgreSQL Database dump creation has completed successfully"
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $PGBACKUP_STATUS -ne 0 ]]; then
        critical "" "PostgreSQL Database dump has failed. Please re-run the script in verbose mode \
to turn on error messages"
      fi

  #Move and rename Database dump file
  if [[ $PGBACKUP_STATUS -eq 0 ]]; then
    # Switch to PGBACKUP_DIR && create an archive file of the atldbbackup.sql.inprogress file
    # This will also be wrapped in the $((command) 2>&1 1>&3) syntax to capture any errors during this process.
    local PGBACKUPMV_LOG="$( { cd "$PGBACKUP_DIR" && tar -cvf atldbbackup-"$(date +%s)".lzma --lzma \
    --transform "flags=r;s|\.inprogress||;s|\.sql|-$(date +%Y%m%d).sql|" --remove-files atldbbackup.sql.inprogress 2>&1; } )" #atldbbackup.sql
    local PGBACKUPMV_STATUS=$?
  else
    local PGBACKUPMV_LOG="No log for Backup file creation"
    local PGBACKUPMV_STATUS=1
  fi

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $PGBACKUPMV_STATUS -eq 0 ]]; then
          export PGSQL_STATUS=0
          notify "PostgreSQL Backup file creation has completed successfully. Verbose log output follows"
          echo -e "$PGBACKUPMV_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $PGBACKUPMV_STATUS -ne 0 ]]; then
          export PGSQL_STATUS=1
          critical "" "PostgreSQL Database dump has completed but creation of the backup file has failed. Log follows"
          echo -e "$PGBACKUPMV_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $PGBACKUPMV_STATUS -eq 0 ]]; then
          export PGSQL_STATUS=0
          notify "PostgreSQL Backup file creation has completed successfully."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $PGBACKUPMV_STATUS -ne 0 ]]; then
          export PGSQL_STATUS=1
          critical "" "PostgreSQL Database dump has completed but creation of the backup file has failed. \
Please re-run the script in verbose mode to turn on error messages"
      fi

}

borg_backup () {
  #Check that S3QL mount point exists, else exit
  if [[ $S3QL_STATUS -eq 0 ]]; then
    debug "S3QL mount point exists. Proceeding with Filesystem backup."
  elif [[ $S3QL_STATUS -ne 0 ]]; then
    critical "" "S3QL filesystem error. Not proceeding with Filesystem backup."
    export BORGBACKUP_STATUS=1
    return
  fi

  #Split the directories to be excluded into individual exclude parameters
  IFS="," 
  local EXCLUDEDIR=""
  for value in $BORGEXCLUDE_DIR;
    do 
      local EXCLUDEDIR="$EXCLUDEDIR --exclude '$value'"
  done
  unset IFS

  local PASSFILE="${BORGPASSFILE:-$BORG_CONFIG_DIR/pass/$BORGTIP}"
  local BORGPASS="$(<$PASSFILE)"
  local BORGBACKUP_START="$(date +%s)"
  debug "Going to start Filesystem backup using Borg now."
  
  # Borg seems to generate output that cannot be captured in a variable even after redirecting
  # STDOUT & STDERR. Hence, falling back to capturing in a file and then loading the
  # file to a variable.
  { export BORG_PASSPHRASE="$BORGPASS"; borg create --debug --compression auto,lzma\
   $EXCLUDEDIR "$BORGBACKUP_DIR/$BORGTIP::$BORGTIP-$(date +%s)" "$BORGBACKUP_SRC" &> /tmp/borgbk-$(date +%Y%m%d).log; } #
  local BORGBK_STATUS=$?
  local BORGBACKUP_LOG="$(</tmp/borgbk-$(date +%Y%m%d).log)" && rm /tmp/borgbk-$(date +%Y%m%d).log
  local BORGBACKUP_DONE="$(($(date +%s)-$BORGBACKUP_START))"
  calc_elapsed_time "$BORGBACKUP_DONE"

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $BORGBK_STATUS -eq 0 ]]; then #i.e. -vv
          export BORGBACKUP_STATUS=0
          notify "Borg backup archive creation has completed successfully. Time taken was $elapsedtime. \
Verbose log output from Borg backup follows"
          echo -e "$BORGBACKUP_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $BORGBK_STATUS -ne 0 ]]; then 
          export BORGBACKUP_STATUS=1
          critical "" "Borg backup archive creation has failed. Time taken was $elapsedtime. \
Verbose log output from Borg backup follows"
          echo -e "$BORGBACKUP_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $BORGBK_STATUS -eq 0 ]]; then
          export BORGBACKUP_STATUS=0
          notify "Borg backup archive creation has completed successfully"
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $BORGBK_STATUS -ne 0 ]]; then
          export BORGBACKUP_STATUS=1
          critical "" "Borg backup archive creation has failed. Please re-run the script in verbose \
mode to turn on error messages"
      fi
}

database_backup_prune () {
  #Check that S3QL mount point exists, else exit
  if [[ $S3QL_STATUS -eq 0 ]]; then
    debug "S3QL mount point exists. Going to check whether database backups can be pruned."
  elif [[ $S3QL_STATUS -ne 0 ]]; then
    critical "" "S3QL filesystem error. Not proceeding with checking whether database backups can be pruned."
    export DBPRUNE_STATUS=1
    return
  fi

  #Check whether the current run of dump_database exited successfully.
  if [[ $PGSQL_STATUS -eq 0 ]]; then
    debug "Databases were backed up successfully in this run. Older backups are safe to be pruned."
  elif [[ $PGSQL_STATUS -ne 0 ]]; then
    critical "" "Database backup did not complete successfully in this run. \
Not pruning older database backups to avoid removing older backups. Please re-run the script \
in verbose mode to determine why database backups failed."
    export DBPRUNE_STATUS=1
    return
  fi

  debug "Going to start pruning old database backups now."
  local PGBK_PRUNE_START="$(date +%s)"
  { PGBK_PRUNE_LOG=$(find $PGBACKUP_DIR -mindepth 1 -type f -mtime +$PGBACKUPS_TO_KEEP -delete -print) 2>&1 1>&3; }
  local PGBK_PRUNE_STATUS=$?
  local PGBK_PRUNE_DONE="$(($(date +%s)-$PGBK_PRUNE_START))"
  calc_elapsed_time "$PGBK_PRUNE_DONE"

  if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $PGBK_PRUNE_STATUS -eq 0 ]]; then #i.e. -vv
      export DBPRUNE_STATUS=0
      notify "Old database backups have been pruned successfully. Time taken was $elapsedtime. \
Verbose log output follows"
      echo -e "$PGBK_PRUNE_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
  elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $PGBK_PRUNE_STATUS -ne 0 ]]; then 
      export DBPRUNE_STATUS=1
      critical "" "Pruning old database backups has failed. Time taken was $elapsedtime. \
Verbose log output follows"
      echo -e "$PGBK_PRUNE_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
  fi

  if [[ $verbosity -le "$wrn_lvl" ]] && [[ $PGBK_PRUNE_STATUS -eq 0 ]]; then
      export DBPRUNE_STATUS=0
      notify "Old database backups have been pruned successfully."
  elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $PGBK_PRUNE_STATUS -ne 0 ]]; then
      export DBPRUNE_STATUS=1
      critical "" "Pruning old database backups has failed. Please re-run the script in verbose \
mode to turn on error messages"
  fi

}

borg_prune () {
  #Check that S3QL mount point exists, else exit
  if [[ $S3QL_STATUS -eq 0 ]]; then
    debug "S3QL mount point exists. Going to check whether filesystem backups can be pruned."
  elif [[ $S3QL_STATUS -ne 0 ]]; then
    critical "" "S3QL filesystem error. Not proceeding with checking whether filesystem backups can be pruned."
    export DBPRUNE_STATUS=1
    return
  fi

  #Check whether the current run of borg_backup exited successfully.
  if [[ $BORGBACKUP_STATUS -eq 0 ]]; then
    debug "Filesystem backup was completed successfully in this run. Older backups are safe to be pruned."
  elif [[ $BORGBACKUP_STATUS -ne 0 ]]; then
    critical "" "Filesystem backup did not complete successfully in this run. \
Not pruning older filesystem backups to avoid removing older backups. Please re-run the script \
in verbose mode to determine why filesystem backups failed."
    export BORGPRUNE_STATUS=1
    return
  fi

  local PASSFILE="${BORGPASSFILE:-$BORG_CONFIG_DIR/pass/$BORGTIP}"
  local BORGPASS="$(<$PASSFILE)"
  local BORGPRUNE_START="$(date +%s)"
  debug "Going to prune filesystem backups now."
  
  { export BORG_PASSPHRASE="$BORGPASS"; borg prune --debug $BORGBACKUPS_TO_KEEP "$BORGBACKUP_DIR/$BORGTIP" \
  &> /tmp/borgprune-$(date +%Y%m%d).log; } #
  local BORGPRN_STATUS=$?
  local BORGPRUNE_LOG="$(</tmp/borgprune-$(date +%Y%m%d).log)" && rm /tmp/borgprune-$(date +%Y%m%d).log
  local BORGPRUNE_DONE="$(($(date +%s)-$BORGPRUNE_START))"
  calc_elapsed_time "$BORGPRUNE_DONE"

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $BORGPRN_STATUS -eq 0 ]]; then #i.e. -vv
          export BORGPRUNE_STATUS=0
          notify "Pruning of filesystem backups has completed successfully. Time taken was $elapsedtime. \
Verbose log output follows"
          echo -e "$BORGPRUNE_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -gt "$wrn_lvl" ]] && [[ $BORGPRN_STATUS -ne 0 ]]; then 
          export BORGPRUNE_STATUS=1
          critical "" "Pruning filesystem backups has failed. Time taken was $elapsedtime. \
Verbose log output follows"
          echo -e "$BORGPRUNE_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $BORGPRN_STATUS -eq 0 ]]; then
          export BORGPRUNE_STATUS=0
          notify "Pruning of filesystem backups has completed successfully."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $BORGPRN_STATUS -ne 0 ]]; then
          export BORGPRUNE_STATUS=1
          critical "" "Pruning filesystem backups has failed. Please re-run the script in verbose \
mode to turn on error messages"
      fi

}

umount_s3 () {
  #Check that S3QL mount point exists, else exit
  if [[ $S3QL_STATUS -eq 0 ]]; then
    debug "S3QL mount point exists. Assuming that the rest of the backup script has executed \
at this stage, so going to unmount the S3QL filesystem."
  elif [[ $S3QL_STATUS -ne 0 ]]; then
    critical "" "S3QL filesystem error. It's probably not mounted so why bother trying to unmount."
    export S3QLUNMOUNT_STATUS=1
    return
  fi

  local S3QLAUTHFILE="${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}"
  readarray -s 1 authinfo_array < "$S3QLAUTHFILE"
  IFS=": " read parameter S3BUCKET <<< ${authinfo_array:0}
  unset IFS

  debug "Now unmounting the S3QL filesystem at $S3QLMNT"
  s3qlctrl --debug flushcache "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log
  s3qlctrl --debug upload-meta "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log
  umount.s3ql --debug "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log
  local S3QLUMNT_STATUS=$?
  local S3QLUMNT_LOG="$(</tmp/s3qlumnt-$(date +%Y%m%d).log)" && rm /tmp/s3qlumnt-$(date +%Y%m%d).log

      if [[ $verbosity -gt "$wrn_lvl" ]] && [[ $S3QLUMNT_STATUS -eq 0 ]]; then
        export S3QLUNMOUNT_STATUS=0
        debug "S3QL filesystem was unmounted successfully. Verbose log output follows"
        echo -e "$S3QLUMNT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLUMNT_STATUS -ne 0 ]]; then
        export S3QLUNMOUNT_STATUS=1
        critical "" "Unmounting S3QL filesystem failed. Verbose log output follows"
        echo -e "$S3QLUMNT_LOG" | fold -w80 -s | sed '1~1s/^/                    /' >&3
      fi

      if [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLUMNT_STATUS -eq 0 ]]; then
        export S3QLUNMOUNT_STATUS=0
        notify "S3QL filesystem was unmounted successfully."
      elif [[ $verbosity -le "$wrn_lvl" ]] && [[ $S3QLUMNT_STATUS -ne 0 ]]; then
        export S3QLUNMOUNT_STATUS=1
        critical "" "Unmounting S3QL filesystem failed. Please re-run the script in verbose mode to turn on error messages"
      fi

}

check_and_exit () {
    local  EXEC_TIME=$1
#PGSQL_STATUS, BORGBACKUP_STATUS, DBPRUNE_STATUS, BORGPRUNE_STATUS, S3QLUNMOUNT_STATUS
    if [[ $S3QL_STATUS -eq 0 ]] && [[ $PGSQL_STATUS -eq 0 ]] && [[ $BORGBACKUP_STATUS -eq 0 ]] && \
      [[ $DBPRUNE_STATUS -eq 0 ]] && [[ $BORGPRUNE_STATUS -eq 0 ]] && [[ $S3QLUNMOUNT_STATUS -eq 0 ]]; then
      notify "Backup script has completed successfully. Total elapsed time was $EXEC_TIME."
      exit 0
    elif [[ $S3QL_STATUS -ne 0 ]]; then
      critical "" "S3QL filesystem error. Backup script is exiting immediately. Please re-run the script in verbose mode to turn on error messages."
      exit 1
    elif [[ $PGSQL_STATUS -ne 0 ]]; then
      warn "Database backups could not be completed successfully. Please re-run the script in verbose mode to turn on error messages."
      exit 1
    elif [[ $BORGBACKUP_STATUS -ne 0 ]]; then
      warn "Filesystem backups could not be completed successfully. Please re-run the script in verbose mode to turn on error messages."
      exit 1
    elif [[ $S3QLUNMOUNT_STATUS -ne 0 ]]; then
      warn "S3QL Filesystem could not be unmounted cleanly. Total elapsed time was $EXEC_TIME. \
There may have been other errors during the script execution. Please re-run the script in verbose \
mode to turn on error messages."
      exit 0
    elif [[ $BORGPRUNE_STATUS -ne 0 ]]; then
      warn "Filesystem backups could not be pruned successfully. Total elapsed time was $EXEC_TIME. \
Please re-run the script in verbose mode to turn on error messages."
      exit 0
    elif [[ $DBPRUNE_STATUS -ne 0 ]]; then
      warn "Database backups could not be pruned successfully. Total elapsed time was $EXEC_TIME. \
Please re-run the script in verbose mode to turn on error messages."
      exit 0
    fi

    return 0

}

finish () {
  #Ignore trap within this function.
  trap "" EXIT HUP INT QUIT PIPE TERM;

  echo -e "Script received interrupt. Exiting now." | fold -w80 -s | sed '1~1s/^/                    /' >&3
  #Clean up after ourselves.
  if [[ -f "$PGBACKUP_DIR/atldbbackup.sql.inprogress" ]]; then rm "$PGBACKUP_DIR/atldbbackup.sql.inprogress"; fi

  local PASSFILE="${BORGPASSFILE:-$BORG_CONFIG_DIR/pass/$BORGTIP}"
  local BORGPASS="$(<$PASSFILE)"
  if [[ -d "$BORGBACKUP_DIR/$BORGTIP/lock.exclusive" ]]; then { export BORG_PASSPHRASE="$BORGPASS";\ 
    borg break-lock "$BORGBACKUP_DIR/$BORGTIP"; }; fi

  local S3QLAUTHFILE="${S3QLPASSFILE:-$HOME/.s3ql/authinfo2}"
  readarray -s 1 authinfo_array < "$S3QLAUTHFILE"
  IFS=": " read parameter S3BUCKET <<< ${authinfo_array:0}
  unset IFS
  umount.s3ql --debug "$S3QLMNT" &> /tmp/s3qlumnt-$(date +%Y%m%d).log #leaving this file after exit for investigation purposes.
  if [[ $# -gt 1 ]] && [[ ${1:-""} == -l* || ${2:-""} == -l* || ${3:-""} == -l* ]]; then
    exec 4<&-
  fi
  exit 99
}

trap finish HUP INT QUIT PIPE TERM

main () {
      check_dependencies
      local ALLBACKUP_START="$(date +%s)"
      # If one of the sub-functions is disabled, enable the corresponding parameter below to allow
      # the script to exit normally.
      # export S3QL_STATUS=0 #for mount_s3()
      # export PGSQL_STATUS=0 #for dump_database()
      # export BORGBACKUP_STATUS=0 #for borg_backup()
      # export BORGPRUNE_STATUS=0 #for borg_prune()
      # export DBPRUNE_STATUS=0 #for database_backup_prune()
      # export S3QLUNMOUNT_STATUS=0 #for umount_s3()
      mount_s3
      check_dirs
      dump_database
      borg_backup
      database_backup_prune
      borg_prune
      umount_s3
      local ALLBACKUP_DONE="$(($(date +%s)-$ALLBACKUP_START))"
      calc_elapsed_time "$ALLBACKUP_DONE"
      check_and_exit "$elapsedtime"
}

while getopts "hesvl:" opt; do
    case "$opt" in
       h) usage; exit 0 ;;
       e) main; exit 0 ;;
       s) setup; exit 0 ;;
       *) error "Invalid options: $1"; usage; exit 1 ;;
    esac
done
shift "$((OPTIND-1))"
args="$@"
