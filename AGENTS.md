# AGENTS.md

Guidance for AI coding agents working in this repository.

## Purpose

A single Terraform root module that launches an SSH bastion in the VPC of a
Redpanda BYOC cluster on AWS, with `rpk` installed by cloud-init. Keep it
small: one instance, one security group, no modules.

## Layout

- `main.tf`: providers, data lookups (BYOC agent instance → VPC, public
  subnets, Ubuntu AMI, caller IP), security group, instance
- `variables.tf`: inputs; `outputs.tf`: outputs
- `user-data.sh`: cloud-init script rendered with `templatefile()`
- `terraform.tfvars.example`: template for `terraform.tfvars` (git-ignored)

## Conventions

- `user-data.sh` is a Terraform template: `${name}` is interpolated by
  Terraform. Write a literal shell `${VAR}` as `$${VAR}`. Every new template
  variable must also be passed in `templatefile()` in `main.tf`.
- The AMI filter is x86_64 and `rpk_url` points at the amd64 build; keep them
  consistent if adding arm64 support.
- `ignore_changes = [ami]` keeps a running bastion from being replaced by a
  newer AMI; don't remove it. `user_data_replace_on_change` is intentional.
- `vpc_id` and `ssh_cidr` default to `null` and switch off their lookups
  (`count = 0`); keep that pattern for optional lookups.
- Give every variable and output a `description`; document new inputs in the
  README tables.
- Commit `.terraform.lock.hcl` when provider versions change (see below).

## Checks before committing

```bash
terraform fmt -check
terraform init -backend=false && terraform validate
shellcheck user-data.sh   # if available; ignore template-interpolation warnings
```

`terraform plan`/`apply` need real AWS credentials and an existing BYOC
cluster; never run `apply` or `destroy` without the user's explicit request.

## Never commit

State files, `terraform.tfvars`, plan files, private keys (`*.pem`), or real
account IDs, cluster IDs, IPs, or key names in examples.

## Provider versions

`hashicorp/aws` is constrained to `>= 5.0, < 7.0`; the lock file pins the
exact version. To upgrade within the range, run `terraform init -upgrade`,
then regenerate hashes for all platforms:

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 \
  -platform=darwin_amd64 -platform=darwin_arm64 -platform=windows_amd64
```

Before raising the upper bound to a new major version, review that version's
upgrade guide and run `terraform validate` against it.
