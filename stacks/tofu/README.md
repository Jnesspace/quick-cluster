# OpenTofu Stack

This stack provisions EC2 instances and emits normalized inventory data for the Ansible stack.

## Function
bump
- Provision EC2 instances using OpenTofu
- Normalize host data via the `tofusible_host` module
- Output inventory in a structure consumable by the Ansible dynamic inventory

## Flow

1. Create EC2 instances.
2. Use `tofusible_host` for each provisioned instance to emit group membership and attributes.
3. Expose the aggregated hosts as outputs for the Ansible stack.

See `modules/tofusible_host/README.md` for details on host normalization.
