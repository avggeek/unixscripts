## Atlassian Application Backup Scripts

This script was developed to create a full backup (database and application folders) of various Atlassian products. Whether it's Confluence, Jira or any other product, Atlassian _[repeatedly](https://confluence.atlassian.com/doc/site-backup-and-restore-163578.html)_ _[recommends](https://confluence.atlassian.com/adminjiraserver071/backing-up-data-802592964.html)_ not relying on the XML backups created by their products and instead suggest rolling your own. Well, this is my version of "rolling your own" backup.

### Table of Contents
   - #### [Features](#features)
   - #### [Installation](#getscripts)
   - #### [Dependencies](#dependencies)
   - #### [Caveats](#caveats)
   - #### [Scheduling](#scheduling)
   - #### [To-Do](#todo)
 

#### [Features](features)
- Backup databases and application folders to an online remote storage service. Supported services include Google Storage, Amazon S3, Openstack etc.
- Backups are stored in an encrypted filesystem at rest and the backups themselves are encrypted.
- Backups are LZMA compressed to minimize backup archive sizes. *Refer also to the [To-Do](#todo) section on the usage of LZMA as a compression format*. 
- Automatically prune older backups. The default is to hold 30 daily backups. This can be changed through a couple of variables in the script.
- Sane defaults to exclude unwanted folders in the filesystem backup. New folders can easily be added in a single user-defined variable.
- Non-verbose logging by default. The script also provides a built-in way to send output to a log file.
- A set of helper scripts to help setup an encryped S3QL filesystem and an encrypted Borg archive (optional)

#### [Installation](getscripts)
The simplest way to get the backup scripts would be to checkout the entire repository and then move the scripts into the user's $PATH. Example instructions are given below using the repository URL on GitHub:
```
$ mkdir ~/backup-scripts && cd ~/backup-scripts
$ git init
$ git remote add origin https://github.com/avggeek/unixscripts.git
$ git pull origin master
#Add the backup script to the user's $PATH
$ mv ./atlassian-backup/atl-backup*.sh ~/bin/
```
<!---
If you would like to avoid checking  out all the other files in this repository, you will need to do some preliminary work to prepare a sparse checkout.
```
mkdir ~/backup-scripts && cd ~/backup-scripts
git init
git remote add origin https://github.com/avggeek/unixscripts.git
git config core.sparsecheckout true
echo "atlassian-backup/*" >> .git/info/sparse-checkout
git pull --depth=2 origin master
#Add the backup script to the user's $PATH
mv ./atlassian-backup/atl-backup*.sh ~/bin/
```
--->

#### [Script Dependencies](dependencies)
- The script relies on some Bash built-in's that are only available in Bash v4 or higher. This is available by default on any reasonably modern Debian/Ubuntu install.
- S3QL tools must be installed. For Debian/Ubuntu,  running `sudo apt-get install s3ql` is sufficient.
- The BorgBackup program is installed. On Debian 9, if `jessie-backports` is enabled then v1.1.4 is available via `sudo apt-get install borgbackup`. For Ubuntu 16.04 LTS, the default repositories only have v1.0.x available. I would suggest downloading a prebuilt binary from the BorgBackup [releases page](https://github.com/borgbackup/borg/releases).
- An authinfo2 file that contains authentication information for S3QL to connect to a supported online service. If the script is run in setup mode and it does not find an authinfo2 file, it will prompt for details to create one.
- In order to backup the databases, a .pgpass file should be available. Since the script relies on **pg_dumpall** (Refer [To-Do](#todo) for planned improvements), the username specified here must have superuser privileges. 
#### [Caveats](caveats)
The standard dependencies are listed in the [dependencies](#dependencies) section. Other caveats are:

- The script does not guarantee that the backup snapshot is consistent beyond the consistency guarantees offered by the tools it uses. To be more specific:
    - `pg_dumpall` which is used by the script to backup databases, does guarantee that that the backup is consistent even if the database being backed up is in use.
 
     - Borg does not offer filesystem consistency guarantees unless the backup target is a filesystem snapshot. On a server hosting a heavily used JIRA or Bitbucket instance, this can mean that a file that has is being backed up by Borg may have changed by the time the backup completes. 
     - If you need to guarantee that the filesystem backup is  consistent, you have to either: 
          - Take a snapshot of the application folders if the filesystem (such as `zfs` or `btrfs`) offers a snapshot capability and set the backup source (`$BORGBACKUP_SRC`) in the script to point to the snapshot location; or 
          - Block access to JIRA / put Bitbucket into read-only mode while the backup script is executing. 
          
            Implementing either of the above is currently not within the scope of this backup script.
    
- While I have tested each portion of the script individually and the complete script as well in different combinations, there are probably some hidden assumptions in the code that are not obvious to me and thus not tested - refer also to the [To-Do](#todo) section. Obviously, a backup script that is not tested exhaustively should make you nervous, the answer therefore is - TEST YOUR BACKUPS! Remember folks, I'm not really a sysadmin I just pretend to be one.
 - The script has been tested only on Debian 9 and Ubuntu 16.04 LTS. It will likely work on other Debian/Ubuntu derivatives without any changes required but that's about all I can promise.
 - The script only supports backing up PostgreSQL databases. 
 - The filesystem backup portion of the script has only been tested with BorgBackup v1.1.x. If the script is run in setup mode and it does not find a borg archive, it will create a new one - the archive created by default is not incompatible with v1.0.x, but I would not recommend using a 1.0.x release as there are known data corruption issues with the Borg v1.0.x releases and Borg releases <1.1.4.

#### [Scheduling the Backup](scheduling)
- The script `atl-backup-cron.sh` provides a convenient wrapper to call the main backup script in a cron-job.
- The wrapper script provides options to redirect job completion emails if there is an error. 
- Depending on how the BorgBackup program was installed, it may not be available in the `$PATH` that is available during cron-job execution. An example of how to schedule the wrapper script is given below, which includes a more complete `$PATH`
```
PATH=/root/bin/:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# This will run at 1:10 AM every day
10 1 * * * root if [ -x /root/bin/atl-backup-cron.sh ]; then /root/bin/atl-backup-cron.sh >/dev/null 2>&1; fi
```
**_Warning_**: In order to capture program output, at various points the script generates a temporary log file in the `/tmp` directory with a date timestamp on the filename. I would not recommend running this script just before midnight - depending on the time taken to complete the backup, if the clock rolls over during the script execution it can have unintended consequences.

#### [To-Do / Limitations](todo)
:white_medium_square: Fix the inevitable bugs that I have not spotted yet.

:white_medium_square: pg_dumpall suffers from a few limitations when it comes to use in a backup script. I need to switch to the more recommended approach, which is to use pg_dumpall to backup global parameters and pg_dump for the actual databases. Progress on this will be tracked in [[SERVERS-46]](https://jira.theaveragegeek.com/projects/SERVERS/issues/SERVERS-46)

:white_medium_square: The script creates .LZMA archives by default. While there is not much difference from an implementation perspective between LZMA and LZMA2 (.xz), LZMA2 is the future and LZMA will eventually be deprecated. I will need to update the script to use .xz by default instead and also migrate the older archives to the new format.

:white_medium_square: The script uses the `BORG_PASSPHRASE` environment variable. Since the variable is set by exporting an environment variable, there is no risk of having the passphrase be visible in the process list. However, Borg also offers a `BORG_PASSCOMMAND`variable which seems like a more robust option.

:white_medium_square:  Currently the script errors out if it finds that the  S3QL filesystem is already mounted. While this is not recommended for a backup filesystem, it's probably worth downgrading this to a warning instead of a critical error.

:white_medium_square: If the script is switching to use pg_dump, the setup portion of the script will need to be updated to create a new config file that stores database username/passwords (preferably with support for multiple users).

:white_medium_square: With the above, the setup portion is going to be increasingly complex. It probably makes sense to split this out as a separate "helper" script.

:white_medium_square: There is a fair bit of repetitive code in the script right now, especially the if-else loop for printing completion messages & debug logs. This should be refactored - probably as a separate function.




