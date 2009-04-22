#!/bin/sh
#
# To check for your bot every 10 minutes, put the following line in your
# crontab:
#    0,10,20,30,40,50 * * * *   /home/mydir/mybot/pyrl_botchk.sh
#VARIABLES#
. /etc/pyrl.init.conf
lockfile=${LOCKFILE-/var/lock/subsys/pyrl}
pidfile=${PIDFILE-/var/run/pyrl.pid}

cd $pyrlpath

# is there a pid file?
if [ -r "$pidfile" ]
then
  # there is a pid file -- is it current?
  pid=`less "$pidfile" | awk '{print($1)}' | sed "s/[^0-9]//g"`
  if `kill -CHLD $pid >/dev/null 2>&1`
  then
    # it's still going -- back out quietly
    exit 0
  fi
  echo ""
  echo "Stale $pidfile file, erasing..."
  rm -f $pidfile
fi

#The rc.d/init.d script creates a couple of files if they are missing
#The next couple of files are also checked for. However, if run as a cronjob
#these errors should get mailed out to the cronjob owner

if ! [ -r "$pyrlpath/config.py" ] ; then
		echo "cannot find readable config.py at ${pyrlpath}. check that it is there and permissions are appropriate"
		exit 3
	elif ! [ -r "$pyrlpath/scheduler.py" ] ; then
		echo "cannot find the scheduler script in PATH ${pyrlpath}. Please copy the script into the pyrl folder"
		exit 3
	else
		#Trapping all messages from the service script file here.
		/sbin/service pyrl start >/dev/null 2>&1
fi

exit 0
