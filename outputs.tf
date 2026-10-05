output "public_ip" {
  description = "Bastion public IP."
  value       = aws_instance.bastion.public_ip
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
  description = "Pass as -var vpc_id=... to destroy after the cluster is gone."
  value       = local.vpc_id
}
