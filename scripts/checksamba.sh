#!/bin/bash

systemctl status systemd-cryptsetup@nasvault.service --no-pager

echo
echo

df -h /mnt/timemachine/phi /mnt/timemachine/cs

echo
echo

echo Phi
du -sh /mnt/timemachine/phi/Martin's\ MacBook\ Pro.sparsebundle

echo

echo CS
du -sh /mnt/timemachine/cs/mharris-mac.sparsebundle
