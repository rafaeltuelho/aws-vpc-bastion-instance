output "public_ip" {
  description = "Bastion public IP."
  value       = aws_instance.bastion.public_ip
}

output "private_ip" {
  description = "Bastion private IP (the source address brokers see over peering)."
  value       = aws_instance.bastion.private_ip
}

output "ssh_command" {
  description = "SSH command; replace <your-key.pem> with the private key of key_name."
  value       = "ssh -i <your-key.pem> ubuntu@${aws_instance.bastion.public_ip}"
}

output "instance_id" {
  description = "Bastion EC2 instance ID."
  value       = aws_instance.bastion.id
}

output "vpc_id" {
  description = "Bastion VPC ID."
  value       = local.vpc_id
}

output "subnet_id" {
  description = "Bastion subnet ID."
  value       = local.subnet_id
}

output "peer_vpc_id" {
  description = "Peered VPC ID, or null. Pass as -var peer_vpc_id=... to destroy after a BYOC cluster is gone."
  value       = local.peering ? local.peer_vpc_id : null
}

output "peering_connection_id" {
  description = "VPC peering connection ID, or null."
  value       = one(aws_vpc_peering_connection.bastion[*].id)
}
