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
    .\scripts\lab.ps1 kubeconfig # save the Kubernetes kubeconfig to ~\.kube\proxmox-lab.yaml
    .\scripts\lab.ps1 k8s        # tunnel the Kubernetes API to https://127.0.0.1:6443
                                 # then, in another window:
                                 #   $env:KUBECONFIG = "$HOME\.kube\proxmox-lab.yaml"; kubectl get nodes
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'gui', 'gui-l1', 'shell', 'password', 'kubeconfig', 'k8s')]
    [string]$Command
)
$ErrorActionPreference = 'Stop'

$tfDir = Join-Path $PSScriptRoot '..\terraform'
$out = terraform "-chdir=$tfDir" output -json | ConvertFrom-Json
if (-not $out.instance_id) { throw 'No Terraform outputs - run terraform apply first.' }
$id = $out.instance_id.value
$region = $out.region.value
# Use the same AWS CLI profile Terraform used, so commands hit the lab's account
if ($out.aws_profile.value) { $env:AWS_PROFILE = $out.aws_profile.value }

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
    'kubeconfig' {
        # Read the kubeconfig the kubernetes role wrote on the L1 host, and point
        # it at the local end of the `k8s` tunnel (127.0.0.1 is in the API cert).
        $cid = aws ssm send-command --region $region --instance-ids $id `
            --document-name AWS-RunShellScript --parameters 'commands=cat /root/.kube/config' `
            --query Command.CommandId --output text
        do {
            Start-Sleep -Seconds 2
            $inv = aws ssm get-command-invocation --region $region --command-id $cid --instance-id $id --output json 2>$null |
                ConvertFrom-Json
        } while (-not $inv -or $inv.Status -in 'Pending', 'InProgress', 'Delayed')
        if ($inv.Status -ne 'Success' -or -not $inv.StandardOutputContent) {
            throw "Could not read the kubeconfig ($($inv.Status)). Is the cluster built? Try: .\scripts\lab.ps1 status"
        }
        $kubeconfig = $inv.StandardOutputContent -replace 'https://10\.10\.40\.10:6443', 'https://127.0.0.1:6443'
        $dest = Join-Path $HOME '.kube\proxmox-lab.yaml'
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        [IO.File]::WriteAllText($dest, $kubeconfig) # UTF-8 without BOM, which kubectl expects
        Write-Host "Saved $dest"
        Write-Host 'Next: .\scripts\lab.ps1 k8s   (leave it running), then in another window:'
        Write-Host "  `$env:KUBECONFIG = `"$dest`"; kubectl get nodes"
    }
    'k8s' {
        Write-Host 'Kubernetes API on https://127.0.0.1:6443. Ctrl+C to stop.'
        aws ssm start-session --target $id --region $region `
            --document-name AWS-StartPortForwardingSessionToRemoteHost `
            --parameters 'host=10.10.40.10,portNumber=6443,localPortNumber=6443'
    }
}
