# Optional VPC peering between the bastion VPC and the cluster VPC
# (peer_vpc_id, or the BYOC cluster VPC when create_vpc and redpanda_cluster_id
# are set), plus the routes, broker security group rules and private DNS
# zones that make the cluster reachable from the bastion. Same account and
# region only.

locals {
  peering     = var.peer_vpc_id != null || (var.create_vpc && var.redpanda_cluster_id != null)
  peer_vpc_id = var.peer_vpc_id != null ? var.peer_vpc_id : local.agent_vpc_id

  # All associated IPv4 CIDR blocks, including secondary ones (e.g. EKS pod
  # ranges).
  peer_cidrs = flatten([for v in data.aws_vpc.peer : [
    for a in v.cidr_block_associations : a.cidr_block if a.state == "associated"
  ]])
  bastion_vpc_cidrs = var.create_vpc ? [var.vpc_cidr] : flatten([for v in data.aws_vpc.bastion : [
    for a in v.cidr_block_associations : a.cidr_block if a.state == "associated"
  ]])

  # Return traffic only needs to reach the bastion subnet.
  bastion_subnet_cidr = var.create_vpc ? var.vpc_cidr : one(data.aws_subnet.bastion[*].cidr_block)

  # The bastion subnet's explicit route table, or else the VPC main table.
  bastion_route_table_id = var.create_vpc ? one(aws_route_table.bastion[*].id) : try(coalesce(
    try(one(data.aws_route_tables.bastion_subnet[0].ids), null),
    try(one(data.aws_route_tables.bastion_main[0].ids), null),
  ), null)

  peer_route_table_ids = var.peer_route_table_ids != null ? var.peer_route_table_ids : flatten(data.aws_route_tables.peer[*].ids)

  # Two CIDRs overlap when their network addresses match at the shorter prefix.
  cidr_overlaps = [
    for p in setproduct(local.bastion_vpc_cidrs, local.peer_cidrs) : "${p[0]} and ${p[1]}"
    if cidrhost("${split("/", p[0])[0]}/${min(split("/", p[0])[1], split("/", p[1])[1])}", 0) ==
    cidrhost("${split("/", p[1])[0]}/${min(split("/", p[0])[1], split("/", p[1])[1])}", 0)
  ]

  # Remote DNS resolution needs DNS support and hostnames on both VPCs.
  remote_dns = local.peering && alltrue([
    for v in concat(data.aws_vpc.peer, data.aws_vpc.bastion) : v.enable_dns_support && v.enable_dns_hostnames
  ])
}

data "aws_vpc" "peer" {
  count = local.peering ? 1 : 0
  id    = local.peer_vpc_id
}

data "aws_vpc" "bastion" {
  count = local.peering && !var.create_vpc ? 1 : 0
  id    = local.vpc_id
}

data "aws_subnet" "bastion" {
  count = local.peering && !var.create_vpc ? 1 : 0
  id    = local.subnet_id
}

data "aws_route_tables" "bastion_subnet" {
  count  = local.peering && !var.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  filter {
    name   = "association.subnet-id"
    values = [local.subnet_id]
  }
}

data "aws_route_tables" "bastion_main" {
  count  = local.peering && !var.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

data "aws_route_tables" "peer" {
  count  = local.peering && var.peer_route_table_ids == null ? 1 : 0
  vpc_id = local.peer_vpc_id
}

resource "aws_vpc_peering_connection" "bastion" {
  count       = local.peering ? 1 : 0
  vpc_id      = local.vpc_id
  peer_vpc_id = local.peer_vpc_id
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
      condition     = local.vpc_id != local.peer_vpc_id
      error_message = "peer_vpc_id is the bastion's own VPC (${local.vpc_id}); peer with a different VPC."
    }
    precondition {
      condition     = length(local.cidr_overlaps) == 0
      error_message = "VPC CIDRs overlap, so they cannot be peered: ${join(", ", local.cidr_overlaps)}. With create_vpc, pick a vpc_cidr outside the peer VPC's ranges."
    }
  }
}

# Bastion -> every CIDR block of the peer VPC.
resource "aws_route" "bastion_to_peer" {
  for_each                  = toset(local.peer_cidrs)
  route_table_id            = local.bastion_route_table_id
  destination_cidr_block    = each.key
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion[0].id
}

# Peer route tables -> bastion subnet.
resource "aws_route" "peer_to_bastion" {
  for_each                  = local.peering ? toset(local.peer_route_table_ids) : toset([])
  route_table_id            = each.key
  destination_cidr_block    = local.bastion_subnet_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion[0].id
}

data "aws_security_group" "peer" {
  for_each = toset(var.peer_security_group_ids)
  id       = each.key
}

# Broker security groups: allow peer_ports from the bastion's private IP.
resource "aws_vpc_security_group_ingress_rule" "peer_from_bastion" {
  for_each = {
    for p in setproduct(var.peer_security_group_ids, var.peer_ports) : "${p[0]}:${p[1]}" => { sg = p[0], port = p[1] }
  }
  security_group_id = each.value.sg
  description       = "${each.value.port}/tcp from ${local.bastion_name}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${aws_instance.bastion.private_ip}/32"
  tags              = local.tags

  lifecycle {
    precondition {
      condition     = data.aws_security_group.peer[each.value.sg].vpc_id == local.peer_vpc_id
      error_message = "Security group ${each.value.sg} is not in the peer VPC (${local.peer_vpc_id})."
    }
  }
}

data "aws_route53_zone" "peer" {
  for_each = toset(var.peer_private_zone_ids)
  zone_id  = each.key
}

# Private hosted zones (e.g. broker names like redpanda-0.redpanda.internal)
# made resolvable from the bastion VPC.
resource "aws_route53_zone_association" "bastion" {
  for_each = toset(var.peer_private_zone_ids)
  zone_id  = each.key
  vpc_id   = local.vpc_id

  lifecycle {
    precondition {
      condition     = data.aws_route53_zone.peer[each.key].private_zone
      error_message = "Hosted zone ${each.key} (${data.aws_route53_zone.peer[each.key].name}) is public; only private zones can be associated."
    }
  }
}
