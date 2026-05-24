# hyperdx-deploy

ArgoCD-managed [HyperDX](https://www.hyperdx.io/) (Sentry-compatible
errors + OTLP traces/logs/metrics + session replay) on volt's k3s cluster.
Replaces Bugsink.

Single upstream chart: `hyperdxio/hdx-oss-v2`. The chart bundles
ClickHouse + MongoDB + the HyperDX OTEL collector; this repo only holds
the values, the traefik Ingress, the S3-cold-storage secret, and the
`Application` manifest that points ArgoCD at the chart repo.

## Layout

```
argocd/
  hyperdx.yaml         # ArgoCD Application (multi-source: chart + values + manifests + secret)
values/
  hyperdx.yaml         # Helm values override
manifests/
  ingress.yaml         # traefik route for hyperdx.volt.tail.avolt.net
secrets/
  hyperdx-s3.sops.yaml # garage S3 creds (sops+age) for ClickHouse cold tier (staged, not yet wired)
install.sh             # idempotent: applies argocd/hyperdx.yaml
```

## Public URL

`https://hyperdx.volt.tail.avolt.net` — tailnet-only, served via the
mirrored `*.volt.tail.avolt.net` wildcard cert (no per-host cert-manager
annotation needed; reflector reflects the Secret into the `hyperdx`
namespace).

## Install

```sh
./install.sh
```

ArgoCD syncs within ~3 min.

## Verify

```sh
ssh volt 'sudo k3s kubectl -n argocd get app hyperdx'
ssh volt 'sudo k3s kubectl -n hyperdx get pods,pvc,ingress'
curl -sI https://hyperdx.volt.tail.avolt.net
```

## OTLP ingestion

Apps send to `hyperdx-hdx-oss-v2-otel-collector.hyperdx:4317` (gRPC)
or `:4318` (HTTP). The HyperDX UI auto-discovers a Sentry-compatible
DSN at `<frontendUrl>/api/v1/sentry/<token>`; this is the value of
`SENTRY_DSN` baked into each app's env.

## Storage layout

- ClickHouse hot data on a 10Gi local-path PVC (~7d target retention).
- MongoDB on a 5Gi local-path PVC (metadata: users, dashboards, alerts).
- Cold-tier in Garage S3 (`hyperdx-cold` bucket, key `hyperdx`) is
  **provisioned but not yet wired**. To enable: add a ClickHouse
  `<storage_configuration>` S3 disk + `tiered` storage policy that
  envFroms `hyperdx-s3-credentials`, and patch the chart's
  `clickhouse-config` ConfigMap (chart doesn't expose this natively
  — likely needs a kustomize overlay or chart fork).

## Out-of-band state

- Garage bucket: `hyperdx-cold` (created via `sudo garage bucket create`).
- Garage key: `hyperdx` / `GKa753b838512445e634f3bc8e` (read+write on
  `hyperdx-cold`). Secret encrypted in `secrets/hyperdx-s3.sops.yaml`.
