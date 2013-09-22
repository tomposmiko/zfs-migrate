#!/bin/bash

# TODO
# --init (like dirvish)
# --incremental (or that is the default?)
# iterate down
# when finished readonly=on for source and readonly=off on destination

SHUTDOWN_WAIT_TIME=600

s_host="virt103"
vm=$1
cmd_ssh="ssh -c blowfish $s_host"




if [ -z ${vm} ];then
	echo "No vm specified!"
	exit 1
fi

if [ -L /etc/lxc/auto/${vm}.conf ];then
	echo "${vm}: Autostart enabled, assuming vm is active on this node!"
	exit 1
fi



#$cmd_ssh $s_host "zfs snap -r tank/kvm/${vm}@migrate"
#$cmd_ssh $s_host "zfs send -P tank/kvm/${vm}@migrate" | zfs recv -v tank/kvm/${vm}
zfs create -o readonly=on tank/kvm/${vm}
$cmd_ssh zfs snap -r tank/kvm/${vm}@m0
$cmd_ssh zfs send -R -P tank/kvm/${vm}@m0 | zfs recv -Fvu tank/kvm/${vm} || exit 0
#zfs set readonly=on tank/kvm/${vm}

snapshot_last_name=$($cmd_ssh "zfs list -t snap -o name |grep ^tank/kvm/${vm}| tail -1")
snapshot_last_number=$(echo $snapshot_last_name| sed "s/.*@m//")
snapshot_next_number=$[$snapshot_last_number+1]

#$cmd_ssh "virsh shutdown ${vm};sec=0;until virsh domstate ${vm} |grep -q 'shut off';do sec=$[$sec+1]; echo -n $sec; if [ $sec -ge $SHUTDOWN_WAIT_TIME ];then virsh destroy ${vm};fi; sleep 1;done"
#sync
#sleep 7

$cmd_ssh zfs snap -r tank/kvm/${vm}@m${snapshot_next_number}
$cmd_ssh zfs send -R -P -i tank/kvm/${vm}@m${snapshot_last_number} tank/kvm/${vm}@m${snapshot_next_number} | zfs recv -vu tank/kvm/${vm}

