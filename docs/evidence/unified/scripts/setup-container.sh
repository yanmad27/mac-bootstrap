#!/usr/bin/env bash
# Creates the disposable debian:12 container `mb-sshd` (openssh-server, curl, iproute2; sshd on 127.0.0.1:2222; users tuser and other)
# used by run_handoff.py. Remove it afterwards with: docker rm -f mb-sshd
set -e
docker rm -f mb-sshd >/dev/null 2>&1 || true
docker run -d --name mb-sshd -p 127.0.0.1:2222:22 debian:12 sleep infinity >/dev/null
docker exec mb-sshd bash -c 'apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server openssh-client curl iproute2 >/dev/null 2>&1; ssh-keygen -A >/dev/null; mkdir -p /run/sshd; useradd -m -s /bin/bash tuser; useradd -m -s /bin/bash other; /usr/sbin/sshd; ls /etc/ssh/ssh_host_ed25519_key.pub'
