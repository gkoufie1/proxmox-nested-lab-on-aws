# Talos VMs on the L1 host. They boot the Talos ISO with a cloud-init drive
# for their static address, sit in maintenance mode until talos.tf applies
# their config, install to scsi0, and reboot from disk.

locals {
  nodes = merge(
    { for name, n in var.controlplanes : name => merge(n, var.controlplane_size, { role = "controlplane" }) },
    { for name, n in var.workers : name => merge(n, var.worker_size, { role = "worker" }) },
  )
}

# Image Factory build of Talos with the QEMU guest agent, so Proxmox can see
# the VMs' addresses and shut them down cleanly.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
}

resource "proxmox_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = var.proxmox_node
  url          = data.talos_image_factory_urls.this.urls.iso
  file_name    = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}-nocloud-amd64.iso"
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = ["kubernetes", each.value.role]
  on_boot   = true

  # The guest agent only runs once Talos is installed; don't block on it.
  agent {
    enabled = true
    timeout = "1s"
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_gb
    file_format  = "raw"
    iothread     = true
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_download_file.talos_iso.id
    interface = "ide2"
  }

  # Empty disk on first boot falls through to the ISO; after install, boots from disk.
  boot_order = ["scsi0", "ide2"]

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_id
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.vm_datastore
    interface    = "ide0"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.dns_server]
    }
  }

  lifecycle {
    # Talos rewrites nothing here, but Proxmox reports the ISO detached
    # differently once installed; don't churn on it.
    ignore_changes = [cdrom]
  }
}
