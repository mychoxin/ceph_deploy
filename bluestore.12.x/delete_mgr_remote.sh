#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "$hostname: remote delete mgr..."
add_log "INFO" "$0 $*"

function usage()
{
	echo "Usage:$0 -t|--target <mgr node ip> [-h|--help]"
	echo "-t, --target <osd node ip>"
	echo -e "\tip to ssh and delete mgr"

	echo "[-h, --help]"
	echo -e "\tget this help info"
}

if ! temp=$(getopt -o t:h --long target:,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp"
	my_exit 1 "Delete mgr failed." "parse arguments failed, $temp"
fi

local_opt=" -un"
eval set -- "$temp"
while true
do
	case "$1" in
		-t|--target) remote_ip=$2; shift 2;;
		-h|--help) usage; exit 1;;
		--) shift; break;;#??
		*) my_exit 1 "Delete mgr failed." "parse arguments failed.";;
	esac
done

RESULT_ERROR="Delete mgr in $remote_ip failed."
RESULT_OK="Delete mgr in $remote_ip successfully."

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

	add_log "INFO" "remote_ip=$remote_ip"

	if ! is_valid_ip $remote_ip
	then
		LAST_ERROR_INFO="target ip is invalid."
		add_log "ERROR" "Invalid ip $remote_ip" $print_log
		return 1
	fi

	if ! check_ssh $remote_ip
	then
		add_log "ERROR" "ssh $remote_ip is not OK" $print_log
		LAST_ERROR_INFO="$LAST_ERROR_INFO"
		return 1
	fi

	wait_for_health_ok

	check_only_one_mgr_node || return 1

	if ! is_all_conf_node_ssh
	then
		if ! wait_for_yes "Not all node in conf file can ssh, continue"
		then
			add_log "INFO" "not all node in conf can ssh, user exited" $print_log
			exit 1
		fi
	fi
}

function delete_mgr()
{
	remote_prepare_files $remote_ip || return 1
	update_conf_from_one_mon || :
	add_log "INFO" "remote deleting mgr..." $print_log
	
	if ! ret_err=$($SSH ${user}@$remote_ip "$remote_tmp_dir/delete_mgr_local.sh $local_opt" 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "Delete mgr in $remote_ip failed, $ret_err" $print_log
		get_remote_log $user $remote_ip || :
		return 1
	fi

	LAST_ERROR_INFO="$ret_err"
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

if delete_mgr
then
	add_log "INFO" "Delete mgr in $remote_ip successfully"
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" "$format"
else
	add_log "ERROR" "Delete mgr in $remote_ip failed"
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" "$format"
fi

