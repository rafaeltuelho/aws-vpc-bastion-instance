output "peering_connection_id" {
  description = "VPC peering connection ID."
  value       = aws_vpc_peering_connection.this.id
}

output "remote_dns_resolution" {
  description = "Whether remote VPC DNS resolution is enabled on the peering (needs DNS support and hostnames on both VPCs)."
  value       = local.remote_dns
}

output "client_cidrs" {
  description = "Client-side CIDRs routed and allowed on the cluster side."
  value       = local.client_cidrs
}

output "cluster_vpc_cidrs" {
  description = "Cluster VPC CIDRs routed from the client side."
  value       = local.cluster_vpc_cidrs
}

output "client_route_table_ids" {
  description = "Client VPC route tables that got routes."
  value       = local.client_route_table_ids
}

output "cluster_route_table_ids" {
  description = "Cluster VPC route tables that got routes."
  value       = local.cluster_route_table_ids
}

output "prefix_list_entries" {
  description = "Entries added to the cluster's prefix lists, as prefix list ID => CIDRs."
  value = {
    for pl in var.cluster_prefix_list_ids : pl => sort([for e in aws_ec2_managed_prefix_list_entry.client : e.cidr if e.prefix_list_id == pl])
  }
}

output "security_group_rule_ids" {
  description = "Inbound rules added to the cluster's security groups, as \"sg|port|cidr\" => rule ID."
  value       = { for k, r in aws_vpc_security_group_ingress_rule.client : k => r.security_group_rule_id }
}

output "private_zone_associations" {
  description = "Private hosted zones associated with the client VPC, as zone ID => zone name."
  value       = { for id, a in aws_route53_zone_association.client : id => data.aws_route53_zone.cluster[id].name }
}
