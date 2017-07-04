#!/bin/bash

function usage()
{
	echo "Usage:$0 [[ip1] [ip2]...] [-h|--help]"

	echo "[[ip1] [ip2]...]"
	echo -e "\tIPs of all nodes, use space seperate, if not given then restart osd daemon on current machine."

	echo "[-h, --help]"
	echo -e "\tget this help info"
}

if ! temp=$(getopt -o h --long help -n 'note' -- "$@" 2>&1)
then
	echo "parse arguments failed, $temp"
	usage
	exit 1
fi

eval set -- "$temp"
while true
do
	case "$1" in
		-h|--help) usage; exit 1;;
		--) shift; break;;#??
		*) echo "$1 unknown parameter"; exit 1;;
	esac
done

arr_all_nodes=($@)

re_start="
python=\"
import json
s = json.loads('\$(echo \$(sudo ceph node ls osd))')
for osd in s[\\\"\$(hostname)\\\"]:
    print osd
\"
osds=\$(echo \"\$python\" | python)
for osd in \$osds
do
	echo stopping osd.\$osd
	sudo kill \$(ps aux | grep -w \"[c]eph-osd -i \$osd\" | awk '{print \$2}') &> /dev/null
	while [ x\"\`ps aux | grep -w \\\"[c]eph-osd -i \$osd\\\"\`\" != x ]
	do
		#echo stopping osd.\$osd
		sleep 1
	done
	sudo ceph-osd -i \$osd
done
"

len=${#arr_all_nodes[@]}
if [ x"$len" = x0 ]
then
	echo "re-starting osd on `hostname`..."
	eval "$re_start"
	exit $?
fi

for node in ${arr_all_nodes[@]}
do 
	echo "re-starting osd on $node..."
	ssh $node "$re_start"
done

exit 0

