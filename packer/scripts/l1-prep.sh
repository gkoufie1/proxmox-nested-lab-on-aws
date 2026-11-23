#!/usr/bin/env bash
# Prepare the Debian 13 AMI to become the Proxmox L1 host.
# Proxmox needs a stable hostname that resolves to the node's real IP, but on
# EC2 the private IP changes every launch. So: fix the hostname, stop
# cloud-init managing it, and rewrite /etc/hosts from IMDS on every boot
# before pve-cluster starts.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl

hostnamectl set-hostname pve-l1

cat > /etc/cloud/cloud.cfg.d/99-proxmox.cfg <<'EOF'
preserve_hostname: true
manage_etc_hosts: false
EOF

cat > /usr/local/sbin/pve-hosts-fix <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
ip=$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
${ip} pve-l1.lab.internal pve-l1
::1 localhost ip6-localhost ip6-loopback
HOSTS
EOF
chmod 0755 /usr/local/sbin/pve-hosts-fix

cat > /etc/systemd/system/pve-hosts-fix.service <<'EOF'
[Unit]
Description=Point the Proxmox hostname at this instance's private IP
Wants=network-online.target
After=network-online.target
Before=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-hosts-fix

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pve-hosts-fix.service
hostname --ip-address
