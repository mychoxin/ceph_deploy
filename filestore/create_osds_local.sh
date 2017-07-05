#!/bin/bash

head_reverse_size=10
tail_reverse_size=$((10*1024))

#using in VM
#head_reverse_size=10
#tail_reverse_size=$((0*1024))

rules=1
warn_jnl_size=$((10*1024))
error_jnl_size=$((1024))

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

MKFS="sudo mkfs.xfs"
MOUNT="sudo mount -o noatime,nodiratime"

set -e
#set -x

clear_log
add_log "INFO" "$hostname: local adding osd..."
add_log "INFO" "$0 $*"

function usage()
{
	echo "Usage:$0 [-n|--num <osd num of each data disk>] [-f|--force] [-r|--rule-num <data disks num of each journal disk>] [-h|--help]"
	echo "-n, --osd-num<osd num of each data disk>"
	echo -e "\tevery data disk will be parted to num*3 partitions(wal,db,block)"

	echo "-f, --force"
	echo -e "\tignore existed partitions in device"

	echo "-r|--rule-num <data disks num of each journal disk>"
	echo -e "\tdata disks num of each journal disk"

	echo "-u, --unformat"
	echo -e "\twhen other shell call this shell, print result to parent shell without format"
	
	echo "[-h, --help]"
	echo -e "\thelp info"
}

RESULT_ERROR="Create osd on $hostname failed."
RESULT_OK="Create osd on $hostname successfully."

if ! temp=$(getopt -o n:r:p:fuh --long osd-num:,rule-num:,prefix:,force,unformat,help -n 'note' -- "$@" 2>&1)
then
	add_log "ERROR" "parse arguments failed, $temp" $print_log
	my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp" $format
fi

host=$(hostname)
mon_id=$host
force=0
format=1
data_disks_of_each_journal=4
tmp_conf=tmp.osd.conf

eval set -- "$temp"
while true
do
        case "$1" in
                -n|--osd-num) osd_num_in_each_disk=$2; shift 2;;
                -r|--rule-num) data_disks_of_each_journal=$2; shift 2;;
                -p|--prefix) tmp_conf=$2; shift 2;;
                -f|--force) force=1; shift 1;;
                -u|--unformat) format=0; shift 1;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                *) my_exit 1 "$RESULT_ERROR" "parse arguments failed" $format;;
        esac
done

arr_all_osd_id=()

#get osd count that we will create
function get_osd_count()
{
	local max_data_disk_count=$(echo $jnl_disk_count*$data_disks_of_each_journal | bc)
	if [ $max_data_disk_count -gt ${data_disks_total_count} ]
	then
		max_data_disk_count=${data_disks_total_count}
	fi
#echo $max_data_disk_count*$osd_num_in_each_disk | bc
    echo $jnl_disk_count
}

#1st param: out put argument
function get_each_osd_journal_size()
{
	local out_put=$1
	local all_size=$(get_blockdev_size "${arr_all_jnl_disks[*]}")
	local j_size=$(echo "($all_size-($head_reverse_size+$tail_reverse_size)*$jnl_disk_count)/$osd_total_count" | bc)
	if [ $j_size -lt $error_jnl_size ]
	then
		set_last_error LAST_ERROR_INFO "journal disks not enough space, journal size: ${j_size}M less than ${error_jnl_size}M"
		return 1
	elif [ $j_size -lt $warn_jnl_size ]
	then
		set_last_error LAST_ERROR_INFO "journal size: ${j_size}M less than ${warn_jnl_size}M"
	fi
#eval $out_put=$j_size
eval $out_put=204800
	return 0
}

function parse_and_check_params()
{
	add_log "INFO" "osd_num_in_each_disk=$osd_num_in_each_disk" $print_log
	if ! check_osd_num_in_each_disk "$osd_num_in_each_disk"
	then
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi

	add_log "INFO" "data_disks_of_each_journal=$data_disks_of_each_journal" $print_log
	if ! check_datadisks_num_of_journal "$data_disks_of_each_journal"
	then
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi

    	if ! arr_all_data_disks=($(get_data_devices))
	then
		add_log "ERROR" "failed to find sd device in $hostname" $print_log
		my_exit 1 "$RESULT_ERROR" "failed to find sd device" $format
	fi

	data_disks_total_count=${#arr_all_data_disks[@]}

	add_log "INFO" "all-data-disks=${arr_all_data_disks[*]}" $print_log
	add_log "INFO" "all-data-disks-count=${data_disks_total_count}" $print_log
	add_log "INFO" "osd-count-in-each-disk=${osd_num_in_each_disk}" $print_log

    	if ! arr_all_jnl_disks=($(get_journal_devices))
	then
		add_log "ERROR" "failed to find nvme device in $hostname" $print_log
		my_exit 1 "$RESULT_ERROR" "failed to find nvme device" $format
	fi
	add_log "INFO" "all-journal-disks=${arr_all_jnl_disks[*]}" $print_log

	jnl_disk_count=${#arr_all_jnl_disks[@]}
	add_log "INFO" "jnl_disk_count=${jnl_disk_count}" $print_log

	osd_total_count=$(get_osd_count)
	add_log "INFO" "osd-total-count=${osd_total_count}" $print_log

	if ! get_each_osd_journal_size osd_jnl_size
	then
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
		my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
	fi
	add_log "INFO" "osd_jnl_size=${osd_jnl_size}" $print_log

        #check data disks, not support symbolink and must block device
        for dev in ${arr_all_data_disks[@]} ${arr_all_jnl_disks[@]}
        do
		if is_mounted $dev
		then
			add_log "ERROR" "'$dev' was mounted" $print_log
			my_exit 1 "$RESULT_ERROR" "'$dev' was mounted." $format
		fi

		if ls $dev*? > /dev/null 2>&1
		then
			LAST_ERROR_INFO="$LAST_ERROR_INFO\n${dev} has partitions"
			if [ $force -eq 0 ]
			then
				add_log "ERROR" "$dev has partitions" $print_log
				my_exit 1 "$RESULT_ERROR" "$dev has partitions." $format
			else
				add_log "WARNING" "$dev has partitions" $print_log
			fi
		fi

		if is_device_used $dev
		then
			add_log "ERROR" "found part label of $dev in $ceph_conf, this means $dev is in use by another osd" $print_log
			my_exit 1 "$RESULT_ERROR" "$dev is in use by another osd." $format
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

#prepare journal disks, one osd one journal disk partition
function prepare_journal_disks()
{
	local n=0
	local j=0
	for((j=0; j<$jnl_disk_count; ++j))
	do
		dev=${arr_all_jnl_disks[$j]}
		if [ $n -ge $osd_total_count ]
		then
			break
		fi

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

		#now $size is left available size
		if [ $size -lt $((osd_jnl_size/2)) ]
		then
			LAST_ERROR_INFO="$LAST_ERROR_INFO\n$dev will be not used due to low capacity."
			add_log "WARNING" "$dev will be not used due to low capacity." $print_log
			continue
		fi

		my_parted $dev "head-reverse-part-${dev##*/}" 0M ${head_reverse_size}M || return 1

		local part_size=$osd_jnl_size
		local i=0
		while [ $n -lt $osd_total_count ]
		do
			if [ $size -lt $((osd_jnl_size/2)) ]
			then
				break
			elif [ $size -lt $(($osd_jnl_size+$osd_jnl_size/2)) ]
			then
				part_size=$size
			fi

			local osd_id=${arr_all_osd_id[$n]}
			local new_part="osd-${osd_id}-journal"
			local from=$(echo $i*$osd_jnl_size+$head_reverse_size|bc)
			local to=$(echo $from+$part_size|bc)
			my_parted $dev ${new_part} ${from}M ${to}M || return 1
			((size -= $part_size))
			((++i))
			let "n++"
			break
		done
	done

	if [ $j -lt $jnl_disk_count ]
	then
		set_last_error LAST_ERROR_INFO "journal disks: ${arr_all_jnl_disks[@]:$j:(($jnl_disk_count-$j))} will not be used"
		add_log "WARNING" "$LAST_ERROR_INFO" $print_log
	fi
	return 0
}

#prepare data disks, one osd per data disk partition
function prepare_data_disk()
{
	local n=0
	local ret_err=
        for dev in ${arr_all_data_disks[@]}
        do
#if ! ret_err=$(mk_gpt_label $dev)
#		then
#			LAST_ERROR_INFO="make gpt label in '$dev' failed.$ret_err"
#			add_log "ERROR" "make gpt label in '$dev' failed.$ret_err" $print_log
#			return 1
#		fi
		#total
                local size=$(get_blockdev_size $dev)
		add_log "INFO" "$dev, total size=$((size/1024))G"
		#total - reverse
		size=$((size-head_reverse_size-tail_reverse_size-204800))
		add_log "INFO" "$dev, total available size=$((size/1024))G, reverse-size=$(($((head_reverse_size))/1024))G"
		#available for each osd
                size=$(echo $size/$osd_num_in_each_disk|bc)
		add_log "INFO" "$dev, each osd size=$((size/1024))G"
		if [ $size -lt 0 ]
		then
			local err="not enough space in $dev."
			LAST_ERROR_INFO="$err"
			add_log "ERROR" "$err" $print_log
			return 1
		fi

		#now $size is each osd size
#my_parted $dev "head-reverse-part-${dev##*/}" 0M ${head_reverse_size}M || return 1
                for((i=0; i<$osd_num_in_each_disk; ++i))
                do
			local osd_id=${arr_all_osd_id[$n]}
			local new_part="osd-${osd_id}-data"
#local from=$(echo $i*$size+$head_reverse_size|bc)
            local from=$(echo $i*$size+$head_reverse_size+204800|bc)
			local to=$(echo $from+$size|bc)
			my_parted $dev ${new_part} ${from}M ${to}M || return 1
			let "n++"
                done
        done
	return 0
}

#prepare data disks, one osd one data disk partition
function prepare_data_mount()
{
	local ret_err=""
        for((i=0; i<$osd_total_count; ++i))
        do
                local osd_id=${arr_all_osd_id[$i]}
		local part="/dev/disk/by-partlabel/osd-${osd_id}-data"
		sudo umount $part &> /dev/null || :
                if ! ret_err=$($MKFS -f $part 2>&1)
		then
			LAST_ERROR_INFO="mkfs in part $part failed, $ret_err"
			add_log "ERROR" "$LAST_ERROR_INFO" $print_log
			return 1
		fi

                local osd_id=${arr_all_osd_id[$i]}
                local osd_dir="$osd_data_dir/osd-$osd_id"
                sudo mkdir -p $osd_dir
                if ! ret_err=$($MOUNT $part $osd_dir 2>&1)
		then
			LAST_ERROR_INFO="mount $part -> $osd_dir failed, $ret_err"
			add_log "ERROR" "$LAST_ERROR_INFO" $print_log
			return 1
		fi
        done
	#all OK
	return 0
}

function prepare_osd_ids()
{
	local _osd_id=
        for((i=0; i<$osd_total_count; ++i))
        do
                #if ! _osd_id=$(ceph osd create 2>&1)
                if ! _osd_id=$(sudo ceph osd create 2>> $local_log_file)
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
	local tmp_conf_path=$conf_dir/$tmp_conf
        for((i=0; i<$osd_total_count; ++i))
        do
                local osd_id=${arr_all_osd_id[$i]}
		local data_dir="${osd_data_dir}/osd-${osd_id}"
		local osd_journal="${part_path}/osd-${osd_id}-journal"

		local pos="\[client\]"
		local osd_line=""
		#if ! osd_line=$(grep "$pos" $ceph_conf)
		#then
                	echo "[osd.$osd_id]" > $tmp_conf_path
        		echo -e "\thost = $host" >> $tmp_conf_path
			echo -e "\tosd journal = ${part_path}/osd-${osd_id}-journal" >> $tmp_conf_path
        		echo -e "\tosd data = $data_dir" >> $tmp_conf_path
		#else
                #	local osd_sec="\[osd.$osd_id\]"
        	#	local osd_host="\\\\thost = $host"
		#	local osd_journal="\\\\tosd journal = ${part_path}/osd-${osd_id}-journal"
        	#	local osd_data="\\\\tosd data = $data_dir"

		#	sudo sed -i "/$pos/i$osd_sec" $ceph_conf 
		#	sudo sed -i "/$pos/i$osd_host" $ceph_conf 
		#	sudo sed -i "/$pos/i$osd_journal" $ceph_conf 
		#	sudo sed -i "/$pos/i$osd_data" $ceph_conf 
		#fi  
        done
}

function create_osd()
{
        for((i=0; i<$osd_total_count; ++i))
        do
                local osd_id=${arr_all_osd_id[$i]}
            	add_log "INFO" "============osd.$osd_id==============" $print_log
                local osd_dir="${osd_data_dir}/osd-${osd_id}"
		#mkdir -p $osd_dir
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
			if ! sudo ceph osd crush add-bucket $host host > /dev/null; then return 1; fi
			if ! sudo ceph osd crush move $mon_id root=default > /dev/null; then return 1; fi
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

                local osd_id=${arr_all_osd_id[$i]}
		local part="/dev/disk/by-partlabel/osd-${osd_id}-data"
		umount $part &> /dev/null || :

                local osd_dir="$osd_data_dir/ceph-$osd_id"
		if [ -d "$osd_dir" ]
		then
			add_log "INFO" "deleting ${osd_dir}..."
			sudo rm -fr $osd_dir
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

if ! prepare_osd_ids
then
	rollback_osds
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

if ! prepare_journal_disks
then
	rollback_osds
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

if ! prepare_data_disk
then
	rollback_osds
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

if ! prepare_data_mount
then
	rollback_osds
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
fi

write_ceph_conf

if ! create_osd
then
	rollback
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO" $format
else
	check_status || :
	create_logrotate_file
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO" $format
fi

