output "instance_id" {
  value = aws_instance.l1.id
}

output "region" {
  value = var.region
}

output "availability_zone" {
  value = local.az
}

output "pve01_ip" {
  value = "10.10.10.11"
}

output "root_password_param" {
  value = aws_ssm_parameter.root_password.name
}

output "next_steps" {
  value = <<-EOT
    The instance terminates itself ${var.ttl_hours}h after boot.
    Watch the build:   .\scripts\lab.ps1 status
    Open the cluster:  .\scripts\lab.ps1 gui       -> https://localhost:8006 (root / PAM)
    Root password:     .\scripts\lab.ps1 password
    Tear down:         terraform -chdir=terraform destroy
  EOT
}
