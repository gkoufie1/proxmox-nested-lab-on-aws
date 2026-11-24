output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "api_endpoint" {
  value = "https://${var.endpoint_ip}:6443"
}

output "health" {
  description = "Set once talos_cluster_health passed."
  value       = data.talos_cluster_health.this.id
}
