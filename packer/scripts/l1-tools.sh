#!/usr/bin/env bash
# Tools the L1 host needs at boot:
#   ansible         - builds the nested cluster from the bundle in S3
#   AWS CLI v2      - fetches the bundle and the root password
#   apt-cacher-ng   - one package download shared by all nested nodes
#   corosync-qnetd  - QDevice tie-breaker for the even-sized cluster
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ansible unzip jq apt-cacher-ng corosync-qnetd

tmp=$(mktemp -d)
curl -fsSL -o "${tmp}/awscliv2.zip" https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
"${tmp}/aws/install" --update
rm -rf "${tmp}"

systemctl enable apt-cacher-ng corosync-qnetd

# Make the next launch look like a fresh instance (new SSH host keys, user data runs)
apt-get clean
cloud-init clean --logs
