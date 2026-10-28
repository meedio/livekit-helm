
Meedio's fork of the LiveKit Helm charts, published to Harbor as OCI charts:
`oci://registry.meedio.eu/meedio/livekit-server`, `.../ingress` and `.../egress`.

## Installing

Log in to Harbor with a robot account:

```shell
helm registry login registry.meedio.eu -u '<HARBOR_USER>' --password-stdin
```

Customize values in values-sample.yaml

### Per-node media VIPs (`instances`)

One room stays on one SFU. Direct ICE therefore needs one advertised address
per LiveKit node. Set `instances` to create one DaemonSet and ConfigMap per
node, each with its own `rtc.node_ip`. TURN/TLS stays on the shared
`*-turn` Service.

```yaml
instances:
  - name: lk-0
    node_ip: 203.0.113.10
    nodeSelector:
      kubernetes.io/hostname: k8s-worker-livekit-0
  - name: lk-1
    node_ip: 203.0.113.11
    nodeSelector:
      kubernetes.io/hostname: k8s-worker-livekit-1
```

Leave `instances` empty for a single shared config (previous behaviour).

Then install the chart

```shell
helm install <instance_name> oci://registry.meedio.eu/meedio/livekit-server --namespace <namespace> --values values.yaml
```

## For LiveKit Helm developers

Each chart pins its default image by `image.digest`. Image findings that upstream has not
fixed yet are listed, with a reason, in [`.grype.yaml`](.grype.yaml).

CI (`.github/workflows/`):

- `test.yaml` runs `ct lint` and renders each chart in its supported layouts on every chart PR.
- `scan-images.yaml` runs Grype on every image the charts render by default, with
  `.grype.yaml`, and fails on a High or Critical finding. It runs on PRs, on master and weekly,
  so new advisories against pinned images surface without a chart change.
- `publish.yaml` packages and pushes every chart to Harbor on a push to master. Bump the
  chart `version` in any PR that changes a chart.

Scan locally with Docker:

```shell
scripts/scan-images.sh
```
