#!/bin/bash


s_host="virt301"
vm=$1
cmd_ssh="ssh -c blowfish $s_host"



vm=foo
$cmd_ssh zfs snap -r tank/kvm/${vm}@m0
$cmd_ssh "zfs send -R -P tank/kvm/${vm}@m0 | mbuffer -q -v 0 -s 128k -m 1G" | mbuffer -s 128k -m 1G | zfs recv -Fvu tank/kvm/${vm}
zfs set readonly=on tank/kvm/${vm}
$cmd_ssh zfs snap -r tank/kvm/${vm}@m1
$cmd_ssh zfs send -R -P -i tank/kvm/${vm}@m0 tank/kvm/${vm}@m1 | zfs recv -vu tank/kvm/${vm}
zfs inherit readonly tank/kvm/${vm
