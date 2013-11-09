#!/bin/sh


while getopts "rwph" flag
do
    case $flag in
        r) opt_r=true;;
        w) opt_w=true;;
        p) opt_p=true;;
        h|*) opt_h=true;;
    esac
done

if [ $opt_h ]
then
    echo "-h help"
    echo "-r restart plack servers"
    echo "-w restart workerss"
    echo "-p restart proxy"
    exit;
fi

_logdir=/home/isucon/deploy/log/;
_logfile=$_logdir`date +%Y-%m-%d.%H%M%S`
if [ ! -d $_logdir ]; then
    mkdir -p $_logdir
fi

RSYNC_DIR=/home/isucon/webapp/
RSYNC_HOSTS="isucon2 isucon3 isucon4 isucon5"

set -e

function die () {
    echo "$@";
    exit 1;
}

function rsync_apps {
    echo "---- sync files"
    echo $RSYNC_HOSTS

    for host in $RSYNC_HOSTS
    do
	rsync -v -a -e ssh $RSYNC_DIR $host:$RSYNC_DIR
    done
}

function restart_apps {
    echo nothing
}

function restart_worker {
    echo nothing
}

function restart_proxy {
    echo nothing
}

(   
    exec 2>&1
    rsync_apps
    [ $opt_r ] && restart_apps
    [ $opt_w ] && restart_worker 
    [ $opt_p ] && restart_proxy 
) | /usr/local/bin/tai64n | tee -a $_logfile | /usr/local/bin/tai64nlocal
