# Prometheus Monitoring Stack

This directory contains Kubernetes manifests for deploying a complete Prometheus monitoring stack.

## Components

### Prometheus Server
- **File**: `prometheus-deployment.yaml`, `prometheus-configmap.yaml`, `prometheus-service.yaml`, `prometheus-rbac.yaml`
- **Purpose**: Main metrics collection and storage server
- **Access**: NodePort 30090 (http://NODE_IP:30090)
- **Retention**: 7 days
- **Resource Limits**: 1 CPU, 2GB RAM

### Node Exporter
- **File**: `node-exporter-daemonset.yaml`
- **Purpose**: Collects host-level metrics (CPU, memory, disk, network) from each node
- **Deployment**: DaemonSet (runs on every node)
- **Port**: 9100

### Kube-State-Metrics
- **File**: `kube-state-metrics.yaml`
- **Purpose**: Generates metrics about Kubernetes objects (pods, deployments, services, etc.)
- **Port**: 8080 (metrics), 8081 (telemetry)

## Deployment

These manifests are deployed automatically by the Kubernetes Spacelift stack.

To manually apply:

```bash
kubectl apply -f prometheus-namespace.yaml
kubectl apply -f prometheus-rbac.yaml
kubectl apply -f prometheus-configmap.yaml
kubectl apply -f prometheus-deployment.yaml
kubectl apply -f prometheus-service.yaml
kubectl apply -f node-exporter-daemonset.yaml
kubectl apply -f kube-state-metrics.yaml
```

## Accessing Prometheus

### Via NodePort
Access Prometheus UI on any cluster node:
```bash
# Get node IPs
kubectl get nodes -o wide

# Access Prometheus (replace NODE_IP with any node's external IP)
http://NODE_IP:30090
```

### Via Port Forward
Forward Prometheus to localhost:
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Then access: http://localhost:9090
```

## What's Being Monitored

1. **Prometheus itself** - Self-monitoring
2. **Kubernetes API server** - API health and performance
3. **Kubernetes nodes** - Via kubelet metrics
4. **Node-level metrics** - Detailed host metrics via node-exporter
5. **Kubernetes resources** - Pods, deployments, services via kube-state-metrics
6. **Spacelift workers** - Any pods in spacelift-worker-controller-system namespace
7. **Custom pods** - Any pod with `prometheus.io/scrape: "true"` annotation

## Useful Queries

### Node Metrics
```promql
# CPU usage per node
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage per node
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# Disk usage per node
100 - ((node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100)
```

### Kubernetes Metrics
```promql
# Pod count by namespace
kube_pod_info

# Container restarts
rate(kube_pod_container_status_restarts_total[1h])

# Pods not ready
kube_pod_status_phase{phase!="Running"}
```

### Spacelift Workers
```promql
# Worker pods
kube_pod_info{namespace="spacelift-worker-controller-system"}

# Worker resource usage
container_memory_working_set_bytes{namespace="spacelift-worker-controller-system"}
```

## Storage

Currently using `emptyDir` for Prometheus storage (ephemeral). Data is retained for 7 days but will be lost if the pod restarts.

To persist data across pod restarts, replace the `emptyDir` volume in `prometheus-deployment.yaml` with a `PersistentVolumeClaim`.

## Resource Requests

- **Prometheus**: 200m CPU, 512Mi RAM (limit: 1 CPU, 2Gi RAM)
- **Node Exporter**: 100m CPU, 128Mi RAM (limit: 200m CPU, 256Mi RAM)
- **Kube-State-Metrics**: 100m CPU, 128Mi RAM (limit: 200m CPU, 256Mi RAM)

**Total per node**: ~400m CPU, ~768Mi RAM

## Troubleshooting

### Check Prometheus logs
```bash
kubectl logs -n monitoring -l app=prometheus
```

### Check targets
Access Prometheus UI → Status → Targets to see all scraped endpoints

### Check service discovery
Access Prometheus UI → Status → Service Discovery to see discovered targets

### Verify RBAC permissions
```bash
kubectl get clusterrolebinding prometheus -o yaml
kubectl get clusterrolebinding kube-state-metrics -o yaml
```
