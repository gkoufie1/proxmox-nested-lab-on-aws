data "aws_ami" "l1" {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "name"
    values = ["proxmox-ve9-l1-*"]
  }
}

data "aws_ec2_instance_type" "l1" {
  instance_type = var.instance_type
}

locals {
  # Nested nodes + ~8 GiB for the L1 host itself + the 4 GiB ZFS ARC cap
  lab_memory_mb = var.node_count * var.node_memory_mb + 12288
}

# --- Bundle: the Ansible tree the instance runs at boot -----------------

resource "aws_s3_bucket" "bundle" {
  bucket_prefix = "${var.project}-bundle-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "archive_file" "bundle" {
  type        = "zip"
  source_dir  = "${path.module}/../ansible"
  output_path = "${path.module}/.build/bundle.zip"
}

resource "aws_s3_object" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  key    = "bundle.zip"
  source = data.archive_file.bundle.output_path
  etag   = data.archive_file.bundle.output_md5
}

# --- Root password for the Proxmox web UI (PAM realm) -------------------
# The value also sits in local Terraform state; keep the state file private.

resource "random_password" "root" {
  length           = 24
  override_special = "-_"
}

resource "aws_ssm_parameter" "root_password" {
  name  = "/${var.project}/root-password"
  type  = "SecureString"
  value = random_password.root.result
}

# --- IAM: SSM access + read the bundle and the password -----------------

resource "aws_iam_role" "l1" {
  name_prefix = "${var.project}-l1-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.l1.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bootstrap" {
  name = "bootstrap"
  role = aws_iam_role.l1.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.bundle.arn}/${aws_s3_object.bundle.key}"
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.root_password.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "l1" {
  name_prefix = "${var.project}-l1-"
  role        = aws_iam_role.l1.name
}

# --- L1 host --------------------------------------------------------------

resource "aws_launch_template" "l1" {
  name_prefix   = "${var.project}-l1-"
  image_id      = data.aws_ami.l1.id
  instance_type = var.instance_type

  # `shutdown` from inside (the TTL timer) terminates the instance and deletes its volumes
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    arn = aws_iam_instance_profile.l1.arn
  }

  vpc_security_group_ids = [aws_security_group.l1.id]

  cpu_options {
    core_count            = data.aws_ec2_instance_type.l1.default_cores
    threads_per_core      = data.aws_ec2_instance_type.l1.default_threads_per_core
    nested_virtualization = "enabled"
  }

  # Hop limit 1 keeps the instance role's credentials away from nested guests
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  block_device_mappings {
    device_name = data.aws_ami.l1.root_device_name
    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_size           = var.data_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region      = var.region
    bucket      = aws_s3_bucket.bundle.id
    bundle_key  = aws_s3_object.bundle.key
    bundle_md5  = data.archive_file.bundle.output_md5
    ttl_minutes = var.ttl_hours * 60
    vars_json = jsonencode({
      aws_region          = var.region
      root_password_param = aws_ssm_parameter.root_password.name
      vpc_dns             = cidrhost(var.vpc_cidr, 2)
      node_count          = var.node_count
      node_cores          = var.node_cores
      node_memory_mb      = var.node_memory_mb
      cluster_name        = var.cluster_name
      enable_qdevice      = var.enable_qdevice
      enable_ceph         = var.enable_ceph
    })
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-l1" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.project}-l1" }
  }
}

resource "aws_instance" "l1" {
  subnet_id = aws_subnet.public.id

  launch_template {
    id      = aws_launch_template.l1.id
    version = aws_launch_template.l1.latest_version
  }

  lifecycle {
    precondition {
      condition     = local.lab_memory_mb <= data.aws_ec2_instance_type.l1.memory_size
      error_message = "${var.node_count} nodes x ${var.node_memory_mb} MiB (+12 GiB host overhead) = ${local.lab_memory_mb} MiB exceeds ${var.instance_type}'s ${data.aws_ec2_instance_type.l1.memory_size} MiB. Lower node_count/node_memory_mb or pick a bigger type."
    }
  }

  depends_on = [aws_iam_role_policy.bootstrap, aws_route_table_association.public]
}
