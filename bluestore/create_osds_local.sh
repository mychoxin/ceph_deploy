#!/bin/bash

head_reverse_size=10
tail_reverse_size=$((10*1024))
wal_part_size=$((10*1024))
db_part_size=$((10*1024))
block_part_min_size=$((4*1024))

#using in VM
#head_reverse_size=10
#tail_reverse_size=$((0*1024))
#wal_part_size=$((1*512))
#db_part_size=$((1*512))
#block_part_min_size=$((2*1024))

one_osd_min_size=$((wal_part_size+db_part_size+block_part_min_size))

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

set -e

clear_log
add_log "INFO" "$hostname: local adding osd..."
add_log "INFO" "$0 $*"

function usage()
{
	echo "Usage:$0 [-n|--num <osd num of each data disk>] [-f|--force] [-h|--help]"
	echo "-n, --osd-num<osd num of each data disk>"
	echo -e "\tevery data disk will be parted to num*3 partitions(wal,db,block)"
	echo "-f, --force"
	echo -e "ignore existed partitions in device"
	
	echo "-u, --unformat"
	echo -e "\twhen other shell call this shell, print result to parent shell without format"
	
	echo "[-h, --help]"
	echo -e "\thelp info"
}

RESULT_ERROR="Create osd on $hostname failed."
RESULT_OK="Create osd on $hostname successfully."

if ! temp=$(getopt -o n:fuh --long osd-num:,force,unformat,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp" $print_log
	my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp" $format
fi

host=$(hostname)
mon_id=$host
force=0
format=1

eval set -- "$temp"
while true
do
	case "$1" in
		-n|--osd-num) osd_num_in_each_disk=$2; shift 2;;
		-f|--force) force=1; shift 1;;
		-u|--unformat) format=0; shift 1;;
		-h|--help) usage; exit 1;;
		--) shift; break;;#??
		*) my_exit 1 "$RESULT_ERROR" "parse arguments failed" $format;;
	esac
done

arr_all_osd_id=()

function parse_and_check_params()
{
	add_log "INFO" "osd_num_in_each_disk=$osd_num_in_each_disk" $print_log
	if ! check_osd_num_in_each_disk "$osd_num_in_each_disk"
	then
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi

    	if ! arr_all_data_disks=($(get_all_nvme_dev))
	then
		add_log "ERROR" "failed to find nvme device in $hostname" $print_log
		my_exit 1 "$RESULT_ERROR" "failed to find nvme device" $format
	fi
	data_disks_total_count=${#arr_all_data_disks[@]}
	osd_total_count=$(echo $data_disks_total_count*$osd_num_in_each_disk | bc)

	add_log "INFO" "all-data-disks=${arr_all_data_disks[*]}"
	add_log "INFO" "all-data-disks-count=${data_disks_total_count}"
	add_log "INFO" "OSD-count-per-disk=${osd_num_in_each_disk}"
	add_log "INFO" "OSD-count-total=${osd_total_count}"

	#check data disks, not support symbolink and must block device
	for dev in ${arr_all_data_disks[@]}
	do
		if is_mounted $dev
		then
			add_log "ERROR" "'$dev' was mounted" $print_log
			my_exit 1 "$RESULT_ERROR" "'$dev' was mounted." $format
		fi

		if is_device_used $dev 
		then
			add_log "ERROR" "found part label of $dev in $ceph_conf, this means $dev is in use by another osd" $print_log
			my_exit 1 "$RESULT_ERROR" "$dev is in use by another osd." $format
		fi

		if ls $dev*? > /dev/null 2>&1
		then
			LAST_ERROR_INFO="$LAST_ERROR_INFO\n${dev} has partitions"
			if [ $force -eq 0 ]
			then
				add_log "ERROR" "$dev has partitions" $print_log
				my_exit 1 "$RESULT_ERROR" "$dev has partitions." $format
			else
				add_log "WARNIING" "$dev has partitions" $print_log
			fi
		fi
	done
}

#1st param: /dev/xxx
#2nd param: part label
#3rd param: from
#4th param: to
function my_parted()
{
	local dev=$1
	local new_part=$2
	local from=$3
	local to=$4
	if ret_err=$(get_new_partition "$dev" $new_part $from $to 2>&1)
	then
		add_log "INFO" "create partition in '$dev' OK($new_part $from $to). $ret_err"
	else
		add_log "ERROR" "create partition in '$dev' failed($new_part $from $to). $ret_err" $print_log
		LAST_ERROR_INFO="Create partition $new_part in '$dev' failed. $ret_err"
		return 1
	fi
	return 0
}

#prepare data disks, one osd per data disk partition
function prepare_disk()
{
	local n=0
	local ret_err=
	for dev in ${arr_all_data_disks[@]}
	do
		if ! ret_err=$(mk_gpt_label $dev)
		then
			LAST_ERROR_INFO="make gpt label in '$dev' failed.$ret_err"
			add_log "ERROR" "make gpt label in '$dev' failed.$ret_err" $print_log
			return 1
		fi
		#total
		local size=$(get_blockdev_size $dev)
		add_log "INFO" "$dev, total size=$((size/1024))G"
		#total - reverse
		size=$((size-head_reverse_size-tail_reverse_size))
		add_log "INFO" "$dev, total available size=$((size/1024))G, reverse-size=$(($((head_reverse_size+tail_reverse_size))/1024))G"
		#available for each osd
		size=$(echo $size/$osd_num_in_each_disk|bc)
		add_log "INFO" "$dev, each osd size=$((size/1024))G"
		if [ $size -lt $one_osd_min_size ]
		then
			local err="not enough space in $dev, one osd need at least $((one_osd_min_size/1024))G space"
			err="$err""(wal=$((wal_part_size/1024))G,db=$((db_part_size/1024))G,min_block=$((block_part_min_size/1024))G),"
			err="$err""but we got olny $((size/1024))G for each osd"

			LAST_ERROR_INFO="$err"
			add_log "ERROR" "$err" $print_log
			return 1
		fi

		#now $size is each osd size
		#my_parted $dev "head-reverse-part" 0M ${head_reverse_size}M || return 1
		for((i=0; i<$osd_num_in_each_disk; ++i))
		do
			local osd_id=${arr_all_osd_id[$n]}
			local new_part="osd-device-${osd_id}-wal"
			local from=$(echo $i*$size+$head_reverse_size|bc)
			local to=$(echo $from+$wal_part_size|bc)
			my_parted $dev ${new_part} ${from}M ${to}M || return 1

			new_part="osd-device-${osd_id}-db"
			from=$to
			to=$(echo $from+$db_part_size|bc)
			my_parted $dev ${new_part} ${from}M ${to}M || return 1

			new_part="osd-device-${osd_id}-block"
			from=$to
			to=$(echo "($i+1)*$size"|bc)
			my_parted $dev ${new_part} ${from}M ${to}M || return 1

			let "n++"
		done
	done
	return 0
}

function create_osd_ids()
{
	local _osd_id=
	for((i=0; i<$osd_total_count; ++i))
	do
		#if ! _osd_id=$(ceph osd create 2>&1)
		if ! _osd_id=$(sudo ceph osd create 2>/dev/null)
		then
			LAST_ERROR_INFO="ceph osd create failed. $_osd_id"
			add_log "ERROR" "ceph osd create failed. $_osd_id"
			return 1
		fi
		arr_all_osd_id[$i]=$_osd_id
	done
	add_log "INFO" "OSD-IDs=${arr_all_osd_id[*]}"
	return 0
}

function write_ceph_conf()
{
	create_roll_back_conf || :
	back_conf || :
	local part_path="/dev/disk/by-partlabel"
	for((i=0; i<$osd_total_count; ++i))
	do
		local osd_id=${arr_all_osd_id[$i]}
		local data_dir="${osd_data_dir}/osd-device-${osd_id}-data"
		#local wal_path="$part_path/osd-device-${osd_id}-wal"
		#local db_path="$part_path/osd-device-${osd_id}-db"
		#local block_path="$part_path/osd-device-${osd_id}-block"
		local dev=${arr_all_data_disks[$i]}
		local wal_path="${dev}p1"
		local db_path="${dev}p2"
		local block_path="${dev}p3"

		local pos="\[client\]"
		local osd_line=""
		if ! osd_line=$(grep "$pos" $ceph_conf)
		then
			echo "[osd.$osd_id]" >> $ceph_conf
			echo -e "\thost = $host" >> $ceph_conf
			echo -e "\tosd data = $data_dir" >> $ceph_conf
			echo -e "\tbluestore block wal path = $wal_path" >> $ceph_conf
			echo -e "\tbluestore block db path = $db_path" >> $ceph_conf
			echo -e "\tbluestore block path = $block_path" >> $ceph_conf
		else
			local osd_sec="\[osd.$osd_id\]"
			local osd_host="\\\\thost = $host"
			local osd_data="\\\\tosd data = $data_dir" >> $ceph_conf
			local osd_wal_path="\\\\tbluestore block wal path = $wal_path"
			local osd_db_path="\\\\tbluestore block db path = $db_path"
			local osd_block_path="\\\\tbluestore block path = $block_path"

			sudo sed -i "/$pos/i$osd_sec" $ceph_conf 
			sudo sed -i "/$pos/i$osd_host" $ceph_conf 
			sudo sed -i "/$pos/i$osd_data" $ceph_conf 
			sudo sed -i "/$pos/i$osd_wal_path" $ceph_conf
			sudo sed -i "/$pos/i$osd_db_path" $ceph_conf
			sudo sed -i "/$pos/i$osd_block_path" $ceph_conf
		fi  
	done
}

function create_osd()
{
	for((i=0; i<$osd_total_count; ++i))
	do
		local osd_id=${arr_all_osd_id[$i]}
		add_log "INFO" "============osd.$osd_id==============" $print_log
		local osd_dir="${osd_data_dir}/osd-device-${osd_id}-data"
		mkdir -p $osd_dir
		#[ x"$osd_dir" != x ] && rm -fr $osd_dir/*
		local ret_err=
		if ! ret_err=$(sudo ceph-osd -i $osd_id --mkfs --mkkey 2>&1)
		then
			LAST_ERROR_INFO="$ret_err"
			add_log "ERROR" "$ret_err" $print_log
			return 1
		fi

		if ! ret_err=$(sudo ceph auth add osd.$osd_id osd 'allow *' mon 'allow profile osd' -i $osd_dir/keyring 2>&1)
		then
			LAST_ERROR_INFO="$ret_err"
			add_log "ERROR" "$ret_err" $print_log
			return 1
		fi

		#only executed when add first OSD
		if ! sudo ceph osd tree| grep "host $host" &> /dev/null;
		then
			if ! sudo ceph osd crush add-bucket $host host &> /dev/null; then return 1; fi
			if ! sudo ceph osd crush move $mon_id root=default &> /dev/null; then return 1; fi
		fi

		if ! ret_err=$(sudo ceph osd crush add osd.$osd_id 1.0 host=$host 2>&1)
		then
			LAST_ERROR_INFO="$ret_err"
			add_log "ERROR" "$ret_err" $print_log
			return 1
		fi

		if ! ret_err=$(sudo ceph-osd -i $osd_id 2>&1)
		then
			LAST_ERROR_INFO="$ret_err"
			add_log "ERROR" "$ret_err" $print_log
			return 1
		fi

	    	add_log "INFO" "--- Create osd.$osd_id OK ---" $print_log
	done
	return 0
}

function check_status()
{
	local ret=1
	for((i=0; i<$osd_total_count; ++i))
	do
		sleep 1
		local osd_stat=$(sudo ceph osd dump|grep ^osd.|awk '{print $1" "$2" "$3}'|grep -w osd.${arr_all_osd_id[$i]})
		#echo $osd_stat
		local arr_stat=($osd_stat)
		echo "${arr_stat[*]}"
		add_log "INFO" "${arr_stat[*]}"
		if [ x"${arr_stat[1]}" != x"up" -o  x"${arr_stat[2]}" != x"in" ]
		then
			#fail
			ret=0
		fi
	done
	return $ret
}

function rollback_osds()
{
	add_log "INFO" "rollback OSDs..."
	for((i=0; i<$osd_total_count; ++i))
	do
		sleep 1
		remove_one_osd "${arr_all_osd_id[$i]}" 0

		local osd_data="${osd_data_dir}/osd-device-${arr_all_osd_id[$i]}-data"
		if [ -d "$osd_data" ]
		then
			add_log "INFO" "deleting ${osd_data}..."
			sudo rm -fr $osd_data
		fi
	done
}

function rollback()
{
	add_log "INFO" "something was wrong, rollback..."  $print_log
	rollback_conf
	rollback_osds
}

#start creating
parse_and_check_params
create_osd_ids || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format

if ! prepare_disk
then
	#rollback_osds
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

write_ceph_conf

if ! create_osd
then
	#rollback
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
else
	#check_status || :
	create_logrotate_file
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" $format
fi

