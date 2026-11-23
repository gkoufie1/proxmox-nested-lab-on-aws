# Architecture

## Layers

| Layer | What | Where |
|---|---|---|
| L0 | AWS Nitro hypervisor | AWS |
| L1 | Proxmox VE 9 on an r8i.4xlarge with nested virtualization enabled | `packer/`, `terraform/` |
| L2 | 16 Proxmox VE 9 VMs forming cluster `lab16` | `ansible/roles/nested_nodes`, `pve_node`, `pve_cluster` |
| L3 | Guests on the nested cluster (LXC works; KVM untested, see Limits) | roadmap |

## Boot sequence

1. `terraform apply` zips `ansible/`, uploads it to S3, stores a random root password in SSM, and launches the instance from the newest `proxmox-ve9-l1-*` AMI through a one-shot EC2 Fleet that can use any AZ offering the type.
2. User data schedules `shutdown -h +TTL` first. Shutdown behavior is `terminate`, so the cost cap holds even if everything after it fails.
3. User data then downloads the bundle and runs `ansible-playbook site.yml` locally:
   1. **l1_host**: checks VT-x is exposed, creates vmbr1 plus the VLAN gateways and NAT, builds a ZFS pool `tank` on the EBS data volume (ARC capped at 4 GiB), and starts apt-cacher-ng and qnetd.
   2. **nested_nodes**: builds a Debian 13 cloud-image template, makes 16 linked clones with 4 NICs each, and addresses them with cloud-init.
   3. **pve_node** (parallel): installs Proxmox VE with the same script Packer used, writes `/etc/hosts`, disables cloud-init, sets the root password, and exchanges SSH keys.
   4. **pve_cluster** (`serial: 1`): `pvecm create` on pve01, then `pvecm add` on each other node in turn.
   5. **qdevice**: `pvecm qdevice setup` against qnetd on the L1 host.
   6. **ceph** (optional): MONs on nodes 1–5, MGRs on 1–3, an OSD per node, and the `vm-pool` RBD storage.
4. The log is `/var/log/lab-bootstrap.log`. `/opt/lab/READY` or `/opt/lab/FAILED` marks the result.

## Network

| VLAN | Name | Subnet | Node NIC | Purpose |
|---|---|---|---|---|
| 10 | mgmt | 10.10.10.0/24 | ens18 | UI/API, SSH, default route via 10.10.10.1, corosync link1 |
| 20 | corosync | 10.10.20.0/24 | ens19 | Corosync link0, isolated from bulk traffic |
| 30 | ceph | 10.10.30.0/24 | ens20 | Ceph public + cluster (one network in the lab) |
| 40 | k8s | 10.10.40.0/24 | ens21 (trunk → vmbr0) | Guest VLAN for Kubernetes VMs |
| 50 | services | 10.10.50.0/24 | ens21 (trunk → vmbr0) | Guest VLAN for services |

Node *n* is `pve0n`, VMID `100+n`, with host address `10+n` on VLANs 10/20/30.
The L1 host is `.1` everywhere, routes between the VLANs, and NATs `10.10.0.0/16`
out of its ENI. DNS is the VPC resolver (`10.200.0.2`). Nested guests are blocked
from IMDS twice: hop limit 1 and an iptables `FORWARD` drop.

In a physical build, vmbr1 becomes the managed switch and the L1 routing moves
to a firewall such as OPNsense. The VLAN plan stays the same.

## Decisions

**Nested on one instance, not 16 instances.** One instance is about 10× cheaper
than 16 instances with their EBS, and builds faster. The cost of that choice:
HA and Ceph failures are simulated, because one host failing takes out every
node. That's acceptable for learning the control plane, fencing and quorum.

**r8i.4xlarge.** AWS documents nested virtualization on C8i/M8i/R8i only. Each
node gets 6 GiB, so 16 nodes need 96 GiB plus about 12 GiB of host overhead,
which fits 128 GiB. vCPUs are overcommitted 2:1, which is fine for a control-plane lab.
Terraform's precondition refuses sizes that don't fit.

**Ansible runs on the instance.** This removes the Windows control-node problem,
SSH exposure and ProxyJump chains. It's also how the whole build becomes "apply and wait".

**Debian cloud image + install script, not the Proxmox ISO.** EC2 can't boot an
ISO. Reusing one script for the AMI and the nodes keeps one code path to debug.

**QDevice for 16 nodes.** An even vote count can split 8/8 with no quorum on
either side. qnetd sits outside the cluster, on the L1 host. On real hardware it
belongs on a separate small machine.

**On-demand, not Spot.** On 2026-11-23, Spot requests with nested
virtualization failed in every us-east-1 AZ, while plain Spot and on-demand with
nested virtualization launched in the same AZ minutes apart. On-demand
r8i.4xlarge is $1.11/h, about 3× Spot, so the TTL does more of the cost work.
`use_spot` stays as an option to retry later.

**One-shot EC2 Fleet, not `aws_instance`.** The fleet lists a subnet in every
AZ that offers the type and launches wherever there's capacity, failing in
seconds if there's none. A single `aws_instance` pinned to one AZ retried
capacity errors for 15+ minutes.

**Self-terminating TTL over Lambda/EventBridge reapers.** Fewer moving parts, and
it can't be skipped by a failed bootstrap. The trade-off is that Terraform
doesn't notice when the TTL fires: run `terraform destroy` before the next
`apply` (or `apply -replace=aws_ec2_fleet.l1`).

## Limits and things to verify on first run

These parts are written but haven't been run end to end yet. Check them in this order:

1. ~~**Proxmox kernel on EC2.**~~ **Verified 2026-11-23:** the AMI build boots
   Proxmox kernel 7.0.14-pve on Nitro (t3) and installs PVE 9.2.32. The first
   attempt failed only because Proxmox's `grub-pc` asked for an install disk;
   `pve-install.sh` now preseeds it. The first r8i launch then came up with
   **no network**: the NIC is `enp39s0` there but `ens5` on the t3 build
   instance, and the image only had config for the latter. The image now
   DHCPs any `en*` NIC via systemd-networkd and ships the SSM agent (Debian
   AMIs don't); verified on an m8i.large, which names its NIC the same way.
2. ~~**Nested virtualization at launch.**~~ **Verified 2026-11-23:** an
   on-demand r8i.4xlarge launches with `NestedVirtualization: enabled`.
3. **Spot + nested virtualization.** Not available when tested (see Decisions).
   Retry with `use_spot = true` occasionally; the fleet fails fast if it still isn't.
4. **Guest NIC names.** The roles assume `ens18`–`ens21` (i440fx + virtio). Check with `ip -br link` on pve01.
5. **L3 KVM.** VMs *inside* the nested nodes need a third level of
   virtualization. L1 exposes `vmx` to L2 (`--cpu host`), but performance and
   stability on EC2 are unknown. LXC containers on the nested nodes need no virtualization.
6. **Ceph sizing.** 16 OSDs on 6 GiB nodes run with `osd_memory_target` at 1 GiB, so expect slow recovery.

## Roadmap

- **Phase 2: Kubernetes.** Talos VMs on VLAN 40 (Terraform `bpg/proxmox` +
  `siderolabs/talos`), Cilium with BGP to the L1 router (FRR), and Ceph RBD CSI.
  If L3 KVM proves unusable, run the Talos VMs on L1 directly.
- **Phase 3: GitOps.** Argo CD bootstrapped from this repo, plus kube-prometheus-stack.
- **Phase 4: Backup / DR.** Proxmox Backup Server as an L2 VM with an S3
  datastore, and a restore drill with measured RTO/RPO.
- **Phase 5: CI.** GitHub Actions running `terraform fmt/validate`,
  `packer validate`, `ansible-lint` and `shellcheck` on every PR.
