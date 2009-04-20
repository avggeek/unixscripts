#!/bin/bash
# script to send simple email
#workaround the fact that the $1 variable is different for rtorrent/hellanzb
no_of_vars=$#
if [ $no_of_vars -eq 3 ] ; then
			status="Torrent Job - ${3}"
			base_filename=$1
			base_path=$2
			time_taken="Not Provided"
	elif [ $no_of_vars -eq 4 ] ; then
			status="Usenet Job - ${1}"
			base_filename=$2
			base_path=$3
			time_taken=$4
	else
		echo "Invalid parameter list. Script supports only 3 or 4 variables"
	fi
fi

#Setup the email contents
SUBJECT=$status
TO_ADDRESS="me@theaveragegeek.com"
BODY="${base_filename} saved in $base_path\nTime Taken - ${time_taken}\n"

#send it out
echo -e $BODY | /bin/mail -s "$SUBJECT" "$TO_ADDRESS"

