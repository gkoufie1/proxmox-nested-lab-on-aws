variable "proxmox_endpoint" {
  type    = string
  default = "https://127.0.0.1:8006/"
}

variable "proxmox_password" {
  description = "root@pam password (the lab root password from SSM)."
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node the Kubernetes VMs run on: the L1 host (see docs, Phase 2)."
  type        = string
  default     = "pve-l1"
}

variable "vm_datastore" {
  type    = string
  default = "tank"
}

variable "iso_datastore" {
  type    = string
  default = "local"
}

variable "bridge" {
  type    = string
  default = "vmbr1"
}

variable "vlan_id" {
  description = "The lab's k8s VLAN (10.10.40.0/24)."
  type        = number
  default     = 40
}

variable "gateway" {
  type    = string
  default = "10.10.40.1"
}

variable "dns_server" {
  description = "VPC resolver, reached through the L1 host's NAT."
  type        = string
  default     = "10.200.0.2"
}

variable "talos_version" {
  type    = string
  default = "v1.14.6"
}

variable "cluster_name" {
  type    = string
  default = "lab-k8s"
}

variable "endpoint_ip" {
  description = "Floating Kubernetes API address, held by one control-plane node at a time (Talos VIP)."
  type        = string
  default     = "10.10.40.10"
}

variable "controlplanes" {
  type = map(object({ vm_id = number, ip = string }))
  default = {
    k8s-cp1 = { vm_id = 4011, ip = "10.10.40.11" }
    k8s-cp2 = { vm_id = 4012, ip = "10.10.40.12" }
    k8s-cp3 = { vm_id = 4013, ip = "10.10.40.13" }
  }
}

variable "workers" {
  type = map(object({ vm_id = number, ip = string }))
  default = {
    k8s-w1 = { vm_id = 4021, ip = "10.10.40.21" }
    k8s-w2 = { vm_id = 4022, ip = "10.10.40.22" }
    k8s-w3 = { vm_id = 4023, ip = "10.10.40.23" }
  }
}

variable "controlplane_size" {
  type    = object({ cores = number, memory_mb = number, disk_gb = number })
  default = { cores = 2, memory_mb = 3072, disk_gb = 20 }
}

variable "worker_size" {
  type    = object({ cores = number, memory_mb = number, disk_gb = number })
  default = { cores = 2, memory_mb = 4096, disk_gb = 30 }
}
