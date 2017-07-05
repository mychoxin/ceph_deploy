#!/bin/bash

set -e

SHELL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $SHELL_DIR/common_fun

add_log
add_log "INFO" "$hostname creating cluster..."
add_log "INFO" "$0 $*"

function usage()
{
	echo "Usage:$0 -m|--monitors <file with monitor IPs>" \
	" -s|--storagenodes <file with osd IPs>" \
	" [-n|--osd-num <osd num per journal device>]" \
	" -c|--cluster-net <cluster net>" \
	" -p|--public-net <public net>" \
	" [-h|--help]"

	echo "-m, --monitors <file with monitor IPs>"
	echo -e "\tIPs used to ssh and remote create monitors, make sure SSH login without passwd, not support ipv6 or lookback interface"
	echo -e "\teg. -m /tmp/mon.txt"

	echo "-s, --storagenodes <file with osd IPs>"
	echo -e "\tIPs used to ssh and remote create OSD, make sure SSH login without passwd, not support ipv6 or lookback interface"
	echo -e "\teg. -s /tmp/osd.txt"
	echo -e "\tFor each osd node,  if there is enough journal devices, all devices about /dev/sd* except /dev/sda\n" \
	        "\twill be used as data devices, and one osd uses one data device, every data device will be parted to\n" \
		"\tone partition and format to xfs; All devices about /dev/nvme* will be used as journal devices and every\n" \
		"\tjournal device will be parted to N partitions, N is determined by param of -n option.\n" \

        echo "[-n, --osd-num<osd num in each journal device>]"
        echo -e "\tdefault is 4, partitions num of each journal device will be parted to"

        echo "-c, --cluster-net<cluster net>"
        echo -e "\teg. -c 10.10.20.1, only support 24 bits mask now, not support ipv6 or lookback net"

        echo "-p, --public-net<public net>"
        echo -e "\teg. -p 10.10.30.2, only support 24 bits mask now, not support ipv6 or lookback net"

        echo "[-h, --help]"
        echo -e "\tget this help info"
}

local_opt=""
RESULT_ERROR="Create cluster failed."
RESULT_OK="Create cluster successfully."
sub_shell_opt="--unformat"
if ! temp=$(getopt -o m:s:n:r:c:p:h --long monitors:,storagenodes:,osd-num:,rule-num:,cluster-net:,public-net:,help -n 'note' -- "$@" 2>&1)
then
	#usage > &2
	my_exit 1 "$RESULT_ERROR" "parse arguments failed, $temp"
fi

mon_list="/$tmp_dir/mon.txt"
osd_list="/$tmp_dir/osd.txt"

ceph_conf_tpl=$SHELL_DIR/ceph.conf.template
eval set -- "$temp"
while true
do
        case "$1" in
                -c|--cluster-net) cluster_ip=$2; shift 2;;
                -p|--public-net) public_ip=$2; shift 2;;
		-m|--monitors) mon_init_memb=$2;arr_ip_monitors=($(sudo cat $2 | grep -v ^#)); mon_list=$2; shift 2;;
		-s|--storagenodes) arr_ip_storage=($(sudo cat $2 | grep -v ^#)); osd_list=$2;shift 2;;
		-n|--osd-num) data_disks_of_each_journal=$2; shift 2;;
                #-r|--rule-num) data_disks_of_each_journal=$2; shift 2;;
                -h|--help) usage; exit 1;;
                --) shift; break;;#??
                 *) my_exit 1 "$RESULT_ERROR" "unkown arguments $1";;
        esac
done

function check_all_ip_ssh()
{
	LAST_ERROR_INFO=""
	local ret=0
	for node in ${arr_ip_monitors[@]}
	do
		if ! is_current_machine $node
		then
			if ! check_ssh $node
			then
				add_log "ERROR" "ssh check monitor node: $node failed" $print_log
				ret=1
			fi
		fi
	done

	#exit, otherwise the user will wait for long time 
	[ $ret -eq 1 ] && return $ret

	for node in ${arr_ip_storage[@]}
	do
		if ! is_current_machine $node
		then
			if ! check_ssh $node
			then
				add_log "ERROR" "ssh check storage node: $node failed" $print_log
				return 1
			fi
		fi
	done

	return $ret
}

function check_all_ip_valid()
{
	local ret=0
	LAST_ERROR_INFO=""

	for node in ${arr_ip_monitors[@]}
	do
		if ! is_valid_ip $node
		then
			add_log "ERROR" "monitor node: $node, ip invalid" $print_log
			LAST_ERROR_INFO="monitor node $node, invalid ip.\n${LAST_ERROR_INFO}"
			ret=1
		fi
	done

	for node in ${arr_ip_storage[@]}
	do
		if ! is_valid_ip $node
		then
			add_log "ERROR" "storage node: $node, ip invalid" $print_log
			LAST_ERROR_INFO="storage node $node, invalid ip.\n${LAST_ERROR_INFO}"
			ret=1
		fi
	done
	return $ret
}

function check_all_node_not_exist_conf()
{
	local ret=0
	if ! $remote_exec $mon_list "sudo bash -c 'ls /etc/ceph/ceph.conf 2>/dev/null'"
	then
		ret=1
		LAST_ERROR_INFO="check exist ceph.conf failed"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
	fi

	if ! $remote_exec $osd_list "sudo bash -c 'ls /etc/ceph/ceph.conf 2>/dev/null'"
	then
		ret=1
		LAST_ERROR_INFO="check exist ceph.conf failed"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
	fi

	return $ret
}

function check_all_node_not_exist_ceph_daemon()
{
	local ret=0
	local all_list=all.txt
	make_all_node $mon_list $osd_list $all_list
	if ! $remote_exec $all_list "sudo bash -c 'pidof ceph-mon 2>/dev/null'"
	then
		ret=1
		LAST_ERROR_INFO="check exist ceph-mon failed"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
	fi

	if ! $remote_exec $all_list "sudo bash -c 'pidof ceph-osd 2>/dev/null'"
	then
		ret=1
		LAST_ERROR_INFO="check exist ceph-osd failed"
		add_log "ERROR" "$LAST_ERROR_INFO" $print_log
	fi
	return $ret
}

function check_all_node_exist_pubnet_and_clstnet()
{
	local ret=0
	local pubnet_tmp=$(echo $cluster_ip|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"\."$2"\."$3"\..*""/"$5"$"}')
	local clstnet_tmp=$(echo $public_ip|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"\."$2"\."$3"\..*""/"$5"$"}')
	local pubnet_print=$(echo $cluster_ip|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"."$2"."$3".*""/"$5}')
	local clstnet_print=$(echo $public_ip|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"."$2"."$3".*""/"$5}')
	LAST_ERROR_INFO=""
	if ! $remote_exec $mon_list "ip addr ls |awk '{print \$2}' |grep $pubnet_tmp" &> /dev/null
	then
		add_log "ERROR" "monitor node: $node, no public net $pubnet_print" $print_log
		LAST_ERROR_INFO="monitor node $node no public net $pubnet_print.\n${LAST_ERROR_INFO}"
		ret=1
	fi

	if ! $remote_exec $osd_list "ip addr ls |awk '{print \$2}' |grep $clstnet_tmp" &> /dev/null
	then
		add_log "ERROR" "storage node: $node, no cluster net $clstnet_print" $print_log
		LAST_ERROR_INFO="storage node $node no cluster net $clstnet_print.\n${LAST_ERROR_INFO}"
		ret=1
	fi

	if ! $remote_exec $osd_list "ip addr ls |awk '{print \$2}' |grep $pubnet_tmp" &> /dev/null
	then
		add_log "ERROR" "storage node: $node, no public net $pubnet_print" $print_log
		LAST_ERROR_INFO="storage node $node no public net $pubnet_print\n${LAST_ERROR_INFO}"
		ret=1
	fi
	return $ret
}

function check_all_storage_nvme()
{
	local log=""
	local has_err=0
	LAST_ERROR_INFO=""
	for node in ${arr_ip_storage[@]}
	do
		remote_cp_common $node || return 1
		if ! $SSH ${user}@$node "source $remote_tmp_dir/common_fun; dev_operation_prompt;"
		then
			has_err=1
			add_log "ERROR" "$node, remote execute fun dev_operation_prompt failed" $print_log
			LAST_ERROR_INFO="storage node $node, get info about '$osd_dev' device failed.\n${LAST_ERROR_INFO}"
			continue
		fi

		#check execute result
		#no nvme device, mounted or has partiontion
		if echo "$log" |grep "no device" > /dev/null ||
		   echo "$log" |grep "mounted" > /dev/null
		then
			has_err=1
			LAST_ERROR_INFO="$node `echo "$log" |awk '{if(NR==1){printf $0}else{printf ", "$0}}'`.\n${LAST_ERROR_INFO}"
			add_log "ERROR" "$node `echo "$log" |awk '{if(NR==1){printf $0}else{printf ", "$0}}'`" $print_log
		elif echo "$log" |grep "has partition" > /dev/null
		then
			LAST_ERROR_INFO="$node `echo "$log" |awk '{if(NR==1){printf $0}else{printf ", "$0}}'`.\n${LAST_ERROR_INFO}"
			add_log "WARNING" "$node `echo "$log" |awk '{if(NR==1){printf $0}else{printf ", "$0}}'`" $print_log
			#if has error, no need to wait for $print_log, because we will return error after for
			if [ $has_err -eq 1 ]
			then
				continue
			elif ! wait_for_yes "some devices in $node has partitions, your data will be destroyed, continue"
			then
				return 1
			fi
		fi
	done

	return $has_err
}

function parse_and_check_params()
{
	add_log "INFO" "checking params..." $print_log
	#check empty
	if [ x"$cluster_ip" = x ]
	then
		my_exit 1 "$RESULT_ERROR" "invalid argument, cluster net is empty."
	fi

	if [ x"$public_ip" = x ]
	then
		my_exit 1 "$RESULT_ERROR" "invalid argument, public net is empty"
	fi

	add_log "INFO" "monitor nodes=${arr_ip_monitors[*]}" $print_log
	add_log "INFO" "osd nodes=${arr_ip_storage[*]}" $print_log

	#check monitors num
	if [ ${#arr_ip_monitors[@]} -ne 1 ] && [ ${#arr_ip_monitors[@]} -ne 3 ] && [ ${#arr_ip_monitors[@]} -ne 5 ]
	then
		add_log "ERROR" "monitor count must 1, 3, 5" $print_log
		my_exit 1 "$RESULT_ERROR" "monitor count must is 1/3/5."
	fi

	if [ ${#arr_ip_storage[@]} -lt 1 ]
	then
		add_log "ERROR" "osd ip not given" $print_log
		my_exit 1 "$RESULT_ERROR" "storage node not given."
	fi

	#add_log "INFO" "osd_num_in_each_disk=$osd_num_in_each_disk" $print_log
	#check_osd_num_in_each_disk "$osd_num_in_each_disk" || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
	#local_opt="-n $osd_num_in_each_disk $local_opt"
	add_log "INFO" "osd_num_of_each_journal=$data_disks_of_each_journal" $print_log
	check_datadisks_num_of_journal "$data_disks_of_each_journal" || my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
	local_opt="-n $data_disks_of_each_journal $local_opt"

	#check look back
	if [ x"`echo $cluster_ip |grep ^\"127\.\"`" != x ]
	then
		add_log "ERROR" "'$cluster_intf' is lookback net but not supported now" $print_log
		my_exit 1 "$RESULT_ERROR" "'$cluster_ip' is lookback net but not supported now."
	fi

	if [ x"`echo $public_ip |grep ^\"127\.\"`" != x ]
	then
		add_log "ERROR" "'$public_ip' is lookback net but not supported now" $print_log
		my_exit 1 "$RESULT_ERROR" "'$public_ip' is lookback net but not supported now."
	fi

	if ! is_valid_ip "$cluster_ip"
	then
		add_log "ERROR" "cluster net $cluster_ip invalid" $print_log
		LAST_ERROR_INFO="cluster net $cluster_ip invalid.\n${LAST_ERROR_INFO}"
		ret=1
	fi

	if ! is_valid_ip "$public_ip"
	then
		add_log "ERROR" "public net $public_ip invalid" $print_log
		LAST_ERROR_INFO="public net $public_ip invalid.\n${LAST_ERROR_INFO}"
		ret=1
	fi

	local tmp_ip="$public_ip"
	public_ip=$(ip addr ls |grep -w inet| grep -w "$public_ip" | awk '{print $2}' | head -n 1)
	if [ x"$public_ip" = x ]
	then
		add_log "ERROR" "get public network from $tmp_ip failed" $print_log
		my_exit 1 "$RESULT_ERROR" "get public network from $tmp_ip failed."
	fi

	local tmp_ip="$cluster_ip"
	cluster_ip=$(ip addr ls |grep -w inet| grep -w "$cluster_ip" | awk '{print $2}' | head -n 1)
	if [ x"$cluster_ip" = x ]
	then
		add_log "ERROR" "get cluster network from $tmp_ip failed" $print_log
		my_exit 1 "$RESULT_ERROR" "get cluster network from $tmp_ip failed."
	fi

	add_log "INFO" "public net=$public_ip"
	add_log "INFO" "cluster net=$cluster_ip"

	check_all_ip_valid || my_exit $? "$RESULT_ERROR" "$LAST_ERROR_INFO"
#	check_all_ip_ssh || my_exit $? "$RESULT_ERROR" "$LAST_ERROR_INFO"
	check_all_node_not_exist_ceph_daemon || my_exit $? "$RESULT_ERROR" "$LAST_ERROR_INFO"
	check_all_node_not_exist_conf || my_exit $? "$RESULT_ERROR" "$LAST_ERROR_INFO"
	check_all_node_exist_pubnet_and_clstnet || my_exit $? "$RESULT_ERROR" "$LAST_ERROR_INFO"
#	check_all_storage_nvme || my_exit $? "$RESULT_ERROR" "$LAST_ERROR_INFO"
}

function set_conf()
{
	#assert: the current machine is a node
	sudo mkdir -p $conf_dir
	sudo cp $ceph_conf_tpl $ceph_conf
	fsid=$(uuidgen)

	#192.168.28.107/24 -> 192.168.28.0/24
	local conv_pub_net=$(echo $public_ip|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"."$2"."$3"."0"/"$5}')
	conv_pub_net=$(echo $conv_pub_net| sudo sed 's#\/#\\\/#g')
	local conv_clst_net=$(echo $cluster_ip|awk -F/ '{print $1"."$2}' |awk -F. '{print $1"."$2"."$3"."0"/"$5}')
	conv_clst_net=$(echo $conv_clst_net| sudo sed 's#\/#\\\/#g')

	add_log "INFO" "fsid=$fsid"
	add_log "INFO" "conv_pub_net=$conv_pub_net"
	add_log "INFO" "conv_clst_net=$conv_clst_net"
	
	local tpl_fsid="_FSID_"
	local tpl_inimb="_MON_INITIAL_MEMBERS_"
	local tpl_pubnet="_PUBLIC_NETWORK_"
	local tpl_clstnet="_CLUSTER_NETWORK_"

	if grep $tpl_fsid $ceph_conf > /dev/null
	then
		sudo sed -i "s/$tpl_fsid/$fsid/" $ceph_conf
	fi

	if grep $tpl_inimb $ceph_conf > /dev/null
	then
		sudo sed -i "s/$tpl_inimb/$mon_init_memb/" $ceph_conf
	fi
	
	if grep $tpl_pubnet $ceph_conf > /dev/null
	then
		sudo sed -i "s/$tpl_pubnet/$conv_pub_net/" $ceph_conf
	fi

	if grep $tpl_clstnet $ceph_conf > /dev/null
	then
		sudo sed -i "s/$tpl_clstnet/$conv_clst_net/" $ceph_conf
	fi
}

function create_monitor_osd()
{
	local tmp_list=tmp_list.txt
	local remote_ip=${arr_ip_monitors[0]}
	sudo bash -c "cat $remote_ip > /$tmp_dir/$tmp_list"
	#create mon
	remote_prepare_files $tmp_list
	$remote_exec $tmp_list "$remote_tmp_dir/create_monitor_local.sh"

	#add mon
	sudo bash -c "echo '' > /$tmp_dir/$tmp_list"
	for((i=1; i<${#arr_ip_monitors[@]}; ++i))
	do
		sudo bash -c "echo ${arr_ip_monitors[$i]} >> /$tmp_dir/$tmp_list"
	done
	[ $i -gt 1 ] && remote_prepare_files $tmp_list
	[ $i -gt 1 ] && $remote_exec $tmp_list "$remote_tmp_dir/create_monitor_local.sh -a"
	[ $i -gt 1 ] && \
	for((i=0; i<${#arr_ip_monitors[@]}; ++i))
	do
		local tmp_conf=tmp.mon.conf
		local node=${arr_ip_monitors[$i]}
		sudo scp $user@${node}:"$conf_dir/$tmp_conf" $ceph_dir/$node.$tmp_conf || :
		sudo cat $conf_dir/$node.$tmp_conf >> $ceph_conf || :
	done

	local_opt="-fu -r $data_disks_of_each_journal $local_opt"
	remote_prepare_files $osd_list
	$remote_exec $osd_list "$remote_tmp_dir/create_osds_local.sh $local_opt"

	for((i=0; i<${#arr_ip_storage[@]}; ++i))
	do
		local tmp_conf=tmp.osd.conf
		local node=${arr_ip_storage[$i]}
		sudo scp $user@${node}:"$conf_dir/$tmp_conf" $ceph_dir/$node.$tmp_conf || :
		sudo cat $conf_dir/$node.$tmp_conf >> $ceph_conf || :
	done

	#sync conf to other node
	local all_list=all.txt
	make_all_node $mon_list $osd_list $all_list
	$remote_cp $all_list "$ceph_conf" "$tmp_dir"
	$remote_exec $all_list "sudo cp $tmp_dir/ceph.conf $ceph_conf"
}

#start creating
parse_and_check_params
set_conf
if create_monitor_osd
then
	wait_for_health_ok || :
	my_exit 0 "$RESULT_OK" "$LAST_ERROR_INFO"
else
	#./delete_cluster.sh -nf "${arr_ip_monitors[*]} ${arr_ip_storage[*]}" || :
	my_exit 1 "$RESULT_ERROR" "$LAST_ERROR_INFO"
fi

