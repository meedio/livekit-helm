#!/usr/bin/env bash
# Check that a built image carries the patched toolchain and modules.
#
#   images/verify.sh <image> <image-ref>
#
# Copies BINARY out of <image-ref> and fails unless `go version -m` reports
# GO_VERSION and every GO_MODULES entry at or above its listed version.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
name="${1:?usage: verify.sh <image> <image-ref>}"
ref="${2:?usage: verify.sh <image> <image-ref>}"

# shellcheck source=common.env
. "$here/common.env"
# shellcheck source=/dev/null
. "$here/$name/image.env"

# Stream the binary between containers so no host directory has to be shared with Docker.
image="$(docker create "$ref")"
inspector="$(docker create -e GOTOOLCHAIN=local "$GO_IMAGE" go version -m "/tmp/$(basename "$BINARY")")"
trap 'docker rm -f "$image" "$inspector" >/dev/null' EXIT
docker cp "$image:$BINARY" - | docker cp - "$inspector:/tmp"

info="$(docker start -a "$inspector")"

fail=0
built="$(awk 'NR == 1 { print $2 }' <<<"$info")"
if [ "$built" != "go$GO_VERSION" ]; then
  echo "FAIL $BINARY built with $built, want go$GO_VERSION" >&2
  fail=1
else
  echo "ok   toolchain $built"
fi

for spec in $GO_MODULES; do
  mod="${spec%@*}"
  want="${spec#*@}"
  # `dep` lines list the module as used; `=>` lines carry a replacement's version.
  got="$(awk -v m="$mod" '$1 == "dep" && $2 == m { print $3 }' <<<"$info")"
  if [ -z "$got" ]; then
    echo "skip $mod not linked into $BINARY"
  elif [ "$(printf '%s\n%s\n' "$want" "$got" | sort -V | head -1)" != "$want" ]; then
    echo "FAIL $mod $got, want >= $want" >&2
    fail=1
  else
    echo "ok   $mod $got"
  fi
done

exit "$fail"
