#!/usr/bin/env bash
# Render each chart in the layouts we deploy, so template errors fail CI without a cluster.
#
#   scripts/render-charts.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

render() {
  local name="$1" chart="$2"
  shift 2
  echo "==> $chart: $name"
  helm template render "$root/$chart" "$@" >/dev/null
}

keys=(--set livekit.keys.devkey=secret --set livekit.redis.address=redis:6379)
turn=(--set livekit.turn.enabled=true --set livekit.turn.domain=turn.example.com
  --set livekit.turn.tls_port=3478 --set livekit.turn.udp_port=443
  --set livekit.turn.secretName=turn-tls)
instances=(--set deploymentType=DaemonSet
  --set 'instances[0].name=lk-0' --set 'instances[0].node_ip=203.0.113.10'
  --set 'instances[0].nodeSelector.kubernetes\.io/hostname=node-0'
  --set 'instances[1].name=lk-1' --set 'instances[1].node_ip=203.0.113.11'
  --set 'instances[1].nodeSelector.kubernetes\.io/hostname=node-1')

render "defaults" livekit-server
render "Deployment, TURN/TLS, load balancer with test hook" livekit-server \
  "${keys[@]}" "${turn[@]}" --set loadBalancer.type=aws
render "DaemonSet with host networking" livekit-server \
  "${keys[@]}" --set deploymentType=DaemonSet --set hostNetwork=true
render "per-node instances with TURN/TLS" livekit-server "${keys[@]}" "${turn[@]}" "${instances[@]}"
render "keys in a secret" livekit-server \
  --set livekit.key_file=keys.yaml --set storeKeysInSecret.enabled=true \
  --set storeKeysInSecret.keys.devkey=secret
render "defaults" ingress
render "defaults" egress
render "deployment strategy" egress --set deploymentStrategy.type=Recreate

echo "All charts render."
