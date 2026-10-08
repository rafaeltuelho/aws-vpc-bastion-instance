# New VPC for the bastion (create_vpc = true): one public subnet spanning
# vpc_cidr, an internet gateway and a default route to it.

# Not every AZ offers every instance type; pick one that offers instance_type.
data "aws_ec2_instance_type_offerings" "bastion" {
  count         = var.create_vpc ? 1 : 0
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

resource "aws_vpc" "bastion" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = local.tags
}

resource "aws_internet_gateway" "bastion" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.bastion[0].id
  tags   = local.tags
}

resource "aws_subnet" "bastion" {
  count                   = var.create_vpc ? 1 : 0
  vpc_id                  = aws_vpc.bastion[0].id
  cidr_block              = var.vpc_cidr
  availability_zone       = try(sort(data.aws_ec2_instance_type_offerings.bastion[0].locations)[0], null)
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.bastion_name}-public" })

  lifecycle {
    precondition {
      condition     = length(data.aws_ec2_instance_type_offerings.bastion[0].locations) > 0
      error_message = "No availability zone in ${var.aws_region} offers ${var.instance_type}."
    }
  }
}

resource "aws_route_table" "bastion" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.bastion[0].id
  tags   = merge(local.tags, { Name = "${local.bastion_name}-public" })
}

resource "aws_route" "bastion_internet" {
  count                  = var.create_vpc ? 1 : 0
  route_table_id         = aws_route_table.bastion[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.bastion[0].id
}

resource "aws_route_table_association" "bastion" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.bastion[0].id
  route_table_id = aws_route_table.bastion[0].id
}
