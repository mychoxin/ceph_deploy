#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "`hostname` creating radosgw remote..." 
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 -n|--radosgw-name <radosgw name> -i|--remote-radosgw-ip <remote radosgw ip>\
	-p|--radosgw-port <radosgw port>\
	[-h|--help]"

        echo "-n, --radosgw-name <radosgw name>"
        echo -e "\teg. client.hostname"

        echo "-i, --remote-radosgw-ip <remote radosgw ip>"
        echo -e "\teg. 192.168.161.101"

        echo "-p, --radosgw-port <radosgw port>"
        echo -e "\teg. 9000"

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

temp=`getopt -o n:i:p:h --long radosgw-name:,remote-radosgw-ip:,radosgw-port:,help -n 'note' -- "$@"`
if [ $? != 0 ]
then
    usage
    exit 1
fi

eval set -- "$temp"
while true
do
    case "$1" in
        -n|--radosgw-name) radosgw_name=$2; shift 2;;
        -i|--remote-radosgw-ip) remote_radosgw_ip=$2; shift 2;;
        -p|--radosgw-port) radosgw_port=$2; shift 2;;
        -h|--help) usage; exit 1;;
        --) shift; break;;#??
        *) usage; exit 1;;
    esac
done

function check_parameter()
{
    if [ x"$radosgw_name" = x ] || [ x"$remote_radosgw_ip" = x ] || [ x"$radosgw_port" = x ]
    then
        add_log "ERROR" "checking if params is empty..." yes
        usage
        return 1
    fi
    check_port "$radosgw_port" || return 1
}

function copy_ceph_conf()
{
    $SSH ${user}@${remote_radosgw_ip} "ls $ceph_conf" > /dev/null 2>&1
    if [ $? -ne 0 ]
    then
        $SCP $ceph_conf ${user}@${remote_radosgw_ip}:$ceph_conf
    fi
}

function add_radosgw()
{
    local_opt="-n '${radosgw_name}' -i ${remote_radosgw_ip} -p ${radosgw_port}";
    remote_mkdir $remote_radosgw_ip
    copy_ceph_conf
    $SCP $SHELL_DIR/common_fun ${user}@${remote_radosgw_ip}:$remote_tmp_dir
    $SCP $SHELL_DIR/create_radosgw_local.sh ${user}@${remote_radosgw_ip}:$remote_tmp_dir
    $SSH ${user}@${remote_radosgw_ip} "$remote_tmp_dir/create_radosgw_local.sh ${local_opt}"
}

#start creating
check_exist_ceph_conf
check_parameter || exit 1
is_all_conf_node_ssh
add_radosgw || { get_remote_log $user $remote_radosgw_ip || : ;
                 add_log "ERROR" "Fail to create radosgw(${radosgw_name})..." yes;
                 exit 1; }
add_log "INFO" "Create radosgw(${radosgw_name}) successfully..."
exit 0
