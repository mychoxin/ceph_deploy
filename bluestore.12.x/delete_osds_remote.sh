#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "$hostname: remote delete monitor..."
add_log "INFO" "$0 $*"

mon_id=$(hostname)

function usage()
{
	echo "Usage:$0 -t|--target <monitor node ip> [-d|--device <osds device>] [-h|--help]"
        echo "-t, --target <osd node ip>"
        echo -e "\tip used to ssh and delete osd"

        echo "[-d, --device <osd disk>]"
        echo -e "\tosd data disk, not a partition, but the whole disk"
        echo -e "\tand we will delete the osds in the disk"

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

if ! temp=$(getopt -o t:d:h --long target:,device:,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp"
	my_exit 1 "Delete osd failed" "parse arguments failed, $temp"
fi

local_opt=" -un"
eval set -- "$temp"
while true
do
        case "$1" in
                -d|--device) all_data_disks=$2; shift 2;;
		-t|--target) remote_ip=$2; shift 2;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                *) my_exit 1 "Delete osd failed" "parse arguments failed, $temp";;
        esac
done

RESULT_ERROR="Delete osd in $remote_ip failed."
RESULT_OK="Delete osd in $remote_ip successfully."

function parse_and_check_params()
{
	add_log "INFO" "checking params..." $print_log
	#check empty
	if [ x"$remote_ip" = x ]
	then
		LAST_ERROR_INFO="target ip is empty."
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	if [ x"${all_data_disks}" != x ]
	then
		local_opt="$local_opt -d ${all_data_disks}"
	fi

	add_log "INFO" "remote_ip=$remote_ip"

	if ! is_valid_ip $remote_ip
	then
		LAST_ERROR_INFO="target ip is invalid."
		add_log "ERROR" "Invalid ip $remote_ip" $print_log
		return 1
	fi

	if ! check_ssh $remote_ip
	then
		LAST_ERROR_INFO="$LAST_ERROR_INFO"
		add_log "ERROR" "ssh $remote_ip is NOT OK" $print_log
		return 1
	fi

	wait_for_health_ok

	check_only_one_osd_node || return 1

	if ! is_all_conf_node_ssh
	then
		if ! wait_for_yes "Not all node in conf file can ssh, continue"
		then
			add_log "INFO" "not all node in conf can ssh, user exited" $print_log
			exit 1
		fi
	fi
}

function delete_osd()
{
	remote_prepare_files $remote_ip || return 1
	update_conf_from_one_mon || :
	add_log "INFO" "remote deleting osd..." $print_log

	if ! ret_err=$($SSH ${user}@$remote_ip "$remote_tmp_dir/delete_osds_local.sh $local_opt" 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "Delete osd in $remote_ip failed, $ret_err" $print_log
		get_remote_log $user $remote_ip || :
		return 1
	fi

	get_remote_log $user $remote_ip || :

	if ! ret_err=$(replace_local_conf $remote_ip 2>&1)
	then
		LAST_ERROR_INFO="Replace $ceph_conf from $remote_ip failed.$ret_err"
		add_log "ERROR" "Replace $ceph_conf from $remote_ip failed.$ret_err" $print_log
		return 1
	fi

	sync_conf_to_other_node || return 1

	return 0
}

if ! parse_and_check_params
then
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
fi

if delete_osd
then
	add_log "INFO" "Delete osd in $remote_ip successfully" $print_log
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO"
else
	add_log "ERROR" "Delete osd in $remote_ip failed" $print_log
	my_exit 0 "$RESULT_ERROR" "$LAST_ERROR_INFO"
fi

