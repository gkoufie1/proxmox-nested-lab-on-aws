#!/usr/bin/env bash
# Install Proxmox VE 9 on top of Debian 13 (trixie), following
# https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
#
# Shared by Packer (bakes the L1 AMI) and Ansible (installs the nested nodes).
# Run twice, rebooting in between:
#   pve-install.sh kernel   # Proxmox repo + kernel
#   pve-install.sh pve      # proxmox-ve packages, remove the Debian kernels
# The phase can also come from $PHASE (Packer passes it that way).
# Precondition: the hostname resolves to a non-loopback IP in /etc/hosts.
set -euo pipefail

PHASE="${1:-${PHASE:-}}"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

. /etc/os-release
if [[ "${VERSION_CODENAME}" != "trixie" ]]; then
  echo "Expected Debian 13 (trixie), found ${VERSION_CODENAME}" >&2
  exit 1
fi

host_ip="$(hostname --ip-address | awk '{print $1}')"
case "${host_ip}" in
  127.*|"")
    echo "$(hostname) resolves to '${host_ip}'; Proxmox needs a non-loopback IP in /etc/hosts" >&2
    exit 1 ;;
esac

case "${PHASE}" in
  kernel)
    apt-get update
    apt-get install "${APT_OPTS[@]}" ca-certificates curl
    curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
      https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
    cat > /etc/apt/sources.list.d/pve-install-repo.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    apt-get update
    apt-get full-upgrade "${APT_OPTS[@]}"
    apt-get install "${APT_OPTS[@]}" proxmox-default-kernel
    echo "Proxmox kernel installed. Reboot, then run: $0 pve"
    ;;

  pve)
    if ! uname -r | grep -q pve; then
      echo "Not running a Proxmox kernel ($(uname -r)); reboot after the kernel phase" >&2
      exit 1
    fi
    echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
    echo "postfix postfix/mailname string $(hostname --fqdn)" | debconf-set-selections
    apt-get install "${APT_OPTS[@]}" proxmox-ve postfix open-iscsi chrony

    # Remove the stock Debian kernels (generic and cloud flavours)
    mapfile -t old_kernels < <(
      dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'linux-image-*' 2>/dev/null \
        | awk '$2 == "installed" && $1 !~ /pve|proxmox/ {print $1}')
    if ((${#old_kernels[@]})); then
      apt-get remove "${APT_OPTS[@]}" "${old_kernels[@]}"
    fi
    update-grub
    apt-get remove "${APT_OPTS[@]}" os-prober || true

    # No subscription: drop the enterprise repos the packages add (they 401 without a key)
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.list
    apt-get update
    pveversion
    ;;

  *)
    echo "usage: $0 kernel|pve" >&2
    exit 2 ;;
esac
