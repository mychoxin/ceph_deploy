#!/bin/bash
set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun
bak_radosgw_conf=$conf_dir/._bak_radosgw_conf

RESULT_ERROR="Delete radosgw failed."
RESULT_OK="Delete radosgw successfully."
print_log="no"

add_log
add_log "INFO" "`hostname` deleting radosgw..."
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 -n|--radosgw-name <radosgw name> [-h|--help]"
        echo "[-h, --help]"
        echo -e "\tget this help info"
}

temp=`getopt -o n:h --long radosgw-name:,help -n 'note' -- "$@"`
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
        -h|--help) usage; exit 1;;
        --) shift; break;;#??
        *) usage; exit 1;;
    esac
done

function check_parameter()
{
    LAST_ERROR_INFO=""
    if [ x"$radosgw_name" = x ]
    then
        add_log "ERROR" "error -n|--radosgw-name, radosgw name is empty..." $print_log
        LAST_ERROR_INFO="error -n|--radosgw-name, radosgw name is empty"
        return 1
    fi
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

function delete_radosgw()
{
    if ! ret_err=$(stop radosgw id="$radosgw_name" 2>&1)
    then
        add_log "ERROR" "$ret_err" $print_log
        LAST_ERROR_INFO="$ret_err"
        return 1
    fi
}

function del_radosgw_conf()
{
    rgw_data="/var/lib/ceph/radosgw/ceph-$radosgw_name"
    if [ -d $rgw_data ]; then
        rm -rf $rgw_data > /dev/null 2>&1 || { add_log "ERROR" "Fail to delete $rgw_data..." $print_log; return 1; }
    fi

    #check if radosgw_name exist in ceph.conf
    if grep -Fx "[$1]" $ceph_conf > /dev/null 2>&1
    then
        line_str=`grep -Fxn "[$1]" $ceph_conf`
        line_num=(${line_str//:/ })
        sed -i "$line_num,+7d" $ceph_conf > /dev/null 2>&1
    else
        add_log "WARNING" "[$1] not exist in $ceph_conf..." $print_log
        LAST_ERROR_INFO="[$1] not exist in $ceph_conf"
        return 1
    fi
    rm "${ceph_log_dir}/${radosgw_name}.log" "/var/run/ceph/ceph-${radosgw_name}.asok" > /dev/null 2>&1 || :
}

#start creating
check_exist_ceph_conf || my_exit 1 "$RESULT_ERROR" "$ceph_conf not exist"
check_parameter || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
is_all_conf_node_ssh
back_conf || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
del_radosgw_conf "${radosgw_name}" || { del_tmp_conf; my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"; }
delete_radosgw || { add_log "ERROR" "Fail to delete radosgw(${radosgw_name})..." $print_log; rollback_conf; my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"; }
del_tmp_conf || :
add_log "INFO" "$RESULT_OK" $print_log
my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO"
