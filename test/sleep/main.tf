# Minimal stack for reproducing self-hosted worker behaviour during
# control-plane restarts. It has no providers/backend so `terraform init` is
# instant; the worker is held "busy" by a runtime after_init sleep, e.g.:
#
#   runtime_config:
#     after_init:
#       - echo sleep
#       - sleep 3600
#
# Then restart spacelift-drain / -scheduler / -server in turn and watch whether
# the in-flight run survives (the builtin MQTT broker lives in the server pod).

output "ok" {
  value = "sleep-stack ready"
}
