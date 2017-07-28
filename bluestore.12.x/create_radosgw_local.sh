#!/bin/bash
set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun
bak_radosgw_conf=$conf_dir/._bak_radosgw_conf
print_log="no"

add_log
add_log "INFO" "`hostname` creating radosgw..."
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 -n|--radosgw-name <radosgw name> -i|--radosgw-ip <radosgw ip>\
       [-p|--radosgw-port <radosgw port>]\
       [-c|--pg-num <radosgw pool pg_num>]\
       [-s|--pool-size <radosgw pool size>]\
       [-t|--rgw-thread-pool-size <rgw thread pool size>]\
       [-h|--help]"

        echo "-n, --radosgw-name <radosgw name>"
        echo -e "\teg. client.hostname"

        echo "-i, --radosgw-ip <radosgw ip>"
        echo -e "\teg. 192.168.161.100"

        echo "-p, --radosgw-port <radosgw port>"
        echo -e "\teg. 9000"

        echo "-s, --pool-size <radosgw pool size>"
        echo -e "\tdefault is '2'"

        echo "-t, --radosgw-thread-pool-size <rgw thread pool size>"
        echo -e "\tdefault is '100', between 100 and 2000."

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

RESULT_ERROR="Create radosgw failed."
RESULT_OK="Create radosgw successfully."
temp=`getopt -o n:i:p:s:t:h --long radosgw-name:,radosgw-ip:,radosgw-port:,pool-size:,rgw-thread-pool-size:,help -n 'note' -- "$@"`
if [ $? != 0 ]
then
    #usage
    my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp"
fi

eval set -- "$temp"
while true
do
    case "$1" in
        -n|--radosgw-name) radosgw_name=$2; shift 2;;
        -i|--radosgw-ip) radosgw_ip=$2; shift 2;;
        -p|--radosgw-port) radosgw_port=$2; shift 2;;
        -s|--pool-size) pool_size=$2; shift 2;;
        -t|--rgw-thread-pool-size) rgw_thread_pool_size=$2; shift 2;;
        -h|--help) usage; exit 1;;
        --) shift; break;;#??
        *) usage; exit 1;;
    esac
done

function check_parameter()
{
    LAST_ERROR_INFO=""
    if [ x"${radosgw_name:0:7}" != x"client." ];then
        add_log "ERROR" "error -n|--radosgw-name must be start with 'client.' ..." $print_log
        LAST_ERROR_INFO="error -n|--radosgw-name must be start with 'client.'"
        return 1
    elif [ x"$radosgw_ip" = x ] || [ x"$radosgw_port" = x ]; then
        add_log "ERROR" "-i|--radosgw-ip or -p|--radosgw-port is empty..." $print_log
        LAST_ERROR_INFO="error, -i|--radosgw-ip or -p|--radosgw-port is empty..."
        return 1
    fi
    check_port "$radosgw_port" || { LAST_ERROR_INFO="error -p|--radosgw-port, $radosgw_port not in (1, 65535)"; return 1; }

    rgw_thread_pool_size=${rgw_thread_pool_size:-"100"}
    if [ "$rgw_thread_pool_size" -gt 2000 -o "$rgw_thread_pool_size" -lt 100 ]; then
        add_log "ERROR" "error -t|--rgw-thread-pool-size, $rgw_thread_pool_size is not between 100 and 2000." $print_log
        LAST_ERROR_INFO="error -t|--rgw-thread-pool-size, $rgw_thread_pool_size is not between 100 and 2000."
        return 1
    fi
}

function set_conf()
{
    #check if radosgw_name exist in ceph.conf
    if grep -Fx "[${radosgw_name}]" $ceph_conf > /dev/null 2>&1
    then
        add_log "ERROR" "[${radosgw_name}] already exist in $ceph_conf..." $print_log
        LAST_ERROR_INFO="[${radosgw_name}] already exist in $ceph_conf"
        return 1
    fi

    lsof -i:${radosgw_port} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        add_log "ERROR" "port(${radosgw_port}) already in use..." $print_log
        LAST_ERROR_INFO="port(${radosgw_port}) already in use"
        return 1
    fi

    add_log "INFO" "[$radosgw_name]"
    add_log "INFO" "rgw_frontends = civetweb port= ${radosgw_port}"
    add_log "INFO" "log file = ${ceph_log_dir}/${radosgw_name}.log"
    add_log "INFO" "host = ${radosgw_ip}"
    cat>>${ceph_conf}<<-EOF
	[${radosgw_name}]
	rgw enable usage log = true
	rgw usage log tick interval = 1
	rgw enable static website = true
	rgw_frontends = "civetweb port=${radosgw_port}"
	rgw thread pool size = $rgw_thread_pool_size
	log file = ${ceph_log_dir}/${radosgw_name}.log
	host = ${radosgw_ip}
	EOF
}

function back_conf()
{
    cp $ceph_conf $bak_radosgw_conf > /dev/null 2>&1
}

function del_tmp_conf()
{
    rm -f $bak_radosgw_conf > /dev/null 2>&1
}

function rollback_conf()
{
    cp $bak_radosgw_conf $ceph_conf > /dev/null 2>&1
    del_tmp_conf 
}

function add_radosgw()
{
    rgw_data="/var/lib/ceph/radosgw/ceph-$radosgw_name"
    if [ -d $rgw_data ]; then
        rm -rf $rgw_data > /dev/null 2>&1 || return 1
    fi
    mkdir $rgw_data -p && touch $rgw_data/done $rgw_data/upstart > /dev/null 2>&1 || return 1
    if ! ret_err=$(start radosgw id=$radosgw_name 2>&1)
    then
        add_log "ERROR" "$ret_err" $print_log
        return 1
    fi

    count=15
    while [ $count -gt 0 ] 
    do
        sleep 1
        lsof -i:${radosgw_port} > /dev/null 2>&1
        if [ $? -eq 0 ]
        then
	    return 0
        fi
	((count--))
    done
    rm -rf $rgw_data > /dev/null 2>&1 || :
    return 1   
}

function delete_radosgw()
{
    if ! ret_err=$(stop radosgw id="$radosgw_name" 2>&1)
    then
        add_log "ERROR" "$ret_err" $print_log
        return 1
    fi
}

#start creating
check_exist_ceph_conf || my_exit 1 "$RESULT_ERROR" "$ceph_conf not exist"
check_parameter || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
is_all_conf_node_ssh
back_conf || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
set_conf || { del_tmp_conf; my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"; }

[ x"$pool_size" == x"" ] && pool_size=($(grep -E "osd pool default size =" $ceph_conf | grep -v "#" | awk -F " = " '{print $2}'))
rgw_create_pool ${pool_size:-2} "default" || { rollback_conf; my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"; }

if ! add_radosgw
then
    add_log "ERROR" "Fail to start radosgw(${radosgw_name}) ..." $print_log
    delete_radosgw || :
    rollback_conf || :
    my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
fi

del_tmp_conf || :
add_log "INFO" "$RESULT_OK" $print_log
my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO"

