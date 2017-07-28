#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "$hostname: remote creating mgr..."
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 -t|--target <remote node ip> [-a|--add] [-u|--unformat] [-h|--help]"
        echo "-t, --target <remote node ip>"
        echo -e "\tan ip used to create mgr in it and make sure SSH login without passwd, not support ipv6 or lookback interface"

        echo "-a, --add"
        echo -e "\tspecify it's adding mgr not creating mgr"

        echo "-u, --unformat"
        echo -e "\twhen other shell call this shell, print result to parent shell without format"

        echo "[-h, --help]"
        echo -e "\tget this help info"
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
                my_exit 1 "Create mgr failed." "Parse arguments failed. $err_info" 0
        else
                my_exit 1 "Create mgr failed." "Parse arguments failed. $err_info" 1
        fi
}

if ! temp=$(getopt -o t:auh --long target:,add,unformat,help -n 'note' -- "$@" 2>&1)
then
	parse_failed "$temp"
	exit 1
fi

format=1
local_opt=" -u "
eval set -- "$temp"
while true
do
        case "$1" in
                -t|--target) remote_ip=$2; shift 2;;
                -a|--add) local_opt="$local_opt -a "; shift 1;;
                -u|--unformat) format=0; shift 1;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                *) parse_failed;;
        esac
done

RESULT_ERROR="Create mgr in $remote_ip failed."
RESULT_OK="Create mgr in $remote_ip successfully."

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

	add_log "INFO" "remote_ip=$remote_ip" $print_log

	if ! is_valid_ip $remote_ip
	then
		add_log "ERROR" "Invalid ip $remote_ip" $print_log
		LAST_ERROR_INFO="invalid ip $remote_ip."
		return 1
	fi

	if ! check_ssh $remote_ip
	then
		LAST_ERROR_INFO="$LAST_ERROR_INFO"
		add_log "ERROR" "ssh $remote_ip is not OK" $print_log
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

function create_mgr()
{
	update_conf_from_one_mon || :
	remote_prepare_files $remote_ip || return 1

	add_log "INFO" "remote creating mgr..." $print_log
	local local_ret=
	if ! local_ret=$($SSH ${user}@$remote_ip "$remote_tmp_dir/create_mgr_local.sh $local_opt" 2>&1)
	then
		LAST_ERROR_INFO="${local_ret}"
		add_log "ERROR" "Create mgr in $remote_ip failed" $print_log
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
if create_mgr
then
	add_log "INFO" "Create mgr in $remote_ip successfully"
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" "$format"
else
	add_log "ERROR" "Create mgr in $remote_ip failed"
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" "$format"
fi

