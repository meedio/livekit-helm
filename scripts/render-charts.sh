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

# A layout the chart must refuse to render.
render_fails() {
  local name="$1" chart="$2"
  shift 2
  echo "==> $chart: $name (must fail)"
  if helm template render "$root/$chart" "$@" >/dev/null 2>&1; then
    echo "expected the render to fail: $name" >&2
    exit 1
  fi
}

# A layout whose render must contain a line that matches each given pattern (grep -E).
# A pattern that starts with "!" must match no line. Usage: render_has <name> <chart>
# <pattern>... -- <helm arguments>
render_has() {
  local name="$1" chart="$2" out pattern
  shift 2
  local patterns=()
  while [[ "$1" != "--" ]]; do
    patterns+=("$1")
    shift
  done
  shift
  echo "==> $chart: $name"
  out="$(helm template render "$root/$chart" "$@")"
  for pattern in "${patterns[@]}"; do
    if [[ "$pattern" == "!"* ]]; then
      if grep -Eq -- "${pattern#!}" <<<"$out"; then
        echo "the render must not contain '${pattern#!}': $name" >&2
        exit 1
      fi
    elif ! grep -Eq -- "$pattern" <<<"$out"; then
      echo "the render must contain '$pattern': $name" >&2
      exit 1
    fi
  done
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
turn_name_0=(--set 'instances[0].turn.domain=turn-0.example.com'
  --set 'instances[0].turn.secretName=turn-0-tls')
turn_name_1=(--set 'instances[1].turn.domain=turn-1.example.com'
  --set 'instances[1].turn.secretName=turn-1-tls')

render "defaults" livekit-server
render "Deployment, TURN/TLS, load balancer with test hook" livekit-server \
  "${keys[@]}" "${turn[@]}" --set loadBalancer.type=aws
render "DaemonSet with host networking" livekit-server \
  "${keys[@]}" --set deploymentType=DaemonSet --set hostNetwork=true
render "per-node instances with TURN/TLS" livekit-server "${keys[@]}" "${turn[@]}" "${instances[@]}"
render "per-node instances, each with its own TURN name and Service" livekit-server \
  "${keys[@]}" "${turn[@]}" "${instances[@]}" "${turn_name_0[@]}" "${turn_name_1[@]}"
render "per-node instances, own TURN names, no TURN Service" livekit-server \
  "${keys[@]}" "${turn[@]}" "${instances[@]}" "${turn_name_0[@]}" --set turnLoadbalancer.enable=false
render_fails "TURN Service with only some instances on their own TURN name" livekit-server \
  "${keys[@]}" "${turn[@]}" "${instances[@]}" "${turn_name_0[@]}"
render_fails "shared TURN nodePort with per-instance TURN Services" livekit-server \
  "${keys[@]}" "${turn[@]}" "${instances[@]}" "${turn_name_0[@]}" "${turn_name_1[@]}" \
  --set livekit.turn.serviceType=NodePort --set livekit.turn.nodePort=30443
redis_ha=(--set livekit.keys.devkey=secret --set redisSentinel.enabled=true
  --set 'redisSentinel.serviceName=\{\{ .Release.Name \}\}-redis'
  --set redisSentinel.existingSecret=redis-credentials)
render_has "per-node instances on the Sentinels of a redis-ha release, passwords from its Secret" livekit-server \
  'render-redis-server-0\.render-redis:26379' 'render-redis-server-2\.render-redis:26379' \
  '!render-redis-server-3' 'sentinel_master_name: mymaster' \
  'name: LIVEKIT_REDIS_PASSWORD' 'name: LIVEKIT_REDIS_SENTINEL_PASSWORD' 'name: "redis-credentials"' \
  -- "${redis_ha[@]}" "${instances[@]}"
render_has "redis-ha Sentinels, passwords from the values" livekit-server \
  'render-redis-server-0\.render-redis:26379' '!LIVEKIT_REDIS_PASSWORD' '!LIVEKIT_REDIS_SENTINEL_PASSWORD' \
  -- "${redis_ha[@]}" --set livekit.redis.password=pw --set livekit.redis.sentinel_password=pw
render_has "redis-ha Sentinels without a Sentinel password" livekit-server \
  'name: LIVEKIT_REDIS_PASSWORD' '!LIVEKIT_REDIS_SENTINEL_PASSWORD' \
  -- "${redis_ha[@]}" --set redisSentinel.sentinelPasswordKey=
render_has "a Redis address in the values wins over redisSentinel" livekit-server \
  'address: redis:6379' '!sentinel_addresses' '!LIVEKIT_REDIS_' \
  -- "${redis_ha[@]}" --set livekit.redis.address=redis:6379
render_has "Sentinel addresses in the values win over redisSentinel" livekit-server \
  'other-0:26379' '!render-redis-server' '!LIVEKIT_REDIS_' \
  -- "${redis_ha[@]}" --set 'livekit.redis.sentinel_addresses[0]=other-0:26379'
render_fails "redisSentinel without serviceName" livekit-server \
  --set livekit.keys.devkey=secret --set redisSentinel.enabled=true
render "keys in a secret" livekit-server \
  --set livekit.key_file=keys.yaml --set storeKeysInSecret.enabled=true \
  --set storeKeysInSecret.keys.devkey=secret
render "defaults" ingress
render "defaults" egress
render "deployment strategy" egress --set deploymentStrategy.type=Recreate

echo "All charts render."
