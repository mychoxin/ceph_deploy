#!/bin/bash

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun
set -e

add_log
add_log "INFO" "$hostname: remote adding osd..."
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 [-n|--osd-num <osd num of each data disk>] -t|--target <osd node ip> [-u|--unformat] [-h|--help]"
        echo "-n, --num<osd num of each data disk>"
        echo -e "\tevery data disk will be parted to num*3 partitions(wal,db,block)"

        echo "-t, --target <osd node ip>"
        echo -e "\tip to ssh and create osd"

        echo "-u, --unformat"
        echo -e "\twhen other shell call this shell, print result without format"

        echo "[-h, --help]"
        echo -e "\thelp info"
}

cmd_tmp="$*"
#1st param: error info
function parse_failed()
{
	local err_info="$1"
	add_log "ERROR" "parse arguments failed. $err_info"
	if echo "$cmd_tmp" | grep -w "\-u" &> /dev/null\
	   || echo "$cmd_tmp" | grep " \-\-unformat" &> /dev/null
	then
		my_exit 1 "Create osd failed." "Parse arguments failed. $err_info" 0
	else
		my_exit 1 "Create osd failed." "Parse arguments failed. $err_info" 1
	fi
}

if ! temp=$(getopt -o n:t:uh --long osd-num:,target:,unformat,help -n 'note' -- "$@" 2>&1)
then
	parse_failed "$temp"
        exit 1
fi

local_opt="-fu"
format=1
eval set -- "$temp"
while true
do
        case "$1" in
                -n|--osd-num) osd_num_in_each_disk=$2; shift 2;;
                -t|--target) remote_ip=$2; shift 2;;
                -u|--unformat) format=0; shift 1;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                *) parse_failed;;
        esac
done

RESULT_ERROR="Create osd in $remote_ip failed."
RESULT_OK="Create osd in $remote_ip successfully."

#the partitions used directly by osd.N
arr_all_osd_id=()

function parse_and_check_params()
{
	add_log "INFO" "checking params..." $print_log
	#check empty
	if [ x"$remote_ip" = x ]
	then
		add_log "ERROR" "target ip is empty" $print_log
		LAST_ERROR_INFO="target ip is empty."
		return 1
	fi

	add_log "INFO" "osd_num_in_each_disk=$osd_num_in_each_disk" $print_log
	check_osd_num_in_each_disk "$osd_num_in_each_disk" || return 1
	local_opt="-n $osd_num_in_each_disk $local_opt"

	add_log "INFO" "remote_ip=$remote_ip" $print_log

	if ! is_valid_ip $remote_ip
	then
		LAST_ERROR_INFO="invalid ip $remote_ip."
		add_log "ERROR" "Invalid ip $remote_ip" $print_log
		return 1
	fi

	if ! check_ssh $remote_ip
	then
		add_log "ERROR" "ssh $remote_ip is NOT OK."
		return 1
	fi

	#wait_for_health_ok

	#is_all_conf_node_ssh || return 1
	if ! is_all_conf_node_ssh
	then
		if ! wait_for_yes "Not all node in conf file can ssh, continue"
		then
			add_log "INFO" "not all node in conf can ssh, user exited" $print_log
			exit 1
		fi
	fi
}

function create_osd()
{
	remote_prepare_files $remote_ip || return 1
	update_conf_from_one_mon || :

	add_log "INFO" "remote creating osd..." $print_log
	local local_ret=
	if ! local_ret=$($SSH ${user}@$remote_ip "$remote_tmp_dir/create_osds_local.sh $local_opt" 2>&1)
	then
		LAST_ERROR_INFO="${local_ret}"
		add_log "ERROR" "Create osd in $remote_ip failed" $print_log
		get_remote_log $user $remote_ip || :
		return 1
	fi

	get_remote_log $user $remote_ip || :

	if ! local_ret=$(replace_local_conf $remote_ip 2>&1)
	then
		LAST_ERROR_INFO="Replace $ceph_conf from $remote_ip failed.$local_ret"
		add_log "ERROR" "Replace $ceph_conf from $remote_ip failed.$local_ret" $print_log
		return 1
	fi

	sync_conf_to_other_node || return 1
	return 0
}

if ! parse_and_check_params
then
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" "$format"
fi

set_hosts "$remote_ip"

#start creating
if create_osd
then
	add_log "INFO" "Create osd in $remote_ip successfully"
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" "$format"
else
	add_log "ERROR" "Create osd in $remote_ip failed"
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" "$format"
fi

