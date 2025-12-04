# Tofusible Dynamic Inventory Plugin

Ansible dynamic inventory plugin that consumes host data from OpenTofu stack outputs via Spacelift stack dependencies.

## Location

This plugin must be placed in `inventory_plugins/` relative to the Ansible project root.

## Usage

Configure in `tofusible.yml`:

```yaml
plugin: tofusible
```

The plugin reads host inventory from the dependent OpenTofu stack's outputs, enabling seamless infrastructure-to-configuration handoff.
