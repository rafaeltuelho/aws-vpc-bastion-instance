# SSH bastion with rpk and kcat for reaching a Redpanda or Kafka cluster on AWS.
#
# The bastion goes into a new VPC (create_vpc), an existing one (vpc_id), or
# the VPC of a Redpanda BYOC cluster (redpanda_cluster_id). Connecting it to a
# cluster in another VPC is the job of the separate peering/ root module.
# See README.md for every option.
#
# Create:  terraform init && terraform apply
# Remove:  terraform destroy (with the same variables)

terraform {
  required_version = ">= 1.9"
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
  bastion_name = "${var.owner}-bastion${try("-${coalesce(var.redpanda_cluster_id, var.vpc_id)}", "")}"
  ssh_cidr     = coalesce(var.ssh_cidr, "${chomp(one(data.http.my_ip[*].response_body))}/32")
  tags = merge(
    { Name = local.bastion_name },
    var.redpanda_cluster_id == null ? {} : { redpanda-cluster = var.redpanda_cluster_id },
  )

  vpc_id            = coalesce(one(aws_vpc.bastion[*].id), var.vpc_id, one(data.aws_instance.agent[*].vpc_id))
  public_subnet_ids = one(data.aws_subnets.public[*].ids)
  subnet_id         = var.create_vpc ? one(aws_subnet.bastion[*].id) : try(sort(local.public_subnet_ids)[0], null)
}

# The BYOC agent instance is tagged Name=redpanda-<cluster_id>; its VPC is the
# cluster VPC.
data "aws_instance" "agent" {
  count = var.redpanda_cluster_id != null ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["redpanda-${var.redpanda_cluster_id}"]
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

# Existing VPC: the bastion goes into its first public subnet.
data "aws_subnets" "public" {
  count = var.create_vpc ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Fails at plan time if key_name doesn't exist in aws_region.
data "aws_key_pair" "bastion" {
  key_name = var.key_name
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
  key_name                    = data.aws_key_pair.bastion.key_name
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  tags                        = local.tags

  user_data = templatefile("${path.module}/user-data.sh", {
    apt_mirror = var.apt_mirror
    rpk_url    = var.rpk_url
  })
  user_data_replace_on_change = true

  # In a new VPC, cloud-init needs the internet route before boot.
  depends_on = [aws_route.bastion_internet, aws_route_table_association.bastion]

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  lifecycle {
    precondition {
      condition     = local.subnet_id != null
      error_message = "No public subnet (map-public-ip-on-launch=true) in ${local.vpc_id}. Use another vpc_id, or create_vpc = true."
    }
    # A newer AMI must not replace a running bastion.
    ignore_changes = [ami]
  }
}
