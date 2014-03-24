#!/bin/bash

# TODO
# check for non-availability of existing VMs (virsh domstate |& lxc-info(?) or /etc/lxc/auto/${vm}.conf)
# 

f_check_switch_param(){
	if echo x"$1" |grep -q ^x-;then
		echo "Missing argument!"
		exit 1
	fi
}


f_check_kvm_state() {
	SHUTDOWN_MAXWAIT=600
	echo "Waiting for $SHUTDOWN_MAXWAIT seconds."
	for sec in `seq $SHUTDOWN_MAXWAIT`;do
		echo -n "$sec "

		if `virsh domstate ${vm} | head -1 | grep -q "shut off"`;
			then
				echo "${vm}: successfully shut down"
				exit 0
			else
				sleep 1
		fi

	done
	echo "${vm}: wasn't able to shut down"
	exit 1
}
# make available to subshells and child processes
export -f f_check_kvm_state


f_usage(){
	echo "Usage:"
	echo
	echo "Destination host (local):"
	echo "	zpull -t lxc|kvm -s HOST -n VM [--up]"
	echo
	echo "	   -t|--virt lxc|kvm		   virtualization type: LXC or KVM"
	echo "	   -s|--source HOST			source host to pull VM from"
	echo "	   -n|--vm|--name VM		   VM name"
	echo "	   --start source|dest		 keep running source VM or start on destination (default: leave both VM stopped)"
	echo
	echo "Source host (remote):"
	echo "	zpull --check-kvm-state VM	 check if KVM up or down"
	echo
}


# Exit if no arguments!
let $# || { f_usage; exit 1; }

while [ "$#" -gt "0" ]; do
  case "$1" in
	-t|--virt)
		PARAM=$2
		f_check_switch_param $PARAM
		virt_type="$PARAM"
		shift 2
	;;

	-s|--source)
		PARAM=$2
		f_check_switch_param $PARAM
		s_host=$PARAM
		shift 2
	;;

	-n|--vm|--name)
		PARAM=$2
		f_check_switch_param $PARAM
		vm=$PARAM
		shift 2
	;;

	--check-kvm-state)
		PARAM=$2
		f_check_switch_param $PARAM
		vm=$PARAM
		f_check_kvm_state 
		shift 2
	;;

	--start)
		PARAM=$2
		f_check_switch_param $PARAM
		VM_START=$PARAM
		shift 2
	;;

	-h|--help|*)
		f_usage
		exit 0
	;;
  esac
done

# check for virt type
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

c_ssh="ssh -c arcfour $s_host"
c_mbuffer_send="mbuffer -q -v 0 -s 128k -m 1G"
c_mbuffer_recv="mbuffer -s 128k -m 1G"


# check for remote zfs dataset
if ! $c_ssh "zfs list tank/${virt_type}/${vm} >/dev/null 2>&1";
	then
		echo "No dataset on source server: tank/${virt_type}/${vm} !"
		exit 1
fi

# check for local zfs dataset
if zfs list tank/${virt_type}/${vm} >/dev/null 2>&1;
	then
		echo "Dataset exists on destination server: tank/${virt_type}/${vm}"
		exit 1
fi

# check for kvm availability
if [ $virt_type = kvm ]; then
	$c_ssh "virsh domstate $vm >/dev/null 2>&1" || { echo "No such VM: ${vm}"; exit 1; }
fi


# m0
echo "############# Phase0: full #############"
echo
$c_ssh zfs destroy -r tank/${virt_type}/${vm}@m0%m2
$c_ssh zfs snap -r tank/${virt_type}/${vm}@m0
$c_ssh "zfs send -R -P -v tank/${virt_type}/${vm}@m0 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -Fvu tank/${virt_type}/${vm}
echo
echo

# without ro flag increment send won't work
zfs set readonly=on tank/${virt_type}/${vm}

# m1
echo "############# Phase1: First increment #############"
echo
$c_ssh zfs snap -r tank/${virt_type}/${vm}@m1
$c_ssh "zfs send -R -P -i tank/${virt_type}/${vm}@m0 tank/${virt_type}/${vm}@m1 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -vu tank/${virt_type}/${vm}
echo
echo

######## STOP ##########
if [ x$VM_START = "xdest" -o  x$VM_START = "x" ];
	then
		echo "############# Shutting down VM #############"
		if [ $virt_type = kvm ];
			then
				$c_ssh virsh shutdown ${vm}
				$c_ssh /root/bin/zpull.sh --check-kvm-state ${vm}
			else
				$c_ssh lxc-stop -n ${vm}
		fi
	else
		echo "############# *** NOT *** shutting down source VM #############"
fi
######## STOP ##########

echo "############# Phase2: Second increment #############"
echo
$c_ssh zfs snap -r tank/${virt_type}/${vm}@m2
$c_ssh "zfs send -R -P -i tank/${virt_type}/${vm}@m1 tank/${virt_type}/${vm}@m2 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -vu tank/${virt_type}/${vm}
echo
echo

echo "############# Finalizing #############"
# remove readonly property
zfs inherit readonly tank/${virt_type}/${vm}

# mount dataset if virt type is lxc
if [ $virt_type = lxc ];
	then
	   zfs mount tank/lxc/${vm}
fi
echo
echo

if [ $virt_type = lxc ];
	then
	apparmor_profile=`awk '/^lxc.aa_profile/ { print $3 }' /tank/lxc/${vm}/config`
	if echo $apparmor_profile |grep -q "lxc-";
	 then
		echo "apparmor profile: $apparmor_profile"
		$c_ssh cat /etc/apparmor.d/lxc/$apparmor_profile > /etc/apparmor.d/lxc/$apparmor_profile
		/etc/init.d/apparmor restart
	 else
		echo "No apparmor profile defines"
	fi
fi

# start destination VM
if [ x$VM_START = "xdest" ];
	then
		echo "############# Starting destination VM #############"
		if [ $virt_type = kvm ];
			then
				virsh start ${vm}
				virsh autostart ${vm}
				$c_ssh virsh autostart --disable ${vm}
			else
				lxc-start -d -n ${vm}
				#ln -s /tank/${virt_type}/${vm}/config /etc/lxc/auto/${vm}.conf
				sed -i 's@#lxc.start.auto@lxc.start.auto@' /tank/${virt_type}/${vm}/config
				$c_ssh sed -i 's@lxc.start.auto@#lxc.start.auto@' /tank/${virt_type}/${vm}/config
		fi
	else
		echo "############# *** NOT *** starting destination VM #############"
fi
