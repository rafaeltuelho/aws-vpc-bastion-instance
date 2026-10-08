output "public_ip" {
  description = "Bastion public IP."
  value       = aws_instance.bastion.public_ip
}

output "private_ip" {
  description = "Bastion private IP (the source address brokers see)."
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
  description = "Bastion VPC ID. Pass it to the peering/ module as client_vpc_id."
  value       = local.vpc_id
}

output "subnet_id" {
  description = "Bastion subnet ID."
  value       = local.subnet_id
}
