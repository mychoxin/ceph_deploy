#!/bin/bash

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

devs=(/dev/sdc /dev/sdd)
for i in ${devs[@]}
do
	parted -s -a optimal $i mklabel gpt
done

from=0
to=0

for ((i=0; i<10; ++i))
do
set -x
	new_part="ceph-${i}-wal"
set +x
	from=$((10+i*10))
	to=$((from+10))
        j=$((i/5))
	dev=${devs[$j]}
	get_new_partition "$dev" $new_part ${from}G ${to}G
done

