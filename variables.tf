variable "cluster_id" {
  description = "Redpanda BYOC cluster ID, from the Redpanda Cloud console."
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair in aws_region."
  type        = string
}

variable "aws_region" {
  description = "Region of the BYOC cluster."
  type        = string
  default     = "us-east-2"
}

variable "owner" {
  description = "Prefix for resource names, e.g. your username."
  type        = string
}

variable "instance_type" {
  description = "Bastion instance type."
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

variable "vpc_id" {
  description = "Cluster VPC ID. Leave unset to look it up from the BYOC agent."
  type        = string
  default     = null
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
