#!/bin/bash


test -z $1 && { echo "No parameter set!"; exit 1; }

for i in :daily :weekly :monthly "";do
	property=com.sun:auto-snapshot
	echo ${property}${i}=true $1
	zfs set ${property}${i}=true $1
done

