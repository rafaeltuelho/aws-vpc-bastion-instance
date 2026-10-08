# --- Required -----------------------------------------------------------------

variable "key_name" {
  description = "Name of an existing EC2 key pair in aws_region."
  type        = string
}

variable "owner" {
  description = "Prefix for resource names, e.g. your username."
  type        = string
}

variable "aws_region" {
  description = "Region of the bastion (and of the peer VPC, if any)."
  type        = string
  default     = "us-east-2"
}

# --- Bastion VPC: set exactly one of create_vpc, vpc_id or redpanda_cluster_id

variable "create_vpc" {
  description = "Create a new VPC (vpc_cidr) with one public subnet for the bastion."
  type        = bool
  default     = false

  validation {
    condition     = var.create_vpc || var.vpc_id != null || var.redpanda_cluster_id != null
    error_message = "Choose the bastion VPC: create_vpc = true, vpc_id = \"vpc-...\", or redpanda_cluster_id = \"...\" (BYOC cluster VPC)."
  }
  validation {
    condition     = !(var.create_vpc && var.vpc_id != null)
    error_message = "Set either create_vpc = true or vpc_id, not both."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the new VPC when create_vpc = true. Must not overlap the peer VPC."
  type        = string
  default     = "10.255.0.0/24"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 28, false)
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /28, e.g. 10.255.0.0/24."
  }
}

variable "vpc_id" {
  description = "Existing VPC to deploy into. Needs a public subnet. No Redpanda cluster is needed."
  type        = string
  default     = null

  validation {
    condition     = var.vpc_id == null || can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "redpanda_cluster_id" {
  description = "Redpanda BYOC cluster ID (Redpanda Cloud console). Alone: deploy into the cluster VPC. With create_vpc: peer the new VPC with the cluster VPC unless peer_vpc_id is set. Also used in names and tags."
  type        = string
  default     = null
}

# --- Peering (same account and region) ----------------------------------------

variable "peer_vpc_id" {
  description = "VPC to peer the bastion VPC with, typically the one hosting the Redpanda/Kafka cluster."
  type        = string
  default     = null

  validation {
    condition     = var.peer_vpc_id == null || can(regex("^vpc-[0-9a-f]+$", var.peer_vpc_id))
    error_message = "peer_vpc_id must look like vpc-0123456789abcdef0."
  }
  validation {
    condition     = var.peer_vpc_id == null || var.peer_vpc_id != var.vpc_id
    error_message = "peer_vpc_id must differ from vpc_id."
  }
}

variable "peer_route_table_ids" {
  description = "Peer VPC route tables that get a route back to the bastion subnet. Unset: all route tables of the peer VPC."
  type        = list(string)
  default     = null

  validation {
    condition     = var.peer_route_table_ids == null || alltrue([for id in(var.peer_route_table_ids == null ? [] : var.peer_route_table_ids) : can(regex("^rtb-[0-9a-f]+$", id))])
    error_message = "peer_route_table_ids must be route table IDs like rtb-0123456789abcdef0."
  }
  validation {
    condition     = var.peer_route_table_ids == null || var.peer_vpc_id != null || (var.create_vpc && var.redpanda_cluster_id != null)
    error_message = "peer_route_table_ids needs peering: set peer_vpc_id (or create_vpc with redpanda_cluster_id)."
  }
}

variable "peer_security_group_ids" {
  description = "Broker security groups in the peer VPC to open to the bastion's private IP on peer_ports. Empty: none are changed."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.peer_security_group_ids : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "peer_security_group_ids must be security group IDs like sg-0123456789abcdef0."
  }
  validation {
    condition     = length(var.peer_security_group_ids) == 0 || var.peer_vpc_id != null || (var.create_vpc && var.redpanda_cluster_id != null)
    error_message = "peer_security_group_ids needs peering: set peer_vpc_id (or create_vpc with redpanda_cluster_id)."
  }
}

variable "peer_ports" {
  description = "TCP ports opened in peer_security_group_ids. Default: Kafka API, Redpanda Admin API, Schema Registry, HTTP Proxy."
  type        = list(number)
  default     = [9092, 9644, 8081, 8082]

  validation {
    condition     = length(var.peer_ports) > 0 && alltrue([for p in var.peer_ports : p >= 1 && p <= 65535 && floor(p) == p])
    error_message = "peer_ports must be a non-empty list of TCP ports (1-65535)."
  }
}

variable "peer_private_zone_ids" {
  description = "Route 53 private hosted zone IDs (same account) to associate with the bastion VPC, so their records (e.g. broker names) resolve there."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.peer_private_zone_ids : can(regex("^Z[A-Z0-9]+$", id))])
    error_message = "peer_private_zone_ids must be hosted zone IDs like Z0123456789ABCDEFGHIJ (without the /hostedzone/ prefix)."
  }
}

# --- Bastion instance ---------------------------------------------------------

variable "instance_type" {
  description = "Bastion instance type (x86_64)."
  type        = string
  default     = "t3.medium"
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH in. Defaults to your current public IP /32."
  type        = string
  default     = null

  validation {
    condition     = var.ssh_cidr == null || can(cidrhost(var.ssh_cidr, 0))
    error_message = "ssh_cidr must be a valid CIDR, e.g. 203.0.113.10/32."
  }
}

variable "ami_name_pattern" {
  description = "Ubuntu AMI name pattern (x86_64)."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-*-24.04-amd64-server-*"
}

variable "apt_mirror" {
  description = "Override the apt mirror, e.g. http://archive.ubuntu.com/ubuntu/ if the regional EC2 mirror returns 503."
  type        = string
  default     = ""
}

variable "rpk_url" {
  description = "Download URL of the rpk zip."
  type        = string
  default     = "https://github.com/redpanda-data/redpanda/releases/latest/download/rpk-linux-amd64.zip"
}
