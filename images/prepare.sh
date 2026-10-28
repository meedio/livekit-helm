#!/usr/bin/env bash
# Prepare the Docker build context for one patched LiveKit image.
#
#   images/prepare.sh <image> <out-dir>
#
# <image> is a directory under images/ (livekit-server, ingress, egress). The script
#  1. clones the upstream release tag and fails unless it resolves to UPSTREAM_COMMIT,
#  2. raises GO_MODULES in go.mod/go.sum with the GO_VERSION toolchain,
#  3. pins the Go version, bakes BUILD_ARGS into the Dockerfile and pins every external
#     image to the digest in PINNED_IMAGES (it fails on any unpinned image),
#  4. appends an OS package refresh to the final stage.
# Set SECURITY_REFRESH to a fixed value to reuse a cached package refresh layer.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
name="${1:?usage: prepare.sh <image> <out-dir>}"
out="${2:?usage: prepare.sh <image> <out-dir>}"

# shellcheck source=common.env
. "$here/common.env"
# shellcheck source=/dev/null
. "$here/$name/image.env"

refresh="${SECURITY_REFRESH:-$(date -u +%Y%m%dT%H%M%SZ)}"

if [ -e "$out" ]; then
  echo "$out already exists" >&2
  exit 1
fi

echo "==> Cloning $UPSTREAM_REPO $UPSTREAM_TAG"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$out"
commit="$(git -C "$out" rev-parse HEAD)"
if [ "$commit" != "$UPSTREAM_COMMIT" ]; then
  echo "$UPSTREAM_TAG resolves to $commit, expected $UPSTREAM_COMMIT" >&2
  exit 1
fi
rm -rf "$out/.git"

modules="$(echo $GO_MODULES)"
if [ -n "$modules" ]; then
  echo "==> Raising Go modules: $modules"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$out:/src" -w /src \
    -e HOME=/tmp -e GOPATH=/tmp/go -e GOCACHE=/tmp/gocache \
    -e GOTOOLCHAIN=local -e GOFLAGS=-mod=mod \
    "$GO_IMAGE" sh -euc "go get $modules && go mod tidy"

  names=""
  for spec in $modules; do names="$names ${spec%@*}"; done
  have="$(docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$out:/src" -w /src \
    -e HOME=/tmp -e GOPATH=/tmp/go -e GOCACHE=/tmp/gocache \
    -e GOTOOLCHAIN=local \
    "$GO_IMAGE" sh -euc "go list -m $names")"
  for spec in $modules; do
    mod="${spec%@*}"
    want="${spec#*@}"
    got="$(awk -v m="$mod" '$1 == m { print $2 }' <<<"$have")"
    if [ -z "$got" ] || [ "$(printf '%s\n%s\n' "$want" "$got" | sort -V | head -1)" != "$want" ]; then
      echo "$mod resolved to '${got:-missing}', need >= $want" >&2
      exit 1
    fi
    echo "    $mod $got"
  done
fi

if [ -f "$out/.go-version" ]; then
  echo "$GO_VERSION" >"$out/.go-version"
fi

dockerfile="$out/$DOCKERFILE"
echo "==> Rewriting $DOCKERFILE"
BUILD_ARGS="$(echo $BUILD_ARGS)" PINNED_IMAGES="$(echo $PINNED_IMAGES)" perl -i -pe '
  BEGIN {
    %args = map { split /=/, $_, 2 } split " ", $ENV{BUILD_ARGS};
    @pins = split " ", $ENV{PINNED_IMAGES};
  }
  for my $k (keys %args) {
    s/^\s*ARG\s+\Q$k\E(=\S*)?\s*$/ARG $k=$args{$k}\n/;
  }
  if (/^\s*FROM\s/i || /--from=/) {
    for my $k (keys %args) {
      s/\$\{\Q$k\E\}|\$\Q$k\E\b/$args{$k}/g;
    }
    for my $pin (@pins) {
      my ($ref) = split /@/, $pin;
      s/(^\s*FROM\s+|--from=)\Q$ref\E(?=\s|$)/$1$pin/i;
    }
  }
' "$dockerfile"

# Every FROM / COPY --from must name a stage or a digest-pinned image.
perl -ne '
  push @stages, lc $1 if /^\s*FROM\s.*\sAS\s+(\S+)/i;
  my @refs;
  push @refs, $1 if /^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)/i;
  push @refs, $1 while /--from=(\S+)/g;
  for my $r (@refs) {
    next if $r =~ /^\d+$/ || grep { $_ eq lc $r } @stages;
    if ($r =~ /\$/ || $r !~ /\@sha256:[0-9a-f]{64}$/) { print STDERR "unpinned image: $r\n"; $bad = 1 }
  }
  END { exit($bad ? 1 : 0) }
' "$dockerfile"

case "$OS_REFRESH" in
  apk) refresh_cmd='apk upgrade --no-cache' ;;
  apt) refresh_cmd='apt-get update && apt-get -y dist-upgrade && apt-get clean && rm -rf /var/lib/apt/lists/*' ;;
  *) echo "unknown OS_REFRESH: $OS_REFRESH" >&2; exit 1 ;;
esac
{
  echo
  echo "# Added by meedio/livekit-helm images/prepare.sh: pull current OS security"
  echo "# updates. The ARG value changes per build so the registry cache never serves it stale."
  echo "USER root"
  echo "ARG MEEDIO_SECURITY_REFRESH=$refresh"
  echo "RUN $refresh_cmd"
  if [ -n "$RUNTIME_USER" ]; then
    echo "USER $RUNTIME_USER"
  fi
} >>"$dockerfile"

image="$REGISTRY/$REGISTRY_PROJECT/$APP_NAME:$IMAGE_TAG"
echo "==> Ready: $out ($DOCKERFILE) for $image"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "app-name=$APP_NAME"
    echo "image-tag=$IMAGE_TAG"
    echo "image=$image"
    echo "dockerfile=$dockerfile"
    echo "context=$out"
  } >>"$GITHUB_OUTPUT"
fi
