# Bakes the L1 AMI: Debian 13 + Proxmox VE 9 + bootstrap tools.
# Build once (and again when you want newer packages):
#   packer init . && packer build .
# The build runs on a cheap t3 instance; nested virtualization is only needed
# at run time. If the Proxmox kernel cannot boot on EC2, this build fails at
# the post-reboot reconnect, long before you pay for an r8i.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# Builds run on Spot: they need no nested virtualization, cost less, and use the
# Spot vCPU quota, so a build can run while an on-demand lab holds the
# on-demand quota. Several types so one short pool doesn't block the build.
variable "build_instance_types" {
  type    = list(string)
  default = ["t3.medium", "t3a.medium", "m7i.large", "m6i.large"]
}

locals {
  stamp = formatdate("YYYYMMDD-hhmm", timestamp())
  sudo  = "chmod +x '{{ .Path }}'; sudo -E env {{ .Vars }} bash '{{ .Path }}'"
}

source "amazon-ebs" "proxmox_l1" {
  region              = var.region
  spot_instance_types = var.build_instance_types
  spot_price          = "auto"
  ami_name            = "proxmox-ve9-l1-${local.stamp}"
  ssh_username        = "admin"

  # Don't ship Packer's temporary public key in the image
  ssh_clear_authorized_keys = true

  # Store the image's snapshot encrypted at rest with the account's default
  # EBS key (aws/ebs): no extra cost, and the AMI stays usable in this account.
  encrypt_boot = true

  # Uses the default VPC; SSH is opened only to your current public IP
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  source_ami_filter {
    filters = {
      name                = "debian-13-amd64-*"
      architecture        = "x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["136693071363"] # Debian
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 16
    volume_type           = "gp3"
    delete_on_termination = true
  }

  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name      = "proxmox-ve9-l1"
    Project   = "proxmox-lab"
    ManagedBy = "packer"
    BaseAMI   = "{{ .SourceAMIName }}"
  }
}

build {
  sources = ["source.amazon-ebs.proxmox_l1"]

  provisioner "shell" {
    execute_command = local.sudo
    script          = "${path.root}/scripts/l1-prep.sh"
  }

  provisioner "shell" {
    execute_command  = local.sudo
    environment_vars = ["PHASE=kernel"]
    script           = "${path.root}/../ansible/files/pve-install.sh"
  }

  provisioner "shell" {
    inline            = ["sudo systemctl reboot"]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before     = "60s"
    execute_command  = local.sudo
    environment_vars = ["PHASE=pve"]
    script           = "${path.root}/../ansible/files/pve-install.sh"
  }

  provisioner "shell" {
    execute_command = local.sudo
    script          = "${path.root}/scripts/l1-tools.sh"
  }
}
