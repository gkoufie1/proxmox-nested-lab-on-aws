variable "project" {
  description = "Name prefix and Project tag for every resource."
  type        = string
  default     = "proxmox-lab"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  description = "Pin the lab to one AZ. Null (recommended) lets the fleet pick any AZ that offers instance_type and has capacity."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "Must not overlap the nested lab's 10.10.0.0/16."
  type        = string
  default     = "10.200.0.0/16"
}

# --- L1 host -------------------------------------------------------------

variable "instance_type" {
  description = "Must support nested virtualization (AWS documents C8i, M8i, R8i and their flex variants)."
  type        = string
  default     = "r8i.4xlarge" # 16 vCPU, 128 GiB

  validation {
    condition     = can(regex("^[cmr]8i(-flex)?\\.", var.instance_type))
    error_message = "Use a C8i/M8i/R8i (or -flex) type; relax this check if AWS has added nested virtualization to your chosen family."
  }
}

variable "use_spot" {
  description = "Use Spot (~3x cheaper, reclaimable). Off by default: on 2026-11-23 AWS had no Spot capacity with nested virtualization in any us-east-1 AZ."
  type        = bool
  default     = false
}

variable "ttl_hours" {
  description = "The instance shuts itself down (and terminates) after this many hours, whatever happens."
  type        = number
  default     = 4

  validation {
    condition     = var.ttl_hours >= 1 && var.ttl_hours <= 12
    error_message = "ttl_hours must be between 1 and 12."
  }
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "data_volume_gb" {
  description = "EBS volume that becomes the ZFS pool for the nested nodes' disks (thin-provisioned)."
  type        = number
  default     = 250
}

# --- Nested cluster ------------------------------------------------------

variable "node_count" {
  type    = number
  default = 16

  validation {
    condition     = var.node_count >= 3 && var.node_count <= 32
    error_message = "node_count must be between 3 and 32."
  }
}

variable "node_cores" {
  type    = number
  default = 2
}

variable "node_memory_mb" {
  description = "RAM per nested node. 4096 is enough without Ceph; use 6144 with it."
  type        = number
  default     = 6144
}

variable "cluster_name" {
  type    = string
  default = "lab16"
}

variable "enable_qdevice" {
  description = "Add a corosync QDevice on the L1 host (only applied when node_count is even)."
  type        = bool
  default     = true
}

variable "enable_ceph" {
  description = "Deploy Ceph (5 monitors, 3 managers, one OSD per node). Adds roughly 10 minutes."
  type        = bool
  default     = false
}

# --- Cost guardrail ------------------------------------------------------

variable "create_budget" {
  description = "Create a monthly AWS Budget. Leave false if your account already has one."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  type    = number
  default = 20
}

variable "budget_email" {
  description = "Where budget alerts go (required when create_budget = true)."
  type        = string
  default     = ""
}
