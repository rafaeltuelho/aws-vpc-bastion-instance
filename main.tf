# SSH bastion inside the VPC of a Redpanda BYOC cluster on AWS.
#
# Create:  terraform init && terraform apply -var cluster_id=<id> -var key_name=<key>
# Remove:  terraform destroy -var cluster_id=<id> -var key_name=<key>
#
# See README.md for usage and troubleshooting.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  bastion_name = "${var.owner}-bastion-${var.cluster_id}"
  vpc_id       = coalesce(var.vpc_id, one(data.aws_instance.agent[*].vpc_id))
  ssh_cidr     = coalesce(var.ssh_cidr, "${chomp(one(data.http.my_ip[*].response_body))}/32")
  tags = {
    Name             = local.bastion_name
    redpanda-cluster = var.cluster_id
  }
}

# The BYOC agent instance is tagged Name=redpanda-<cluster_id>; its VPC is the
# cluster VPC. Skipped when vpc_id is set (e.g. to destroy after the cluster
# is gone).
data "aws_instance" "agent" {
  count = var.vpc_id == null ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["redpanda-${var.cluster_id}"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

data "http" "my_ip" {
  count = var.ssh_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Canonical's Ubuntu images; the newest match wins.
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true
  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "bastion" {
  name        = "${local.bastion_name}-ssh"
  description = "SSH to ${local.bastion_name}"
  vpc_id      = local.vpc_id
  tags        = merge(local.tags, { Name = "${local.bastion_name}-ssh" })

  ingress {
    description = "ssh from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }

  # Terraform drops AWS's default allow-all egress rule, so add it back:
  # the bastion needs apt, GitHub (rpk) and the brokers.
  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = sort(data.aws_subnets.public.ids)[0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  tags                        = local.tags

  user_data = templatefile("${path.module}/user-data.sh", {
    apt_mirror = var.apt_mirror
    rpk_url    = var.rpk_url
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.public.ids) > 0
      error_message = "No public subnet (map-public-ip-on-launch=true) in ${local.vpc_id}."
    }
    # A newer AMI must not replace a running bastion.
    ignore_changes = [ami]
  }
}
