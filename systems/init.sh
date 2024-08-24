#!/usr/bin/env bash

sudo -i
mkdir /root/.ssh
chmod 700 /root/.ssh
cd /root/.ssh || exit

curl -sf "https://github.com/dragoncrafted87.keys"
