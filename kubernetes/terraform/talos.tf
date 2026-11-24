# Talos machine configuration, bootstrap and kubeconfig.

locals {
  cp_ips      = [for name, n in var.controlplanes : n.ip]
  worker_ips  = [for name, n in var.workers : n.ip]
  first_cp_ip = local.cp_ips[0]

  common_patch = {
    machine = {
      install = {
        disk  = "/dev/sda"
        image = data.talos_image_factory_urls.this.urls.installer
      }
    }
    cluster = {
      apiServer = {
        # 127.0.0.1: reached from your PC through an SSM port forward
        certSANs = [var.endpoint_ip, "127.0.0.1", "localhost"]
      }
    }
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "this" {
  for_each = toset(["controlplane", "worker"])

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.endpoint_ip}:6443"
  machine_type     = each.key
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
  config_patches   = [yamlencode(local.common_patch)]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips
  nodes                = concat(local.cp_ips, local.worker_ips)
}

# Per-node: hostname, static address, and (control planes) the shared VIP.
resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.value.role].machine_configuration
  node                        = each.value.ip

  config_patches = [yamlencode({
    machine = {
      network = {
        hostname = each.key
        interfaces = [merge(
          {
            deviceSelector = { physical = true }
            addresses      = ["${each.value.ip}/24"]
            routes         = [{ network = "0.0.0.0/0", gateway = var.gateway }]
          },
          each.value.role == "controlplane" ? { vip = { ip = var.endpoint_ip } } : {},
        )]
        nameservers = [var.dns_server]
      }
    }
  })]

  depends_on = [proxmox_virtual_environment_vm.node]
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_cp_ip

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_cp_ip

  depends_on = [talos_machine_bootstrap.this]
}

# Block until etcd, the API server and every node report healthy.
data "talos_cluster_health" "this" {
  client_configuration = data.talos_client_configuration.this.client_configuration
  control_plane_nodes  = local.cp_ips
  worker_nodes         = local.worker_ips
  endpoints            = local.cp_ips

  timeouts = {
    read = "20m"
  }

  depends_on = [talos_cluster_kubeconfig.this]
}
