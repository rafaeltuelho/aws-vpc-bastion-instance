# AWS VPC Bastion for Redpanda BYOC

Terraform that launches a small SSH bastion (Ubuntu 24.04) inside the VPC of a
[Redpanda BYOC](https://docs.redpanda.com/redpanda-cloud/get-started/cluster-types/byoc/)
cluster on AWS, with [`rpk`](https://docs.redpanda.com/current/reference/rpk/)
preinstalled. Use it to inspect and manage the cluster from inside its network,
e.g. when the cluster uses private connectivity.

## What it creates

| Resource | Details |
|---|---|
| Security group `<owner>-bastion-<cluster_id>-ssh` | SSH (22/tcp) from `ssh_cidr` only (default: your current public IP `/32`); all egress |
| EC2 instance `<owner>-bastion-<cluster_id>` | Latest Ubuntu 24.04 x86_64 AMI, first public subnet of the cluster VPC, IMDSv2 required, encrypted gp3 root volume |

Cloud-init installs `rpk` (with bash completion), `curl`, `jq`, `unzip` and
`netcat-openbsd`.

The cluster VPC is found automatically from the BYOC agent instance (tag
`Name=redpanda-<cluster_id>`), unless you pass `vpc_id`. Everything is tagged
`redpanda-cluster=<cluster_id>`.

## Prerequisites

- Terraform >= 1.5
- AWS credentials for the account and region hosting the BYOC cluster, allowed
  to manage EC2 instances and security groups
- An existing [EC2 key pair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html)
  in that region and its private key
- The Redpanda BYOC cluster ID (Redpanda Cloud console)
- At least one public subnet in the cluster VPC (`map-public-ip-on-launch=true`)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
```

Or without a tfvars file:

```bash
terraform apply -var cluster_id=<id> -var key_name=<key> -var owner=<you>
```

Connect using the `ssh_command` output:

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@$(terraform output -raw public_ip)
```

Cloud-init needs a minute or two after boot. Check progress with
`tail -f /var/log/cloud-init-output.log`, or wait with `cloud-init status --wait`.

From the bastion, configure `rpk` to reach the cluster, e.g. with
`rpk cloud login` and `rpk cloud cluster select`, or with an `rpk` profile that
points at the cluster's bootstrap servers.

### Tear down

```bash
terraform destroy
```

If the BYOC cluster (and its agent instance) is already gone, the VPC lookup
fails. Pass the VPC ID instead; `terraform output vpc_id` prints it:

```bash
terraform destroy -var vpc_id=vpc-0123456789abcdef0
```

## Inputs

| Name | Description | Default |
|---|---|---|
| `cluster_id` | Redpanda BYOC cluster ID | required |
| `key_name` | Existing EC2 key pair name in `aws_region` | required |
| `owner` | Prefix for resource names, e.g. your username | required |
| `aws_region` | Region of the BYOC cluster | `us-east-2` |
| `instance_type` | Bastion instance type (must be x86_64) | `t3.medium` |
| `ssh_cidr` | CIDR allowed to SSH in | your public IP `/32` (via checkip.amazonaws.com) |
| `vpc_id` | Cluster VPC ID; skips the agent lookup | `null` |
| `ami_name_pattern` | Ubuntu AMI name pattern | `ubuntu/images/hvm-ssd-gp3/ubuntu-*-24.04-amd64-server-*` |
| `apt_mirror` | Replacement apt mirror URL | `""` (EC2 regional mirror) |
| `rpk_url` | rpk zip download URL | latest `rpk-linux-amd64.zip` release |

## Outputs

| Name | Description |
|---|---|
| `public_ip` | Bastion public IP |
| `ssh_command` | Ready-to-edit SSH command |
| `instance_id` | Bastion instance ID |
| `vpc_id` | Cluster VPC ID (keep it for `destroy`) |

## Troubleshooting

- **`data.aws_instance.agent` returns no results**: wrong `cluster_id` or `aws_region`, or
  the cluster is gone. Pass `vpc_id` explicitly.
- **`No public subnet ... in vpc-...`**: the VPC has no subnet with
  auto-assign public IP enabled.
- **SSH times out**: your public IP changed since `apply` (VPN, new network).
  Run `terraform apply` again to refresh the rule, or set `ssh_cidr`.
- **`rpk: command not found`**: cloud-init is still running or failed. Check
  `/var/log/cloud-init-output.log`. If apt fails with 503s from the regional
  EC2 mirror, set `apt_mirror = "http://archive.ubuntu.com/ubuntu/"`. Changing
  user data replaces the instance.
- **Newer AMI available**: the AMI is ignored after creation so the bastion is
  not replaced. Use `terraform apply -replace=aws_instance.bastion` to
  rebuild it.

## Security notes

- SSH is the only inbound port and is limited to `ssh_cidr`. Avoid `0.0.0.0/0`.
- Terraform state includes your public IP and resource IDs. It is kept locally
  and ignored by git; use a remote backend if several people share it.
- Destroy the bastion when you no longer need it.

## License

[Apache License 2.0](LICENSE)
