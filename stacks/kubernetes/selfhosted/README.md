# Spacelift Self-Hosted — all-in-one Helm chart

A single Helm chart that stands up [Spacelift self-hosted](https://docs.spacelift.io/self-hosted/latest/installing-spacelift/reference-architecture/guides/deploying-to-onprem.html)
on a small cluster (e.g. k3s). One `helm install` deploys the Spacelift app plus
its dependencies, wired together with the required secrets:

| Component   | Source                                      | Notes                                            |
| ----------- | ------------------------------------------- | ------------------------------------------------ |
| Spacelift   | `spacelift-self-hosted` subchart (aliased `spacelift`) | server, drain, scheduler, MQTT          |
| MinIO       | `minio` subchart                            | object storage + 11 buckets + ILM + S3 creds     |
| PostgreSQL  | `charts/postgres` (local subchart)          | single instance, PVC-backed                      |
| Secrets     | this chart's `templates/secrets.yaml`       | `spacelift-shared` / `-server` / `-drain`        |
| HPAs        | this chart's `templates/hpa.yaml`           | optional autoscaling for server/drain            |

Defaults target **minimal cost on k3s**: single replicas, modest requests,
in-cluster MinIO + Postgres on PVCs (k3s `local-path`).

## Prerequisites

- A running cluster + `kubectl` context, and [`helm`](https://helm.sh) 3.14+.
- An **ingress controller** and DNS you can point at it. k3s ships Traefik; this
  chart's ingress annotations are nginx-flavored (see Notes).
- Spacelift **images pushed to your registry** (`spacelift-backend`, `spacelift-launcher`)
  per the guide's "Push images" step — this chart does not push images.
- A Spacelift **license token** and an **RSA encryption key**.
- For HPA autoscaling: **metrics-server** (k3s bundles it).

## Quickstart

```bash
# 1. Generate the RSA encryption key
./scripts/gen-rsa-key.sh                      # copy the output

# 2. Fill in your values
cp values-secrets.example.yaml values-secrets.yaml
$EDITOR values-secrets.yaml                   # license, passwords, domain, images

# 3. Fetch subcharts (minio + spacelift-self-hosted) into charts/
helm dependency build

# 4. Install
helm install spacelift . \
  -n spacelift --create-namespace \
  -f values-secrets.yaml \
  --skip-schema-validation
```

Then point DNS for `serverHostname` and the MinIO host at your ingress IP, and
complete [first-time setup](https://docs.spacelift.io/self-hosted/latest/installing-spacelift/reference-architecture/guides/first-setup.html).

> **Why `--skip-schema-validation`?** The upstream `spacelift-self-hosted` chart
> ships a strict `values.schema.json` (`additionalProperties: false`) that rejects
> the `global` key Helm automatically injects into every subchart. The flag is
> only needed because we run it as a subchart; it does not affect what's deployed.

## Configuration

Everything is driven by `values.yaml`. The minimal set to override lives in
`values-secrets.example.yaml`. Key knobs:

- `spacelift.shared.serverHostname` / `spacelift.shared.image` — your domain and backend image.
- `launcher.image` / `launcher.tag` — launcher image used to spawn run pods.
- `objectStorage.publicUrl` — externally reachable MinIO URL (for presigned URLs).
- `minio.*` — bundled object storage. Set `minio.enabled: false` to use external
  object storage instead (then fill `objectStorage.endpoint/accessKeyId/secretAccessKey`).
- `postgres.*` — bundled DB. Set `postgres.enabled: false` for an external managed
  database (then set `database.url`, keeping `?statement_cache_capacity=0`).
- `*.storageClass` — `""` uses the cluster default (`local-path` on k3s); set your
  EBS class (e.g. `gp3`) for durable volumes on AWS-backed nodes.

## Scaling

### Manual

```bash
# Persistent — change values and upgrade:
helm upgrade spacelift . -n spacelift --reuse-values --skip-schema-validation \
  --set spacelift.server.replicaCount=3 \
  --set spacelift.drain.replicaCount=2

# Immediate (non-persistent):
./scripts/scale.sh server 3
./scripts/scale.sh drain 2
```

- **server** and **drain** scale horizontally.
- **scheduler** stays at **1** (it emits recurring tasks).

### Autoscaling (HPA)

The upstream chart has no HPA, so this chart adds optional ones for server/drain.
Requires metrics-server. Enable in values:

```yaml
spacelift:
  server:
    replicaCount: 2          # set to the HPA minimum
autoscaling:
  server:
    enabled: true
    minReplicas: 2
    maxReplicas: 8
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80   # optional
```

`kubectl -n spacelift get hpa` to watch. When an HPA is enabled, set that
component's `replicaCount` to its `minReplicas` (each `helm upgrade` resets
replicas to that value, then the HPA scales from there).

> **Node** autoscaling is a cluster concern (cluster-autoscaler / Karpenter), not
> part of this chart.

## Workers (the runners)

Workers are **phase-two**: deploy them *after* the app is up and you've created a
worker pool in Spacelift (you need its token + base64 private key). Run them in a
**dedicated namespace**. Both paths use Spacelift's published charts directly —
we only add the glue they leave to you. Pick one:

- **Autoscaling (controller + KEDA)** → the `workers/` chart. Wraps the upstream
  `spacelift-workerpool-controller` (WorkerPool CRD + `spacelift-promex`) and adds
  the `WorkerPool` CR, credentials secret, PodMonitor, and a KEDA `ScaledObject`
  that scales on Spacelift queue depth. Requires KEDA + a Prometheus that scrapes
  promex (their upstream charts — install separately).

  ```bash
  cp workers/values-secrets.example.yaml worker-secrets.yaml   # fill in token/key/api creds
  helm dependency build ./workers
  helm install spacelift-workers ./workers -n spacelift-workers --create-namespace -f worker-secrets.yaml
  ```

- **Simple/static** → `examples/worker-pool-values.yaml`. Installs the upstream
  `spacelift-worker` chart directly (a plain Deployment of launcher pods), scaled
  by `replicaCount` (or attach your own HPA). No operator.

  ```bash
  helm upgrade --install spacelift-workers spacelift/spacelift-worker --version 0.64.0 \
    -n spacelift-workers --create-namespace -f examples/worker-pool-values.yaml
  ```

For self-hosted, repoint the worker images to your registry's launcher and set pod
resources (an admission controller may otherwise inject huge requests).

## Teardown

```bash
helm uninstall spacelift -n spacelift
kubectl -n spacelift delete pvc --all   # PVCs (MinIO/Postgres data) are NOT auto-deleted
kubectl delete namespace spacelift
```

## Notes & caveats

- **k3s ships Traefik.** This chart's Spacelift/MinIO ingresses use nginx
  annotations and default `ingressClassName: nginx`. Either run ingress-nginx
  (e.g. start k3s with `--disable traefik` and install ingress-nginx), or set the
  `ingressClassName` fields to `traefik` — note the body-size and underscore-header
  tweaks below won't apply on Traefik.
- **Underscore headers.** MinIO presigned uploads send headers with underscores;
  nginx strips them by default. If you run ingress-nginx, enable
  `enable-underscores-in-headers: "true"` in the controller config.
- **MinIO CORS.** `minio.environment.MINIO_API_CORS_ALLOW_ORIGIN` defaults to `*`;
  tighten to your domain if desired.
- **TLS.** The Spacelift ingress expects a TLS secret named `cert`; the MinIO
  ingress uses `minio-tls`. Use cert-manager (uncomment the `cert-manager.io/cluster-issuer`
  annotations in values) or provide those secrets yourself.
- **In-cluster Postgres is not production-recommended** (per the guide) — it's here
  for low cost. Back up the PVC or use an external DB (`postgres.enabled: false`).
- **MinIO ILM `mc` syntax.** Values use `mc ilm rule add --expire-days …`; very old
  `mc` images use `mc ilm add --expiry-days …` — adjust if the provisioning job fails.
- **Pinned versions.** `Chart.yaml` pins `spacelift-self-hosted` 0.64.0 (appVersion
  4.0.0) and `minio` 5.4.0. Bump and re-run `helm dependency build` to upgrade.
```
