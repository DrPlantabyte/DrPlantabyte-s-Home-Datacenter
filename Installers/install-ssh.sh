#!/bin/bash
set -exo pipefail
cd "$(dirname "$0")"
sudo apt install openssh-server openssh-sftp-server
sudo install -o root -g root ./ssh/sshd_config /etc/ssh/sshd_config
sudo service sshd restart


