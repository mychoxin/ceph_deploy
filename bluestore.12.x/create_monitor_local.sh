#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

mkdir "$mon_dir" -p

clear_log
add_log "INFO" "$hostname: local creating monitor..."
add_log "INFO" "$0 $*"

add_mon_flag=0

function usage()
{
        echo "Usage:$0 [-a|--add] [-u|--unformat] [-h|--help]"

        echo "-a, --add"
        echo -e "\tspecify it's adding monitor not creating monitor"

        echo "-u, --unformat"
        echo -e "\twhen other shell call this shell, print result to parent shell without format"

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

RESULT_ERROR="Create monitor on $hostname failed."
RESULT_OK="Create monitor on $hostname successfully."

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
                -a|--add) add_mon_flag=1; shift 1;;
                -u|--unformat) format=0; shift 1;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                *) my_exit 1 "$RESULT_ERROR" "Parse arguments failed." 1;;
        esac
done

function check_and_parse_params()
{
	pidof ceph-mon &> /dev/null && my_exit 1 "$RESULT_ERROR" "existed one monitor on $hostname" $format
	return 0
}

function set_conf()
{
	create_roll_back_conf || :
	back_conf || :
	host=$(hostname)
	mon_id=$host

	if ! mon_addr=$(get_pubnet)
	then
		return 1
	fi

	local pos="\[mgr\]"
	local mon_line=
	if ! mon_line=$(grep "$pos" $ceph_conf)
	then
		LAST_ERROR_INFO="no find $pos in $ceph_conf."
		add_log "ERROR" "no find $pos in $ceph_conf" $print_log
		return 1
	fi

	local line_sec_mon="\[mon.$mon_id\]"
	sed -i "/$pos/i$line_sec_mon" $ceph_conf 
	
	local line_mon_host="\\\\tmon host = $host"
	sed -i "/$pos/i$line_mon_host" $ceph_conf 

	local line_mon_addr="\\\\tmon addr = $mon_addr"
	sed -i "/$pos/i$line_mon_addr" $ceph_conf 

	local line_mon_data="\\\\tmon data = $mon_dir/ceph-$mon_id"
	sed -i "/$pos/i$line_mon_data" $ceph_conf 
}

function create_monitor()
{
	if pidof ceph-mon >/dev/null 2>&1
	then
		LAST_ERROR_INFO="ceph-mon was running."
		add_log "ERROR" "ceph-mon was running" $print_log
		return 1
	fi

	if ! fsid=$(get_fsid)
	then
		return 1
	fi

	local ret_err=
	if ! ret_err=$(ceph-authtool --create-keyring /tmp/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *' 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	if ! ret_err=$(ceph-authtool --create-keyring $conf_dir/ceph.client.admin.keyring --gen-key -n client.admin --set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow' 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	if ! ret_err=$(ceph-authtool /tmp/ceph.mon.keyring --import-keyring $conf_dir/ceph.client.admin.keyring 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi 

	if ! ret_err=$(monmaptool --create --add $mon_id $mon_addr --fsid $fsid /tmp/monmap 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	mkdir -p $mon_dir/ceph-$mon_id

	if ! ret_err=$(ceph-mon --mkfs -i $mon_id --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi

	touch $mon_dir/ceph-$mon_id/done $mon_dir/ceph-$mon_id/upstart > /dev/null 2>&1 || return 1

	if ! ret_err=$(ceph-mon -i $mon_id 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi
	return 0
}

function add_monitor()
{
	local ret_err=
	add_log "INFO" "will ceph auth get mon."
	ceph auth get mon. -o /tmp/ceph.mon.keyring &> /dev/null || :
	add_log "INFO" "after ceph auth get mon."

	add_log "INFO" "will ceph mon getmap"
	if ! ret_err=$(ceph mon getmap -o /tmp/monmap 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi
	add_log "INFO" "ok ceph mon getmap"

	mkdir -p $mon_dir/ceph-$mon_id

	add_log "INFO" "will ceph-mon --mkfs"
	if ! ret_err=$(ceph-mon -i $mon_id --mkfs --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi
	add_log "INFO" "ok ceph-mon --mkfs"

	add_log "INFO" "will start ceph-mon daemon"
	touch $mon_dir/ceph-$mon_id/done $mon_dir/ceph-$mon_id/upstart > /dev/null 2>&1 || return 1
	if ! ret_err=$(start ceph-mon id=$mon_id 2>&1)
	then
		LAST_ERROR_INFO="$ret_err"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		return 1
	fi
	add_log "INFO" "ok start ceph-mon daemon"

	return 0
}

check_and_parse_params

set_conf || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format

if [ $add_mon_flag -eq 1 ]
then
	if ! add_monitor > /dev/null
	then
		rollback_conf
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi
else
	if ! create_monitor > /dev/null
	then
		rollback_conf
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi
fi

create_logrotate_file
my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" $format

