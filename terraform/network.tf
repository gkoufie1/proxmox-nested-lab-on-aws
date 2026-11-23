# One public subnet so the instance can reach SSM, S3 and package mirrors
# without a NAT gateway (~$33/month). Nothing can reach in: the security group
# has no ingress rules, and all access goes through SSM Session Manager.

data "aws_ec2_instance_type_offerings" "l1" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

# One subnet per AZ that offers the instance type; the EC2 Fleet in main.tf
# launches into whichever has capacity. Spot capacity for large types moves
# between AZs minute to minute, so pinning one AZ is unreliable.
locals {
  azs = var.availability_zone != null ? [var.availability_zone] : sort(data.aws_ec2_instance_type_offerings.l1.locations)
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  for_each = toset(local.azs)

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 10 + index(local.azs, each.key))
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "l1" {
  name_prefix = "${var.project}-l1-"
  description = "Proxmox L1 host: no inbound, all access via SSM"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Package mirrors, SSM, S3"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}
