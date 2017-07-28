#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

clear_log
add_log "INFO" "$hostname: local deleting mgr..."
add_log "INFO" "$0 $*"

mgr_id=$(hostname)

function usage()
{
	echo "Usage:$0 [-n|--noninteractive] [-u|--unformat] [-h|--help]"

	echo "[-n, --noninteractive]"
	echo -e "\tNo ask to ensure to remove mgr"

	echo "-u, --unformat"
	echo -e "\twhen other shell call this shell, print result to parent shell without format"

	echo "[-h, --help]"
	echo -e "\tget this help info"
}

if ! temp=$(getopt -o nuh --long noninteractive,unformat,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp"
	my_exit 1 "" "parse arguments failed, $temp" 1
fi

RESULT_ERROR="Delete mgr $mgr_id failed."
RESULT_OK="Delete mgr $mgr_id successfully."
need_ensure_flag=1
format=1

eval set -- "$temp"
while true
do
	case "$1" in
		-n|--noninteractive) need_ensure_flag=0; shift 1;;
		-u|--unformat) format=0; shift 1;;
		-h|--help) usage; exit 1;;
		--) shift; break;;#??
		*) my_exit 1 "" "parse arguments failed, $temp" $format;;
	esac
done

function parse_and_check_params()
{
	check_only_one_mgr_node || return 1

	if [ $need_ensure_flag -eq 1 ]
	then
		local mgr="mgr.$hostname"
		if ! wait_for_yes "Are you sure to remove $mgr"
		then
			add_log "INFO" "user not sure to remove mgr $mgr" $print_log
			exit 1
		fi
	fi
	return 0
}

function modify_conf()
{
	back_conf || :
	local delete_lines=()
	mgr_data_dir="mgr module path"
	mgr_data_dir_tmp=$(echo $mgr_data_dir |sed 's#\/#\\\/#g')
	if ! delete_lines=($(awk -F " = " '
	/\[mgr\.'"$mgr_id"'\]/{a=1;mgr_line=NR}a==1&&$1~/'"$mgr_data_dir_tmp"'/{print mgr_line" "NR; a=0}
	' $ceph_conf))
	then
		LAST_ERROR_INFO="Find mgr line number failed."
		add_log "ERROR" "Find mgr line number failed" $print_log
		return 1
	fi

	local from=${delete_lines[0]}
	local to=${delete_lines[1]}
	if [ x"$from" = x ] || [ x"$to" = x ]
	then
		LAST_ERROR_INFO="find mgr line number failed."
		add_log "ERROR" "find mgr line number failed" $print_log
		return 1
	fi

	if ! ret_err=$(sed -i "$from,${to}d" $ceph_conf 2>&1)
	then
		LAST_ERROR_INFO="modify $ceph_conf failed."
		add_log "ERROR" "modify $ceph_conf failed. $ret_err" $print_log
		return 1
	fi
}

function remove_mgr()
{
	if ! ret_err=$(kill -9 `ps aux | grep -w [c]eph-mgr -i $mgr_id | awk '{print $2}'` 2>&1)
	then
		LAST_ERROR_INFO="stop mgr failed"
		add_log "ERROR" "stop mgr($mgr_id) failed. $ret_err" $print_log
		#return 1
	fi

	modify_conf || return 1

	mgr_data_dir="$mgr_dir/ceph-$mgr_id"
	rm -fr $mgr_data_dir 2>/dev/null || :
	return 0
}

if ! parse_and_check_params
then
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

if remove_mgr
then
	add_log "INFO" "delete mgr $mgr_id successfully"
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" $format
else
	add_log "ERROR" "delete mgr $mgr_id failed"
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

