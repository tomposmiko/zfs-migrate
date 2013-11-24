#!/bin/bash

check_switch_param(){
	if echo x"$PARAM" |grep -q ^x-;then
		echo "Missing parameter!"
		exit 1
	fi
}


f_kvm_check-state() {

	SHUTDOWN_MAXWAIT=600
	for sec in {1..$SHUTDOWN_MAXWAIT};do
		echo -n $sec

		if `virsh domstate ${vm}|head -1|grep -q "shut off"`;
		 then
			echo "${vm}: shut down"
			exit 1
			
		fi

		echo "${vm}: cannot be shut down"
	done
}

usage(){
	echo "Usage:"
	echo "zpull -t lxc|kvm -n VM"
	echo "   -t|--virt lxc|kvm"
	echo "   -n|--vm|--name VM"
	echo
}


while [ "$#" -gt "0" ]; do
  case "$1" in
	-t|--virt)
		$PARAM=$2
		check_switch_param
		VIRT_TYPE="$PARAM"
		shift 2
	;;
	-n|--vm|--name)
		Force="yes"
		shift 1
	;;
	-h|--help|*)
		usage
	;;
  esac
done


if [ x$VIRT_TYPE != x"lxc" -a x$VIRT_TYPE != x"kvm" ];
	then
	 echo "Invalid or no virtualization type: "$VIRT_TYPE""
fi


s_host="v301"
vm=$1
cmd_ssh="ssh -c blowfish $s_host"
c_mbuffer_send="mbuffer -q -v 0 -s 128k -m 1G"
c_mbuffer_recv="mbuffer -s 128k -m 1G"

$cmd_ssh zfs snap -r tank/${vm}@m0
$cmd_ssh "zfs send -R -P tank/${vm}@m0 | mbuffer -q -v 0 -s 128k -m 1G" | mbuffer -s 128k -m 1G | zfs recv -Fvu tank/${vm}
zfs set readonly=on tank/${vm}
$cmd_ssh zfs snap -r tank/${vm}@m1
$cmd_ssh "zfs send -R -P -i tank/${vm}@m0 tank/${vm}@m1 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -vu tank/${vm}

######## STOP ##########

######## STOP ##########

#$cmd_ssh zfs snap -r tank/${vm}@m2
#$cmd_ssh zfs send -R -P -i tank/${vm}@m1 tank/${vm}@m2 | zfs recv -vu tank/${vm}

zfs inherit readonly tank/${vm}
