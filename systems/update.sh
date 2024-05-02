#!/usr/bin/env bash

hostname=$1

ssh -tt "dragon@${hostname}.lan" 'bash -s' <<'ENDSSH'
ls -lah --color
ENDSSH
