# Connectivity layer between a client VPC (e.g. the bastion's) and a cluster
# VPC (Redpanda or Kafka): VPC peering, routes in both directions, and,
# optionally, access to the cluster through prefix lists or security groups
# and private DNS zones. Same account and region.
#
# Its own root module and state, so neither the bastion nor the cluster
# project references the other. See README.md.
#
# Create:  terraform init && terraform apply
# Remove:  terraform destroy (before destroying either VPC)

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name = coalesce(var.name, "${var.client_vpc_id}-to-${var.cluster_vpc_id}")
  tags = merge(var.tags, { Name = local.name })

  # All associated IPv4 CIDR blocks, including secondary ones (e.g. EKS pod
  # ranges).
  client_vpc_cidrs  = [for a in data.aws_vpc.client.cidr_block_associations : a.cidr_block if a.state == "associated"]
  cluster_vpc_cidrs = [for a in data.aws_vpc.cluster.cidr_block_associations : a.cidr_block if a.state == "associated"]

  # Sources allowed on the cluster side: all client VPC CIDRs unless narrowed.
  client_cidrs = var.client_cidrs != null ? var.client_cidrs : local.client_vpc_cidrs

  client_route_table_ids  = var.client_route_table_ids != null ? var.client_route_table_ids : flatten(data.aws_route_tables.client[*].ids)
  cluster_route_table_ids = var.cluster_route_table_ids != null ? var.cluster_route_table_ids : flatten(data.aws_route_tables.cluster[*].ids)

  # One route per (route table, destination CIDR).
  client_routes = {
    for p in setproduct(local.client_route_table_ids, local.cluster_vpc_cidrs) : "${p[0]}|${p[1]}" => { rtb = p[0], cidr = p[1] }
  }
  cluster_routes = {
    for p in setproduct(local.cluster_route_table_ids, local.client_cidrs) : "${p[0]}|${p[1]}" => { rtb = p[0], cidr = p[1] }
  }

  # Two CIDRs overlap when their network addresses match at the shorter prefix.
  cidr_overlaps = [
    for p in setproduct(local.client_vpc_cidrs, local.cluster_vpc_cidrs) : "${p[0]} and ${p[1]}"
    if cidrhost("${split("/", p[0])[0]}/${min(split("/", p[0])[1], split("/", p[1])[1])}", 0) ==
    cidrhost("${split("/", p[1])[0]}/${min(split("/", p[0])[1], split("/", p[1])[1])}", 0)
  ]

  # client_cidrs entries that aren't inside any client VPC CIDR.
  client_cidrs_outside_vpc = [
    for c in local.client_cidrs : c
    if !anytrue([
      for v in local.client_vpc_cidrs :
      tonumber(split("/", c)[1]) >= tonumber(split("/", v)[1]) &&
      cidrhost("${split("/", c)[0]}/${split("/", v)[1]}", 0) == cidrhost(v, 0)
    ])
  ]

  # Remote DNS resolution needs DNS support and hostnames on both VPCs.
  remote_dns = alltrue([
    for v in [data.aws_vpc.client, data.aws_vpc.cluster] : v.enable_dns_support && v.enable_dns_hostnames
  ])
}

data "aws_vpc" "client" {
  id = var.client_vpc_id
}

data "aws_vpc" "cluster" {
  id = var.cluster_vpc_id
}

data "aws_route_tables" "client" {
  count  = var.client_route_table_ids == null ? 1 : 0
  vpc_id = var.client_vpc_id
}

data "aws_route_tables" "cluster" {
  count  = var.cluster_route_table_ids == null ? 1 : 0
  vpc_id = var.cluster_vpc_id
}

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.client_vpc_id
  peer_vpc_id = var.cluster_vpc_id
  auto_accept = true
  tags        = local.tags

  requester {
    allow_remote_vpc_dns_resolution = local.remote_dns
  }
  accepter {
    allow_remote_vpc_dns_resolution = local.remote_dns
  }

  lifecycle {
    precondition {
      condition     = length(local.cidr_overlaps) == 0
      error_message = "VPC CIDRs overlap, so they cannot be peered: ${join(", ", local.cidr_overlaps)}."
    }
    precondition {
      condition     = length(local.client_cidrs_outside_vpc) == 0
      error_message = "client_cidrs must be inside the client VPC (${join(", ", local.client_vpc_cidrs)}): ${join(", ", local.client_cidrs_outside_vpc)}."
    }
  }
}

# Client route tables -> every CIDR block of the cluster VPC.
resource "aws_route" "client_to_cluster" {
  for_each                  = local.client_routes
  route_table_id            = each.value.rtb
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Cluster route tables -> client_cidrs.
resource "aws_route" "cluster_to_client" {
  for_each                  = local.cluster_routes
  route_table_id            = each.value.rtb
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# --- Optional: let the clients through the cluster's firewall ---------------

data "aws_ec2_managed_prefix_list" "cluster" {
  for_each = toset(var.cluster_prefix_list_ids)
  id       = each.key
}

# Preferred: the cluster's security group rules reference a prefix list, and
# this module only adds entries to it.
resource "aws_ec2_managed_prefix_list_entry" "client" {
  for_each = {
    for p in setproduct(var.cluster_prefix_list_ids, local.client_cidrs) : "${p[0]}|${p[1]}" => { pl = p[0], cidr = p[1] }
  }
  prefix_list_id = each.value.pl
  cidr           = each.value.cidr
  description    = local.name

  lifecycle {
    precondition {
      condition     = data.aws_ec2_managed_prefix_list.cluster[each.value.pl].owner_id != "AWS"
      error_message = "Prefix list ${each.value.pl} is AWS-managed; only customer-managed prefix lists can take entries."
    }
    precondition {
      condition     = data.aws_ec2_managed_prefix_list.cluster[each.value.pl].address_family == "IPv4"
      error_message = "Prefix list ${each.value.pl} is not an IPv4 prefix list."
    }
    precondition {
      condition = (
        length(data.aws_ec2_managed_prefix_list.cluster[each.value.pl].entries) +
        length(setsubtract(local.client_cidrs, [for e in data.aws_ec2_managed_prefix_list.cluster[each.value.pl].entries : e.cidr]))
      ) <= data.aws_ec2_managed_prefix_list.cluster[each.value.pl].max_entries
      error_message = "Prefix list ${each.value.pl} has no room for ${length(local.client_cidrs)} more entries (max_entries = ${data.aws_ec2_managed_prefix_list.cluster[each.value.pl].max_entries})."
    }
  }
}

data "aws_security_group" "cluster" {
  for_each = toset(var.cluster_security_group_ids)
  id       = each.key
}

# Alternative: add rules directly to the cluster's security groups.
resource "aws_vpc_security_group_ingress_rule" "client" {
  for_each = {
    for p in setproduct(var.cluster_security_group_ids, var.cluster_ports, local.client_cidrs) :
    "${p[0]}|${p[1]}|${p[2]}" => { sg = p[0], port = p[1], cidr = p[2] }
  }
  security_group_id = each.value.sg
  description       = "${each.value.port}/tcp from ${local.name}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  tags              = local.tags

  lifecycle {
    precondition {
      condition     = data.aws_security_group.cluster[each.value.sg].vpc_id == var.cluster_vpc_id
      error_message = "Security group ${each.value.sg} is not in the cluster VPC (${var.cluster_vpc_id})."
    }
  }
}

# --- Optional: resolve the cluster's private DNS names from the client VPC --

data "aws_route53_zone" "cluster" {
  for_each = toset(var.private_zone_ids)
  zone_id  = each.key
}

resource "aws_route53_zone_association" "client" {
  for_each = toset(var.private_zone_ids)
  zone_id  = each.key
  vpc_id   = var.client_vpc_id

  lifecycle {
    precondition {
      condition     = data.aws_route53_zone.cluster[each.key].private_zone
      error_message = "Hosted zone ${each.key} (${data.aws_route53_zone.cluster[each.key].name}) is public; only private zones can be associated."
    }
  }
}
