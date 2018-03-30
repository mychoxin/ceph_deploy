echo -e "yes\n" | mdadm --create /dev/md1 --level=0 --raid-devices=2 /dev/sd[c-d]
echo -e "yes\n" | mdadm --create /dev/md2 --level=0 --raid-devices=2 /dev/sd[e-f]
echo -e "yes\n" | mdadm --create /dev/md3 --level=0 --raid-devices=2 /dev/sd[g-h]

echo -e "yes\n" | mdadm --create /dev/md4 --level=0 --raid-devices=2 /dev/sd[i-j]
echo -e "yes\n" | mdadm --create /dev/md5 --level=0 --raid-devices=2 /dev/sd[k-l]
echo -e "yes\n" | mdadm --create /dev/md6 --level=0 --raid-devices=2 /dev/sd[m-n]
