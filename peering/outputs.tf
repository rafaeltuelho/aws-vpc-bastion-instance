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
