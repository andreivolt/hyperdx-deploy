# hyperdx-deploy

ArgoCD-managed [HyperDX](https://www.hyperdx.io/) (Sentry-compatible
errors + OTLP traces/logs/metrics + session replay) on volt's k3s cluster.
Replaces Bugsink.

Single upstream chart: `hyperdxio/hdx-oss-v2`. The chart bundles
ClickHouse + MongoDB + the HyperDX OTEL collector. This repo wraps the
chart in a kustomize layer (`kustomization.yaml` at the repo root) so we
can patch the chart-rendered ClickHouse Deployment to add an S3 cold-tier
storage policy. ArgoCD points at the repo root as a kustomize source;
the chart is inflated in-place via `kustomize.helmCharts` (requires
`kustomize.buildOptions: --enable-helm` in `argocd-cm`, set by the
bootstrap repo).

## Layout

```
kustomization.yaml         # kustomize root: helmCharts + ingress + storage patch
values/
  hyperdx.yaml             # Helm values override
manifests/
  ingress.yaml             # traefik route for hyperdx.volt.tail.avolt.net
  clickhouse-storage-config.yaml  # ConfigMap with <storage_configuration> XML
  clickhouse-storage-patch.yaml   # strategic-merge patch: mounts + envFrom on the CH Deployment
secrets/
  hyperdx-s3.sops.yaml     # garage S3 creds (sops+age) for ClickHouse cold tier
install.sh                 # idempotent: applies the bootstrap-side Application manifest
```

The ArgoCD `Application` itself lives in
`~/dev/volt/bootstrap/argocd/apps/hyperdx.yaml` (single source of truth,
deployed by the cluster's app-of-apps).

## Public URL

`https://hyperdx.volt.tail.avolt.net` — tailnet-only, served via the
mirrored `*.volt.tail.avolt.net` wildcard cert (no per-host cert-manager
annotation needed; reflector reflects the Secret into the `hyperdx`
namespace).

## No-login access (Grafana-style)

The UI opens straight into the app with no login screen, the same outcome
as Grafana's anonymous-admin. HyperDX OSS v2 gets there differently because
it has **no anonymous / no-auth / declarative-credentials mode** for the
split multi-component deployment (upstream issue hyperdxio/hyperdx#1329 is
open and unaddressed; its only auth-less path, `IS_LOCAL_MODE`, is a
build-time `NEXT_PUBLIC` flag baked `false` into the standard image and ships
as an all-in-one localStorage container — incompatible with this chart).

Instead `manifests/middleware-auto-login.yaml` injects a valid HyperDX
session cookie at the traefik layer. HyperDX uses express-session
(`connect.sid`) backed by connect-mongo with `rolling:true` and a 30-day
maxAge, so one server-validated session renews on every request and never
lapses. The `tailnet-only` ipAllowList sibling pins the host to Tailscale
IPs, so the injected session is only reachable from the tailnet (the cookie
is a plaintext shared credential, same posture as Grafana's `adminPassword`).
Re-mint instructions are in the middleware file's header comment.

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

- **Hot**: ClickHouse local PVC (10Gi, local-path on volt) — fast SSD.
- **Cold**: Garage S3 bucket `hyperdx-cold` (single-node Garage on volt,
  tailnet endpoint `http://100.64.0.9:3900`) — slow but cheap. Mounted
  into ClickHouse as the `cold_s3` disk.
- **MongoDB**: 5Gi local-path PVC (metadata: users, dashboards, alerts).

### Cold-tier storage policy

`manifests/clickhouse-storage-config.yaml` provides a sidecar
`<storage_configuration>` XML injected into ClickHouse via
`/etc/clickhouse-server/config.d/storage.xml`. It declares:

- A `cold_s3` disk pointing at `hyperdx-cold/clickhouse/`, with creds
  pulled from env vars (`HYPERDX_S3_ACCESS_KEY` /
  `HYPERDX_S3_SECRET_KEY`) supplied by `envFrom: hyperdx-s3-credentials`.
- A `tiered` storage policy: `default` (local) → `cold_s3` with
  `move_factor=0.2`, so ClickHouse migrates oldest parts to S3 when the
  hot disk is >80% full.

To verify the policy is loaded:

```sh
ssh volt 'sudo k3s kubectl -n hyperdx exec deploy/hyperdx-hdx-oss-v2-clickhouse -- \
  clickhouse-client -q "SHOW STORAGE POLICIES"'
# Expect: default, tiered
ssh volt 'sudo k3s kubectl -n hyperdx exec deploy/hyperdx-hdx-oss-v2-clickhouse -- \
  clickhouse-client -q "SELECT name, type FROM system.disks"'
# Expect: default (local), cold_s3 (s3)
```

#### Per-table TTL (one-off operator step)

The storage policy makes the cold disk **available**; per-table TTL
drives the bulk of the migration. HyperDX creates its tables itself
(default schema), so the TTL has to be applied out-of-band after the
first ingest. For each large table (`default.otel_logs`,
`default.otel_traces`, `default.otel_metrics_*`, `default.hyperdx_sessions`):

```sql
ALTER TABLE default.otel_logs
  MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE default.otel_logs
  MODIFY TTL toDate(Timestamp) + INTERVAL 7 DAY  TO DISK 'cold_s3',
         toDate(Timestamp) + INTERVAL 90 DAY DELETE;
```

7 days hot, 90 days cold, then dropped.

## Out-of-band state

- Garage bucket: `hyperdx-cold` (created via `sudo garage bucket create`).
- Garage key: `hyperdx` / `GKa753b838512445e634f3bc8e` (read+write on
  `hyperdx-cold`). Secret encrypted in `secrets/hyperdx-s3.sops.yaml`,
  decrypted by sops-secrets-operator into Secret `hyperdx-s3-credentials`.
- `argocd-cm` must have `kustomize.buildOptions: --enable-helm` (set
  cluster-wide by the bootstrap repo) for `kustomize.helmCharts` to work.
