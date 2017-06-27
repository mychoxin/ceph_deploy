#!/bin/bash

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "$hostname: clearing ceph cluster..."
add_log "INFO" "$0 $*"

RESULT_ERROR="Delete cluster failed."
RESULT_OK="Delete cluster successfully."

function usage()
{
	echo "Usage:$0 [[ip1] [ip2]...] [-n, --noninteractive] [-f, --force] [-h|--help]"

	echo "[[ip1] [ip2]...]"
	echo -e "\tip of all nodes, if not given than find from ceph.conf, use space seperate"

	echo "[-n, --noninteractive]"
	echo -e "\tforce to destory the cluster without asking the user"

	echo "[-f, --force]"
	echo -e "\tforce to delete all of the searched device partitions even though they are not used by ceph"

	echo "[-h, --help]"
	echo -e "\tget this help info"
}

if ! temp=$(getopt -o nfh --long noninteractive,force,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp"
	my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp" 1
fi

need_ensure_flag=1
force=no
format=1

eval set -- "$temp"
while true
do
	case "$1" in
		-n|--noninteractive) need_ensure_flag=0; shift 1;;
		-f|--force) force=yes; shift 1;;
		-u|--unformat) format=0; shift 1;;
		-h|--help) usage; exit 1;;
		--) shift; break;;#??
		*) my_exit 1 "$RESULT_ERROR." "parse arguments failed." $format;;
	esac
done

arr_conf_node=($@)

function remove_the_same_element()
{
	local new_arr=()
	local k=0
	local len=${#arr_conf_node[@]}
	for((i=0; i<$len; ++i))
	do 
		local ele=${arr_conf_node[$i]}
		local ele_host=$(host_to_ip $ele)
		if ! echo ${new_arr[*]} |grep -w "${ele}" &> /dev/null \
		   && ! echo ${new_arr[*]} |grep -w "${ele_host}" &> /dev/null
		then
			new_arr[$k]=$ele
			((k++))
		fi
	done
	arr_conf_node=(${new_arr[@]})
}

function check_all_ip_ssh()
{
	if [ ${#arr_conf_node[@]} -eq 0 ]
	then
		arr_conf_node=($(awk -F" = " '/\[mon..*\]/{a=1}a==1&&$1=="\tmon host"{print $2; a=0}/\[osd..*\]/{b=1}b==1&&$1=="\thost"{print $2; b=0}' $ceph_conf 2>/dev/null || :))
	fi

	remove_the_same_element

	add_log "INFO" "delete nodes: ${arr_conf_node[*]}" $print_log
	nodes_cannot_ssh=()
	local i=0
	for((j=0; j<${#arr_conf_node[@]}; ++j))
	do
		local node=${arr_conf_node[$j]}
		node=$(host_to_ip $node)
		if ! is_valid_ip $node
		then
			LAST_ERROR_INFO="$node(${arr_conf_node[$j]}) is invalid ip or unknown host. ${SEG}${LAST_ERROR_INFO}"
			add_log "ERROR" "$node(${arr_conf_node[$j]}) is invalid ip or unknown host" $print_log
			nodes_cannot_ssh[$i]=${node}
			((i++))
			unset arr_conf_node[$j]
		fi

		if ! is_current_machine $node
		then
			if ! check_ssh $node &> /dev/null
			then
				nodes_cannot_ssh[$i]=${node}
				LAST_ERROR_INFO="${arr_conf_node[$j]}($node) ssh failed. ${SEG}${LAST_ERROR_INFO}"
				add_log "ERROR" "ssh check node: ${arr_conf_node[$j]}($node) failed" $print_log
				unset arr_conf_node[$j] 
				((i++))
			fi
		fi
		arr_conf_node[$j]=$node
	done
	return $i
}

function parse_and_check_params()
{
	add_log "INFO" "checking params or env..." $print_log
	if [ $need_ensure_flag -eq 1 ]
	then
		if ! wait_for_yes "all of your data in ceph cluster will be destroyed, are you sure to continue"
		then
			exit 1
		fi
	fi

	if ! check_all_ip_ssh
	then
		if [ $need_ensure_flag -ne 1 ]
		then
			my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
		fi

		if ! wait_for_yes "`echo ${nodes_cannot_ssh[*]}` can not ssh, are you sure to continue"
		then
			exit 1
		fi
	fi
}

function remove_osd_monitor()
{
	add_log "INFO" "removing all nodes: ${arr_conf_node[*]}" $print_log
	for node in ${arr_conf_node[@]}
	do
		add_log "INFO" "deleting node: $node..." $print_log
		if ! remote_clear_node $node $force
		then
			my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
		fi
	done
}

parse_and_check_params
remove_osd_monitor

add_log "INFO" "Delete cluster finished" $print_log

my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO"

