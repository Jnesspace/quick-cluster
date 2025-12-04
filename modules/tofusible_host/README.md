# Tofusible Host Module

The `tofusible_host` module normalizes host data for consumption by the Spacelift Ansible dynamic inventory plugin. It abstracts provider-specific attributes into a consistent structure so downstream automation can reliably reference host addresses and metadata.

## Purpose

- Provide a uniform schema for host addresses and attributes across providers.
- Emit data in a shape directly consumable by the `tofusible` inventory plugin.

## Key Inputs

- `host` (string): Address of the host (for example, EC2 public IP). Required.
- `groups` (list(string)): Inventory groups to assign the host to. Dotted notation creates nested groups (for example, `servers.linux`).
- `extra_vars` (map(string)): Arbitrary variables attached to the host object for use in playbooks.

### Example

```hcl
module "tofusible_host_web" {
  source = "spacelift.io/spacelift-solutions/tofusible-host/spacelift"

  host   = aws_instance.web.public_ip
  groups = ["web", "production", "servers.linux"]
  extra_vars = {
    environment = "prod"
  }
}
```

## Ansible Behavioral Inventory Parameters

Behavioral parameters may be supplied without the `ansible_` prefix. Examples:

```hcl
module "tofusible_host_app" {
  source = "spacelift.io/spacelift-solutions/tofusible-host/spacelift"

  host = "192.0.2.10"
  user = "ubuntu"  # sets ansible_user
}
```

See the Ansible documentation for the full set of behavioral inventory parameters: https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html#connecting-to-hosts-behavioral-inventory-parameters
