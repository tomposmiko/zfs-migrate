#!/bin/bash


f_log(){
	date=`date "+%Y-%m-%d %T"`
	echo "$date $HOSTNAME: $*" >> $logfile;
}

tempfile=`mktemp /tmp/zpull.XXXX`

echo "CLI: $0 $*" >> $tempfile

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
		echo
		exit 1
fi

# check for source hostname
if [ x$s_host = x ];
	then
		echo "No source hostname set!"
		echo
		exit 1
	else
		ssh $s_host echo || { echo "Source host $s_host is not reachable!"; exit 1; }
fi

# check if VM name set
if [ x$vm = x ];
	then
		echo "No VM name set!"
		echo
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
	#$c_ssh "virsh domstate $vm >/dev/null 2>&1" || { echo "No such VM: ${vm}"; exit 1; }
	if $c_ssh "virsh domstate $vm >/dev/null 2>&1";
		then
			config_xml=`mktemp /tmp/config_vmxml.XXXX`
			$c_ssh "virsh dumpxml $vm > $config_xml"
			virsh define $config_xml
			rm -f $config_xml
		else
			echo "No such VM: ${vm}";
			exit 1;
	fi
fi

logfile=`mktemp /tmp/logfile.XXXX`

# m0
f_log "Starting Phase0: full"
unixtime_start=`date "+%s"`
echo "############# Phase0: full #############"
echo
$c_ssh zfs destroy -r tank/${virt_type}/${vm}@m0%m2
$c_ssh zfs snap -r tank/${virt_type}/${vm}@m0
$c_ssh "zfs send -R -P -v tank/${virt_type}/${vm}@m0 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -Fvu tank/${virt_type}/${vm}
echo
echo

# without the ro flag incremental send won't work
zfs set readonly=on tank/${virt_type}/${vm}

# m1
f_log "Starting Phase1: First increment"
echo "############# Phase1: First increment #############"
echo
$c_ssh zfs snap -r tank/${virt_type}/${vm}@m1
$c_ssh "zfs send -R -P -i tank/${virt_type}/${vm}@m0 tank/${virt_type}/${vm}@m1 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -vu tank/${virt_type}/${vm}
echo
echo

######## STOP ##########
if [ x$VM_START = "xdest" -o  x$VM_START = "x" ];
	then
		f_log "Shutting down VM"
		echo "############# Shutting down VM #############"
		if [ $virt_type = kvm ];
			then
				$c_ssh virsh shutdown ${vm}
				$c_ssh /root/bin/zpull.sh --check-kvm-state ${vm}
			else
				$c_ssh lxc-stop -n ${vm}
		fi
	else
		f_log "**** NOT **** SHUTTING DOWN source VM: $vm"
		echo "############# *** NOT *** shutting down source VM #############"
fi
######## STOP ##########

f_log "Starting Phase2: Second increment"
echo "############# Phase2: Second increment #############"
echo
$c_ssh zfs snap -r tank/${virt_type}/${vm}@m2
$c_ssh "zfs send -R -P -i tank/${virt_type}/${vm}@m1 tank/${virt_type}/${vm}@m2 | $c_mbuffer_send" | $c_mbuffer_recv | zfs recv -vu tank/${virt_type}/${vm}
echo
echo

unixtime_stop=`date "+%s"`
unixtime_interval_secs=$[${unixtime_stop}-${unixtime_start}]
#unixtime_interval_human=`date -d @${unixtime_interval_secs} +%T`
unixtime_interval_human=`printf %02d:%02d:%02d $((unixtime_interval_secs/3600)) $((unixtime_interval_secs%3600/60)) $((unixtime_interval_secs%60))`
echo "ZFS send/receive time: $unixtime_interval_human"
f_log "ZFS send/receive time: $unixtime_interval_human"


f_log "Finalizing"
echo "############# Finalizing #############"
# remove readonly property
zfs inherit readonly tank/${virt_type}/${vm}

# mount dataset if virt type is lxc
# not good enough, since all datasets have to be mounted recursively
if [ $virt_type = lxc ];
	then
		for fs in `zfs list -H tank/lxc/${vm} -r -o name`;do
			echo "Mounting filesystem: $fs"
			f_log "Mounting filesystem: $fs"
			zfs mount $fs
		done
fi
echo
echo



# container specific apparmor profile
if [ $virt_type = lxc ];
	then
	apparmor_profile=`awk '/^lxc.aa_profile/ { print $3 }' /tank/lxc/${vm}/config`
	if echo $apparmor_profile |grep -q "lxc-";
	 then
		f_log "Apparmor profile: $apparmor_profile"
		echo "Apparmor profile: $apparmor_profile"
		$c_ssh cat /etc/apparmor.d/lxc/$apparmor_profile > /etc/apparmor.d/lxc/$apparmor_profile
		/etc/init.d/apparmor restart
	 else
<<<<<<< Updated upstream
		f_log "No apparmor profile defined"
		echo "No apparmor profile defined."
=======
		echo "No apparmor profile defined"
>>>>>>> Stashed changes
	fi
fi

# start destination VM
if [ x$VM_START = "xdest" ];
	then
		f_log "Starting VM on destination host $HOSTNAME"
		echo "############# Starting VM on destination host $HOSTNAME #############"
		if [ $virt_type = kvm ];
			then
				$c_ssh virsh autostart --disable ${vm}
				virsh start ${vm}
				virsh autostart ${vm}
				state=`virsh domstate ${vm} | head -1`
				if [ "x$state" != "xrunning" ];
					then
						f_log "Libvirt VM state is not expected: **** $domstate ****"
						echo "Libvirt VM state is not expected: **** $domstate ****"
				fi
			else
				$c_ssh sed -i 's@lxc.start.auto@#lxc.start.auto@' /tank/${virt_type}/${vm}/config
				lxc-start -d -n ${vm}
				sed -i 's@#lxc.start.auto@lxc.start.auto@' /tank/${virt_type}/${vm}/config
				state=`lxc-info -n ${vm}|awk '/^State:/ { print $2 }'`
				if [ "x$state" != "xRUNNING" ];
					then
						f_log "LXC container state is not expected: **** $domstate ****"
						echo "LXC container state is not expected: **** $domstate ****"
				fi
		fi
	else
		f_log "**** NOT **** starting destination VM"
		echo "############# *** NOT *** starting destination VM #############"
fi

<<<<<<< Updated upstream
f_log "Do not forget to change the backup reference to **** $HOSTNAME ****"
cat $logfile |mail -s "${vm} migration from $s_host to $HOSTNAME" it@chemaxon.com
rm -f $logfile
=======
echo |mail -s "`hostname`: ${vm} migration done" root


rm -f $tempfile
>>>>>>> Stashed changes
