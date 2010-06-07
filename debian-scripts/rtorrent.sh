#!/bin/sh
### BEGIN INIT INFO
# Provides:          rtorrent
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs $network
# Should-Start:      $remote_fs $named
# Should-Stop:       $remote_fs $named
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Starts rTorrent daemon
# Description:       This script runs rTorrent in a dtach session
#                    to daemon-ize the application
### END INIT INFO
. /lib/lsb/init-functions
#VARIABLES#
. /home/rt/rtorrent.init.conf
PATH=/usr/bin:/usr/local/bin:/usr/local/sbin:/sbin:/bin:/usr/sbin
DESC="rtorrent via dtach"
NAME=rtorrent
DAEMON=rtorrent
SCRIPTNAME=/etc/init.d/$NAME
RTPIDFILE=/var/run/$NAME.pid
DTPIDFILE=/var/run/dtach-$NAME.pid

#Functions
checkconfig() {
        exists=0

        for i in `echo "$PATH" | tr ':' '\n'` ; do
                if [ -f $i/$DAEMON ] ; then
                        exists=1
                        appdir=$i
                        apppath=$i/$DAEMON
                        break
                fi
        done

        if ! [ -x "$apppath" ] ; then
                echo "cannot find executable rtorrent binary in PATH $appdir" | tee -a "$logfile" >&2
                exit 3
        fi

        if [ $exists -eq 0 ] ; then
                        echo "cannot find rtorrent binary in PATH $PATH" | tee -a "$logfile" >&2
                        exit 3
        fi

        if ! [ -r "${config}" ] ; then
                echo "cannot find readable config ${config}. check that it is there and permissions are appropriate" | tee -a "$logfile" >&2
                exit 3
        fi

        session=`getsession "$config"`
        if ! [ -d "${session}" ] ; then
                echo "cannot find readable session directory ${session} from config ${config}. check permissions" | tee -a "$logfile" >&2
                exit 3
        fi
}

getsession() {
        session=`awk '/^session/{print($3)}' "$config"`
        echo $session
}

makepidfiles() {
	#make sure files don't exist before we start
	if [ -r "$DTPIDFILE" ] ; then
	rm -f "$DTPIDFILE"
	fi
	if [ -r "$RTPIDFILE" ] ; then
		rm -f "$RTPIDFILE"
	fi
        dtpid=`ps -u ${user} | egrep dtach | awk '!/egrep/' | awk '{print($1)}'`
        rtpid=`ps -u ${user} | egrep ${DAEMON} | awk '!/egrep/' | awk '{print($1)}'`
        if [ -z $rtpid ] ; then
                echo "Finding PID(s) failed"
                exit 3
        else
                echo $rtpid > $RTPIDFILE
                echo $dtpid > $DTPIDFILE
        fi

}

start() {
log_daemon_msg "Starting daemon-ized dtach session for" "$NAME"

	OPTIONS="-n /tmp/dtach-${NAME} rtorrent"
	start-stop-daemon --start --chuid ${user} --pidfile "$DTPIDFILE" --startas /usr/bin/dtach -- $OPTIONS
	if [ $? != 0 ]; then
    	    log_end_msg 1
    	    exit 1
    	else
    		makepidfiles
    		log_end_msg 0
    	fi

}

stop() {
SIGNAL="INT"
	if [ -f "$RTPIDFILE" ]; then
	log_daemon_msg "Stopping daemon-ized dtach session for" "$NAME"
        start-stop-daemon --stop --signal $SIGNAL --quiet --pidfile "$RTPIDFILE"
        if [ $? = 0 ]; then
                start-stop-daemon --stop --signal $SIGNAL --quiet --pidfile "$DTPIDFILE"
                if [ $? = 0 ]; then
                        rm -f "$DTPIDFILE"
                fi
        log_end_msg 0
        rm -f "$RTPIDFILE"
	else
        	SIGNAL="KILL"
		log_daemon_msg "Couldn't stop $NAME daemon gracefully. Trying to $SIGNAL" "$NAME instead"
		#Trying to find the PIDs again
		makepidfiles
		start-stop-daemon --stop --signal $SIGNAL --quiet --pidfile "$RTPIDFILE"
		if [ $? = 0 ]; then
			start-stop-daemon --stop --signal $SIGNAL --quiet --pidfile "$DTPIDFILE"
		        if [ $? = 0 ]; then
				rm -f "$DTPIDFILE"
		        fi
		        rm -f "$RTPIDFILE"
		        log_daemon_msg "$NAME has been killed. This is not optimal, so please check if there were failures during session startup."
		        log_end_msg 0
			else
			log_daemon_msg "Script could not kill"" $NAME. Please try stopping the dtach session manually"
        		log_end_msg 1
        	fi
        fi
 fi

}

#End Functions
#Script

checkconfig

case "$1" in
  start)
        start
        ;;

  stop)
        stop
        ;;

  restart|force-reload)
        stop
        sleep 1
        start
        ;;

  *)
        echo "Usage: $SCRIPTNAME {start|stop|restart|force-reload}" >&2
        exit 1
        ;;

esac

exit 0


