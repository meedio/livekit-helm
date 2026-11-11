
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
`*-turn` Service unless the instances set their own TURN name (below).

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

### Per-instance TURN names (`instances[].turn`)

With the shared `*-turn` Service, a client on TURN/TLS can land on either SFU,
which then has to relay to the media address of the SFU that holds the room.
Give each instance its own TURN name and the client lands on the SFU that
holds its room: LiveKit hands a client the `turn.domain` of the node the room
runs on. Needs chart 1.13.0 or later.

```yaml
livekit:
  turn:
    enabled: true
    tls_port: 5349
instances:
  - name: lk-0
    node_ip: 203.0.113.10
    turn:
      domain: turn-0.example.com
      secretName: turn-0-tls
    nodeSelector:
      kubernetes.io/hostname: k8s-worker-livekit-0
  - name: lk-1
    node_ip: 203.0.113.11
    turn:
      domain: turn-1.example.com
      secretName: turn-1-tls
    nodeSelector:
      kubernetes.io/hostname: k8s-worker-livekit-1
```

- `turn.domain` replaces `livekit.turn.domain` in that instance's config.
- `turn.secretName` is the TLS Secret that instance mounts. Without it the
  instance mounts `livekit.turn.secretName`, which must then cover its name.
- With `turnLoadbalancer.enable`, the chart renders one Service per instance,
  `<fullname>-<name>-turn`, selecting only that instance's pods, and no shared
  Service. Every instance must set `turn.domain`, or none; a mix fails the
  render.
- Each Service takes `turn.loadBalancerIP` and `turn.nodePort` from its own
  instance. `livekit.turn.loadBalancerIP` and `livekit.turn.nodePort` belong to
  the shared Service and fail the render here. `turn.loadBalancerAnnotations`
  are merged over `livekit.turn.loadBalancerAnnotations`.
- With `turnLoadbalancer.enable: false` the chart renders no TURN Service.
  Point each name at a load balancer that forwards 443 to `turn.tls_port` on
  that instance's node only.

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
  `.grype.yaml`, and fails on a High or Critical finding. It runs on chart PRs and on master.
- `publish.yaml` packages and pushes every chart to Harbor on a push to master. Bump the
  chart `version` in any PR that changes a chart.

Scan locally with Docker:

```shell
scripts/scan-images.sh
```
