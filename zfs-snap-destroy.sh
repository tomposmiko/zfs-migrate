#!/bin/bash

for dataset in `zfs list -t snap -r -H tank -o name |grep $1`;do
	echo $dataset
	zfs destroy $dataset
done
