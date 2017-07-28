#!/bin/bash
set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "`hostname` deleting radosgw remote..."
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 -n|--radosgw-name <radosgw name> -i|--remote-radosgw-ip <remote radosgw ip>\
	[-h|--help]"

        echo "-n, --radosgw-name <radosgw name>"
        echo -e "\teg. client.hostname"

        echo "-i, --remote-radosgw-ip <remote radosgw ip>"
        echo -e "\teg. 192.168.161.101"

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

temp=`getopt -o n:i:h --long radosgw-name:,remote-radosgw-ip:,help -n 'note' -- "$@"`
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
        -h|--help) usage; exit 1;;
        --) shift; break;;#??
        *) usage; exit 1;;
    esac
done

function check_parameter()
{
    #check intf empty
    if [ x"$radosgw_name" = x ] || [ x"$remote_radosgw_ip" = x ]
    then
        usage
        return 1
    fi
}

function delete_radosgw()
{
    remote_mkdir $remote_radosgw_ip
    $SCP $SHELL_DIR/common_fun ${user}@${remote_radosgw_ip}:$remote_tmp_dir
    $SCP $SHELL_DIR/delete_radosgw_local.sh ${user}@${remote_radosgw_ip}:$remote_tmp_dir
    $SSH ${user}@${remote_radosgw_ip} "$remote_tmp_dir/delete_radosgw_local.sh -n '$radosgw_name'" || return 1
}

#start creating
check_exist_ceph_conf
check_parameter
is_all_conf_node_ssh
delete_radosgw || { get_remote_log $user $remote_radosgw_ip || : ;
                    add_log "ERROR" "Fail to delete radosgw(${radosgw_name})..." yes;
                    exit 1; }
add_log "INFO" "Delete radosgw(${radosgw_name}) successfully..."
exit 0
