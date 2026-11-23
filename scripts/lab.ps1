<#
.SYNOPSIS
    Day-to-day helpers for the ephemeral Proxmox lab. Run from the repo root.
.DESCRIPTION
    All access goes through SSM Session Manager - no SSH keys, no open ports.
    Needs the AWS CLI v2 and the Session Manager plugin.
.EXAMPLE
    .\scripts\lab.ps1 status     # follow the bootstrap log until the cluster is ready
    .\scripts\lab.ps1 gui        # https://localhost:8006 -> pve01 (the nested cluster)
    .\scripts\lab.ps1 gui-l1     # https://localhost:8007 -> the L1 host
    .\scripts\lab.ps1 shell      # shell on the L1 host (then: sudo -i)
    .\scripts\lab.ps1 password   # root password for both UIs
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'gui', 'gui-l1', 'shell', 'password')]
    [string]$Command
)
$ErrorActionPreference = 'Stop'

$tfDir = Join-Path $PSScriptRoot '..\terraform'
$out = terraform "-chdir=$tfDir" output -json | ConvertFrom-Json
if (-not $out.instance_id) { throw 'No Terraform outputs - run terraform apply first.' }
$id = $out.instance_id.value
$region = $out.region.value

switch ($Command) {
    'status' {
        aws ssm start-session --target $id --region $region `
            --document-name AWS-StartInteractiveCommand `
            --parameters 'command=tail -n 50 -f /var/log/lab-bootstrap.log'
    }
    'gui' {
        Write-Host 'Open https://localhost:8006  (user: root, realm: Linux PAM). Ctrl+C to stop.'
        aws ssm start-session --target $id --region $region `
            --document-name AWS-StartPortForwardingSessionToRemoteHost `
            --parameters "host=$($out.pve01_ip.value),portNumber=8006,localPortNumber=8006"
    }
    'gui-l1' {
        Write-Host 'Open https://localhost:8007  (user: root, realm: Linux PAM). Ctrl+C to stop.'
        aws ssm start-session --target $id --region $region `
            --document-name AWS-StartPortForwardingSession `
            --parameters 'portNumber=8006,localPortNumber=8007'
    }
    'shell' {
        aws ssm start-session --target $id --region $region
    }
    'password' {
        aws ssm get-parameter --name $out.root_password_param.value --with-decryption `
            --query Parameter.Value --output text --region $region
    }
}
