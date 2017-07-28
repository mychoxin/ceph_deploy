#!/bin/bash

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

clear_log
add_log "INFO" "$hostname: local deleting osd..."
add_log "INFO" "$0 $*"

function usage()
{
        echo "Usage:$0 [-d|--device <osd disk>] [-n|--noninteractive] [-u|--unformat] [-h|--help]"

        echo "[-d, --device <osd disk>]"
        echo -e "\tosd data disk, not a partition, but the whole disk"
        echo -e "\tand we will delete the osds in the disk"

        echo "[-n, --noninteractive]"
        echo -e "\tNo ask to ensure to remove osd"

        echo "-u, --unformat"
        echo -e "\twhen other shell call this shell, print result to parent shell without format"

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

RESULT_ERROR="Delete osd failed."
RESULT_OK="Delete osd successfully."

if ! temp=$(getopt -o d:nuh --long device:,noninteractive,unformat,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp"
	my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp" 1
fi

need_ensure_flag=1
format=1

eval set -- "$temp"
while true
do
        case "$1" in
                -d|--device) arr_all_data_disks=(${2//,/ }); shift 2;;
		-n|--noninteractive) need_ensure_flag=0; shift 1;;
                -u|--unformat) format=0; shift 1;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                *) my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp" $format;;
        esac
done

function parse_and_check_params()
{
	#check empty
	data_disks_total_count=${#arr_all_data_disks[@]}
	if [ $data_disks_total_count -eq 0 ]
	then
    		if ! arr_all_data_disks=($(get_all_nvme_dev))
		then
			LAST_ERROR_INFO="find nvme device in $hostname failed"
			add_log "ERROR" "$LAST_ERROR_INFO" $print_log
			return 1
		fi
		data_disks_total_count=${#arr_all_data_disks[@]}
	fi

	osd_ids=()
	local k=0
	local ret=0
	for((i=0; i<$data_disks_total_count; ++i))
        do
		local dev=${arr_all_data_disks[$i]}
		#check existance
		if [ ! -e "$dev" ]
		then
			ret=1
			LAST_ERROR_INFO="'$dev' not exists, $LAST_ERROR_INFO"
			add_log "ERROR" "'$dev' not exists" $print_log
			unset arr_all_data_disks[$i] 
		fi

		#may be it's a symbol link
		if [ ! -b "$dev" -a ! -L "$dev" ]
		then
			ret=1
			LAST_ERROR_INFO="'$dev' is not block device, $LAST_ERROR_INFO"
			add_log "WARNING" "'$dev' is not block device" $print_log
			unset arr_all_data_disks[$i]
			continue
		fi

		if ! is_device_used $dev
		then
			ret=1
			LAST_ERROR_INFO="'$dev' is not used by any osd, $LAST_ERROR_INFO"
			add_log "WARNING" "no found part label of $dev in $ceph_conf, this means $dev is not in use by any osd" $print_log
			unset arr_all_data_disks[$i]
			continue
		fi

		local block_part=(`parted $dev -s print |awk '/'"${osd_data_base}"'-.*-block/{print $0}'|awk '{print "/dev/disk/by-partlabel/"$NF}'`)

		add_log "INFO" "$dev wal-part=${block_part[*]}"

		for((j=0; j<${#block_part[@]}; ++j))
		do
			local osd=$(awk -F" = " -v dir="${block_part[$j]}" '/\[osd..*\]/{a=1;osd_line=NR;find=$0}a==1&&$2==dir{print find":"osd_line":"NR}' $ceph_conf)
			osd_ids[$k]="$osd"
			((k++))
		done
	done
	
	add_log "INFO" "osd-ids=${osd_ids[*]}"
	if [ $need_ensure_flag -eq 1 ]
	then
		local osd_delete=$(echo ${osd_ids[@]} | awk '{for(i=1; i<NF+1; ++i)print $i}' | cut -d [ -f 2| cut -d ] -f 1| awk '{for(i=1; i<NF+1; ++i)printf $i" "}')
		if ! wait_for_yes "Are you sure to remove $osd_delete"
		then
			add_log "INFO" "user not sure to remove osds $osd_delete"
			exit 1
		fi
		add_log "INFO" "user sure to remove osds $osd_delete" $print_log
	fi

	check_only_one_osd_node || return 1
	return $ret
}

function remove_osds()
{
	for id in ${osd_ids[@]}
	do
		local osd=(${id//:/ })
		section=${osd[0]}
		[ x"$section" != x ] && [ x"$print_log" = x"yes" ] && echo "$section: removing..."
		num=${section##*.}
		num=${num%%\]*}
		if [ x"$num" = x ]
		then
			continue
		fi
		add_log "INFO" "remove_one_osd id=$num wait=$remove_wait"
		remove_one_osd $num $remove_wait

                local osd_data="${osd_data_dir}/${osd_data_base}-${num}"
		if [ -d "$osd_data" ]
		then
			add_log "INFO" "deleting ${osd_data}..."
			rm -fr $osd_data
		fi
	done
}

function clear_disks()
{
	for dev in ${arr_all_data_disks[@]}
        do
		add_log "INFO" "clear_disk: del_all_partition $dev"
		if is_device_used $dev
		then
			if ! ret_err=$(del_all_partition $dev 2>&1)
			then
				LAST_ERROR_INFO="$ret_err\n$LAST_ERROR_INFO"
			fi

			add_log "INFO" "clearing dev head info of $dev" $print_log
			if ! ret=$(dev_head clear $dev 2>&1)
			then
				add_log "INFO" "clear head info of $dev failed, $ret"
			fi
		fi
	done
}

function modify_conf()
{
	back_conf || :
	#del from back to front, this can make sure the line num validate
	for ((i=${#osd_ids[@]}; i>0; --i))
	do
		local j=$((i-1))
		local del=(${osd_ids[$j]//:/ })
		local from=${del[1]}
		local to=${del[2]}
		if [ x"$from" = x ] || [ x"$to" = x ]
		then
			continue
		fi
		add_log "INFO" "sed -i \"$from,${to}d\" $ceph_conf"
		if ret_err=$(sed -i "$from,${to}d" $ceph_conf 2>&1)
		then
			LAST_ERROR_INFO="$ret_err\n$LAST_ERROR_INFO"
		fi
	done
}

function check_health()
{
	local pg_status
	if ! pg_status=$(is_active_clean)
	then
		add_log "WARNING" "pg status: $pg_status" $print_log
		return 1
	else
		add_log "INFO" "pg status: $pg_status" no
		return 0
	fi
}

if ! parse_and_check_params
then
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" 0
fi

check_health || :

#start deleting
remove_osds

clear_disks
modify_conf

my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" $format

