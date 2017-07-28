#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

mkdir "$mgr_dir" -p

clear_log
add_log "INFO" "$hostname: local creating mgr..."
add_log "INFO" "$0 $*"

add_flag=0
CEPH_PORT=6789
host=$(hostname)
mgr_id=$host

function usage()
{
	echo "Usage:$0 [-a|--add] [-u|--unformat] [-h|--help]"

	echo "-a, --add"
	echo -e "\tspecify it's adding mgr not creating mgr"

	echo "-u, --unformat"
	echo -e "\twhen other shell call this shell, print result to parent shell without format"

	echo "[-h, --help]"
	echo -e "\tget this help info"
}

RESULT_ERROR="Create mgr on $hostname failed."
RESULT_OK="Create mgr on $hostname successfully."

if ! temp=$(getopt -o auh --long add,unformat,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp" $print_log
	my_exit 1 "$RESULT_ERROR" "Parse arguments failed. $temp" 1
fi

#[ ! -d "$conf_dir" ] && mkdir $conf_dir -p

format=1
eval set -- "$temp"
while true
do
	case "$1" in
		-a|--add) add_flag=1; shift 1;;
		-u|--unformat) format=0; shift 1;;
		-h|--help) usage; exit 1;;
		--) shift; break;;#??
		*) my_exit 1 "$RESULT_ERROR" "Parse arguments failed." 1;;
	esac
done

function check_and_parse_params()
{
	pidof ceph-mgr &> /dev/null && my_exit 1 "$RESULT_ERROR" "existed one mgr on $hostname" $format
	return 0
}

function get_pubnet()
{
	local pubnet=
	if ! pubnet=$(grep "public network = " $ceph_conf | awk -F" = " '{print $2}')
	then
		LAST_ERROR_INFO="get 'public network' from $ceph_conf failed."
		add_log "ERROR" "get 'public network' from $ceph_conf failed" $print_log
		return 1
	fi
	
	local pubnet_tmp=$(echo $pubnet|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"\."$2"\."$3"\..*""/"$5"$"}')
	local public_ip=
	if ! public_ip=$(ip addr ls |awk '{print $2}' |grep "$pubnet_tmp"| awk -F'/' '{print $1}' | head -n 1)
	then
		LAST_ERROR_INFO="get ip in ${pubnet} failed."
		add_log "ERROR" "get ip in ${pubnet} failed" $print_log
		return 1
	fi
	echo $public_ip
	return 0
}

function set_conf()
{
	create_roll_back_conf || :
	back_conf || :

	if ! mgr_addr=$(get_pubnet)
	then
		return 1
	fi

	local pos="\[osd\]"
	local mgr_line=
	if ! mgr_line=$(grep "$pos" $ceph_conf)
	then
		LAST_ERROR_INFO="no find $pos in $ceph_conf."
		add_log "ERROR" "no find $pos in $ceph_conf" $print_log
		return 1
	fi

	local line_sec="\[mgr.$mgr_id\]"
	sed -i "/$pos/i$line_sec" $ceph_conf 

	local line_mgr_host="\\\\thost = $host"
	sed -i "/$pos/i$line_mgr_host" $ceph_conf 

	#local line_mgr_data="\\\\tmgr data = $mgr_dir/ceph-$mgr_id"
	#sed -i "/$pos/i$line_mgr_data" $ceph_conf

	local mgr_module_path="\\\\tmgr module path = /usr/local/lib/x86_64-linux-gnu/ceph/mgr"
	if which ceph | grep "build/bin/ceph"
	then
		local ceph_path=$(which ceph);
		mgr_module_path="\\\\tmgr module path = `(cd ${ceph_path%/*}/../../src/pybind/mgr && pwd) 2>&1 || :`"
	fi
	add_log "INFO" "which ceph=`which ceph || :`" no
	add_log "INFO" "$mgr_module_path" no
	sed -i "/$pos/i$mgr_module_path" $ceph_conf
}

function create_mgr()
{
	local ret_err=
	mkdir -p $mgr_dir/ceph-$mgr_id
	if ! ret_err=$(ceph auth get-or-create mgr.$mgr_id mon 'allow profile mgr' osd 'allow *' mds 'allow *' 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	MGR_IP=$(get_pubnet)
	MGR_PORT=$(($CEPH_PORT + 1000))
	if ret_err=$(ceph_adm config-key put mgr/dashboard/$mgr_id/server_addr $MGR_IP 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	if ret_err=$(ceph_adm config-key put mgr/dashboard/$mgr_id/server_port $MGR_PORT 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	MGR_PORT=$(($MGR_PORT + 1000))
	if ret_err=$(ceph_adm config-key put mgr/restful/$name/server_addr $MGR_IP 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	if ret_err=$(ceph_adm config-key put mgr/restful/$name/server_port $MGR_PORT 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	touch $mgr_dir/ceph-$mgr_id/done $mgr_dir/ceph-$mgr_id/upstart > /dev/null 2 > $local_log_file || return 1

	if ! ret_err=$(ceph-mgr -i $mgr_id 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi
	return 0
}

function add_mgr()
{
	if ! create_mgr
	then
		return 1
	fi
	return 0
}

check_and_parse_params

set_conf || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format

if [ $add_flag -eq 1 ]
then
	if ! add_mgr > /dev/null
	then
		rollback_conf
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi
else
	if ! create_mgr > /dev/null
	then
		rollback_conf
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi
fi

#create_logrotate_file
my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" $format

