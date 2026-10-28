#!/usr/bin/env bash
# Scan every image the charts render by default with Grype and the repo's .grype.yaml.
#
#   scripts/scan-images.sh
#
# Exits non-zero when any image has a High or Critical finding that .grype.yaml does not
# ignore. Needs helm and docker. Set GITHUB_STEP_SUMMARY to also write a Markdown report.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
grype_image="${GRYPE_IMAGE:-anchore/grype:v0.121.0}"
platform="${PLATFORM:-linux/amd64}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# loadBalancer.type renders the server's `helm test` hook, which has its own image.
images="$(
  {
    helm template scan "$root/livekit-server" --set loadBalancer.type=aws
    helm template scan "$root/ingress"
    helm template scan "$root/egress"
  } | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' | sort -u
)"
if [ -z "$images" ]; then
  echo "no images rendered" >&2
  exit 1
fi

echo "## Image scan (Grype ${grype_image##*:}, $platform)" >>"$summary"
failed=""
for image in $images; do
  echo "==> $image"
  set +e
  out="$(docker run --rm \
    -v "$root/.grype.yaml:/config/.grype.yaml:ro" \
    "$grype_image" "registry:$image" \
    -c /config/.grype.yaml --platform "$platform" --fail-on high -q -o table 2>&1)"
  rc=$?
  set -e
  echo "$out"
  case "$rc" in
    0) verdict="pass" ;;
    2) verdict="**fail**: High or Critical finding not in .grype.yaml"; failed="$failed $image" ;;
    *) verdict="**error** (exit $rc)"; failed="$failed $image" ;;
  esac
  {
    echo
    echo "### \`$image\`: $verdict"
    echo
    echo '<details><summary>Findings</summary>'
    echo
    echo '```'
    echo "$out"
    echo '```'
    echo '</details>'
  } >>"$summary"
done

if [ -n "$failed" ]; then
  echo "Images with unignored High/Critical findings or scan errors:$failed" >&2
  exit 1
fi
echo "All images pass."
