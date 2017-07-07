#!/bin/bash -e
if [ $# -ne 1 ]
then
   echo "$# Usage: $0 <file_path>"
   exit 1
fi

node_list=$1
remote_exec="pgm -A -p 10 -b -f"
remote_cp="pgmscp -A -p 10 -b -f"
user="wanjun.lp"

echo "generating local key..."
#ssh-keygen -t rsa -P ''

echo "copying local key to other node..."
$remote_cp $node_list ~/.ssh/id_rsa.pub /home/$user/

echo "making other node no-passwd-whith-sudo..."
$remote_exec $node_list " \
if grep $user /etc/sudoers &>/dev/null
then
   echo \"found $user in /etc/sudoers\" >&2
else
   sudo bash -c \"echo -e \\\""$user"\tALL=(ALL) NOPASSWD: ALL\\\" >> /etc/sudoers\"
fi
"
