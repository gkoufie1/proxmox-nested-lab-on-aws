#!/usr/bin/env bash
# Tools the L1 host needs at boot:
#   ansible         - builds the nested cluster from the bundle in S3
#   AWS CLI v2      - fetches the bundle and the root password
#   apt-cacher-ng   - one package download shared by all nested nodes
#   corosync-qnetd  - QDevice tie-breaker for the even-sized cluster
#   SSM agent       - the only way in (no SSH, no open ports); Debian AMIs
#                     don't ship it and Debian doesn't package it
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ansible unzip jq apt-cacher-ng corosync-qnetd

tmp=$(mktemp -d)
curl -fsSL -o "${tmp}/awscliv2.zip" https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
"${tmp}/aws/install" --update
curl -fsSL -o "${tmp}/amazon-ssm-agent.deb" \
  https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i "${tmp}/amazon-ssm-agent.deb"
rm -rf "${tmp}"

systemctl enable apt-cacher-ng corosync-qnetd amazon-ssm-agent
# The build instance has no instance profile, so the agent never registered;
# stop it so the image carries no half-initialised state.
systemctl stop amazon-ssm-agent

# Make the next launch look like a fresh instance (new SSH host keys, user data
# runs) and drop the build instance's NIC-specific network config; the
# catch-all in 99-ec2-dhcp.network (l1-prep.sh) brings the NIC up instead.
apt-get clean
rm -f /etc/netplan/50-cloud-init.yaml /etc/network/interfaces.d/50-cloud-init
cloud-init clean --logs
