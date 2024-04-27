#!/usr/bin/env bash

# shellcheck disable=SC2317

exit

# direct console as root to setup ssh
mkdir --mode=700 /root/.ssh
curl -sf https://github.com/dragoncrafted87.keys > /root/.ssh/authorized_keys

# get HW MAC address
ip a | grep -v lo | grep ether
