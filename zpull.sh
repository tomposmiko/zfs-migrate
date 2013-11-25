#!/bin/bash

check_switch_param(){
	if echo x"$1" |grep -q ^x-;then
		echo "Missing argument!"
		exit 1
	fi
}


VAR_f_kvm_check_state='f_kvm_check_state() {
# usage: ssh $s_host "$VAR_f_kvm_check_state; f_kvm_check_state"

	SHUTDOWN_MAXWAIT=600
	for sec in {1..$SHUTDOWN_MAXWAIT};do
		echo -n $sec

		if `virsh domstate ${vm}|head -1|grep -q "shut off"`;
			then
				echo "${vm}: shut down"
				exit 1
			else
				sleep 1
		fi

		echo "${vm}: cannot be shut down"
	done
}'
# make this function available on this host
eval $VAR_f_kvm_check_state
# make available to subshells and child processes
export -f f_kvm_check_state


usage(){
	echo "Usage:"
	echo "zpull -t lxc|kvm -s HOST -n VM"
	echo "   -t|--virt lxc|kvm"
	echo "   -s|--source HOST"
	echo "   -n|--vm|--name VM"
	echo
}


# Exit if no arguments!
let $# || { usage; exit 1; }

while [ "$#" -gt "0" ]; do
  case "$1" in
	-t|--virt)
		$PARAM=$2
		check_switch_param $PARAM
		virt_type="$PARAM"
		shift 2
	;;
	-s|--source)
		$PARAM=$2
		check_switch_param $PARAM
		s_host=$PARAM
		shift 2
	;;
	-n|--vm|--name)
		$PARAM=$2
		check_switch_param $PARAM
		vm=$PARAM
		shift 2
	;;
	-h|--help|*)
		usage
	;;
  esac
done


if [ x$virt_type != x"lxc" -a x$virt_type != x"kvm" ];
	then
		echo "Invalid or no virtualization type: "$virt_type" !"
		exit 1
fi


# checking if mbuffer is installed
if ! mbuffer -h >/dev/null 2>&1 ;then
	echo "No mbuffer installed!"
	exit 1
fi

cmd_ssh="ssh -c blowfish $s_host"
c_mbuffer_send="mbuffer -q -v 0 -s 128k -m 1G"
c_mbuffer_recv="mbuffer -s 128k -m 1G"


# check for zfs dataset
if ! $cmd_ssh "zfs list tank/${virt_type}/${vm} >/dev/null 2>&1";
	then
		echo "No dataset on source server: tank/${virt_type}/${vm} !"
		exit 1
fi

if [ $virt_type = kvm ]; then
	$cmd_ssh "virsh domstate $vm >/dev/null 2>&1" || { echo "No such VM: ${vm}"; exit 1; }
fi



$cmd_ssh zfs snap -r tank/${virt_type}/${vm}@m0
$cmd_ssh "zfs send -R -P tank/${virt_type}/${vm}@m0 | mbuffer -q -v 0 -s 128k -m 1G" | mbuffer -s 128k -m 1G | zfs recv -Fvu tank/${virt_type}/${vm}
zfs set readonly=on tank/${vm}
$cmd_ssh zfs snap -r tank/${vm}@m1
$cmd_ssh "zfs send -R -P -i tank/${virt_type}/${vm}@m0 tank/${vm}@m1 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -vu tank/${virt_type}/${vm}

######## STOP ##########
$cmd_ssh "$VAR_f_kvm_check_state; f_kvm_check_state"
######## STOP ##########

$cmd_ssh zfs snap -r tank/${vm}@m2
$cmd_ssh zfs send -R -P -i tank/${vm}@m1 tank/${vm}@m2 | zfs recv -vu tank/${vm}

# remove readonly property
#zfs inherit readonly tank/${virt_type}/${vm}
#
# mount dataset if virt type is lxc
#if [ $virt_type = lxc ];
#    then
#       zfs mount tank/lxc/${vm}
#fi


echo "Do not forget to change readonly property!"
echo "zfs inherit readonly tank/${virt_type}/${vm}"
