# --- The two VPCs (same account and region) ----------------------------------

variable "aws_region" {
  description = "Region of both VPCs."
  type        = string
  default     = "us-east-2"
}

variable "client_vpc_id" {
  description = "VPC of the clients, e.g. the bastion VPC (the bastion module's vpc_id output). Requester side of the peering."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.client_vpc_id))
    error_message = "client_vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "cluster_vpc_id" {
  description = "VPC hosting the Redpanda/Kafka cluster. Accepter side of the peering. CHANGES THIS VPC: accepts the peering and adds routes to its route tables."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.cluster_vpc_id))
    error_message = "cluster_vpc_id must look like vpc-0123456789abcdef0."
  }
  validation {
    condition     = var.cluster_vpc_id != var.client_vpc_id
    error_message = "cluster_vpc_id must differ from client_vpc_id."
  }
}

variable "name" {
  description = "Name tag for the peering connection and the other tagged resources. Default: <client_vpc_id>-to-<cluster_vpc_id>."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags for the resources that support tags."
  type        = map(string)
  default     = {}
}

# --- Routes -------------------------------------------------------------------

variable "client_cidrs" {
  description = "Client-side CIDRs the cluster side should reach and allow (routes, prefix list entries, security group rules). Unset: all CIDR blocks of the client VPC. Narrow it, e.g. to the bastion subnet, to keep the cluster-side changes minimal."
  type        = list(string)
  default     = null

  validation {
    condition     = var.client_cidrs == null || try(length(var.client_cidrs) > 0 && alltrue([for c in var.client_cidrs : can(cidrhost(c, 0)) && strcontains(c, "/")]), false)
    error_message = "client_cidrs must be a non-empty list of IPv4 CIDRs, e.g. [\"10.255.0.0/24\"]."
  }
}

variable "client_route_table_ids" {
  description = "Client VPC route tables that get routes to the cluster VPC. Unset: all route tables of the client VPC."
  type        = list(string)
  default     = null

  validation {
    condition     = alltrue([for id in(var.client_route_table_ids == null ? [] : var.client_route_table_ids) : can(regex("^rtb-[0-9a-f]+$", id))])
    error_message = "client_route_table_ids must be route table IDs like rtb-0123456789abcdef0."
  }
}

variable "cluster_route_table_ids" {
  description = "Cluster VPC route tables that get routes back to client_cidrs. Unset: all route tables of the cluster VPC. CHANGES THE CLUSTER VPC either way; set it only to narrow the change."
  type        = list(string)
  default     = null

  validation {
    condition     = alltrue([for id in(var.cluster_route_table_ids == null ? [] : var.cluster_route_table_ids) : can(regex("^rtb-[0-9a-f]+$", id))])
    error_message = "cluster_route_table_ids must be route table IDs like rtb-0123456789abcdef0."
  }
}

# --- Optional: access through the cluster's firewall --------------------------

variable "cluster_prefix_list_ids" {
  description = "Customer-managed prefix lists that the cluster's security groups reference. client_cidrs are added as entries. Preferred over cluster_security_group_ids: the cluster project keeps owning its rules. CHANGES THE PREFIX LISTS."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.cluster_prefix_list_ids : can(regex("^pl-[0-9a-f]+$", id))])
    error_message = "cluster_prefix_list_ids must be prefix list IDs like pl-0123456789abcdef0."
  }
}

variable "cluster_security_group_ids" {
  description = "Cluster security groups (brokers or Kubernetes nodes) that get inbound rules from client_cidrs on cluster_ports. CHANGES THE CLUSTER VPC. Conflicts with a project that defines these groups' rules inline."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.cluster_security_group_ids : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "cluster_security_group_ids must be security group IDs like sg-0123456789abcdef0."
  }
}

variable "cluster_ports" {
  description = "TCP ports opened in cluster_security_group_ids. Default: Kafka API, Redpanda Admin API, Schema Registry, HTTP Proxy. Use the NodePorts for a Kubernetes deployment."
  type        = list(number)
  default     = [9092, 9644, 8081, 8082]

  validation {
    condition     = length(var.cluster_ports) > 0 && alltrue([for p in var.cluster_ports : p >= 1 && p <= 65535 && floor(p) == p])
    error_message = "cluster_ports must be a non-empty list of TCP ports (1-65535)."
  }
}

# --- Optional: DNS --------------------------------------------------------------

variable "private_zone_ids" {
  description = "Route 53 private hosted zones (same account) to associate with the client VPC, so their records (e.g. broker names) resolve there. CHANGES THE ZONES. Conflicts with a project that defines the zone's VPCs inline."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.private_zone_ids : can(regex("^Z[A-Z0-9]+$", id))])
    error_message = "private_zone_ids must be hosted zone IDs like Z0123456789ABCDEFGHIJ (without the /hostedzone/ prefix)."
  }
}
