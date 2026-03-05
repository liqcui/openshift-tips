#!/bin/bash
if [[ -f /proc/$1/maps ]];then
  echo "dump memory for $1"
  pmap -x -p $1 >pmap-$1.txt
  grep rw-p /proc/$1/maps \
  | sed -n 's/^\([0-9a-f]*\)-\([0-9a-f]*\) .*$/\1 \2/p' \
  | while read start stop; do \
    gdb --batch --pid $1 -ex \
        "dump memory $1-$start-$stop.dump 0x$start 0x$stop"; \
  done
  #gcore -o /host/var/tmp/ovnkube-master $pid
else
  echo please specify correct process id PID
  exit 1
fi
