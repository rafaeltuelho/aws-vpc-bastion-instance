# --- Required -----------------------------------------------------------------

variable "key_name" {
  description = "Name of an existing EC2 key pair in aws_region."
  type        = string
}

variable "owner" {
  description = "Prefix for resource names, e.g. your username. Letters, digits, '-' and '_' only."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$", var.owner))
    error_message = "owner must be 1-32 letters, digits, '-' or '_' (e.g. jdoe), not a placeholder like <your-name>."
  }
}

variable "aws_region" {
  description = "Region of the bastion."
  type        = string
  default     = "us-east-2"
}

# --- Bastion VPC: set exactly one of create_vpc, vpc_id or redpanda_cluster_id

variable "create_vpc" {
  description = "Create a new VPC (vpc_cidr) with one public subnet for the bastion."
  type        = bool
  default     = false

  validation {
    condition     = length([for chosen in [var.create_vpc, var.vpc_id != null, var.redpanda_cluster_id != null] : chosen if chosen]) == 1
    error_message = "Choose exactly one bastion VPC: create_vpc = true, vpc_id = \"vpc-...\", or redpanda_cluster_id = \"...\" (BYOC cluster VPC)."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the new VPC when create_vpc = true. If you plan to peer it with a cluster VPC, it must not overlap that VPC's CIDRs."
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
  description = "Redpanda BYOC cluster ID (Redpanda Cloud console). Deploys into the cluster VPC, found from the BYOC agent instance. Also used in names and tags."
  type        = string
  default     = null
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
