# Patched LiveKit images

Upstream LiveKit images can ship vulnerable Go modules or OS packages that a chart bump
cannot fix. This directory rebuilds a pinned upstream release with patched modules and
pushes it to Harbor, so the charts can pin the result by digest.

| Image | Upstream | Harbor repository |
|---|---|---|
| `livekit-server` | `livekit/livekit` | `registry.meedio.eu/meedio/livekit-server-image` |
| `ingress` | `livekit/ingress` | `registry.meedio.eu/meedio/livekit-ingress-image` |
| `egress` | `livekit/egress` | `registry.meedio.eu/meedio/livekit-egress-image` |

The `-image` suffix keeps images apart from the Helm charts, which Harbor stores under
`registry.meedio.eu/meedio/<chart>`.

## How a build works

`images/<image>/image.env` is the whole recipe. [`prepare.sh`](prepare.sh) turns it into a
build context:

1. Clone `UPSTREAM_TAG` and stop unless it resolves to `UPSTREAM_COMMIT`.
2. `go get` every `GO_MODULES` entry with the Go `GO_VERSION` toolchain ([`common.env`](common.env)),
   then `go mod tidy`. It stops if any module resolves below the listed version.
3. Write `GO_VERSION` to `.go-version` when upstream has one. Bake `BUILD_ARGS` into the
   Dockerfile as `ARG` defaults; the shared build action takes no build args.
4. Pin every external image to its `PINNED_IMAGES` digest. It stops on any image left unpinned.
5. Append an `apk upgrade` or `apt-get dist-upgrade` to the final stage, keyed on a fresh
   timestamp so the registry build cache never serves stale packages.

[`verify.sh`](verify.sh) copies the binary out of the built image and checks `go version -m`
for the Go version and the module versions.

[`.github/workflows/images.yaml`](../.github/workflows/images.yaml) runs both:

- **Pull request**: prepare, build, verify and Grype-scan each image. Nothing is pushed.
- **master**: build with `meedio/actions/docker-build@v3` (SBOM, Dependency-Track, Grype,
  push, Cosign sign), verify, and write the digest to the run summary. A tag that already
  exists in Harbor is skipped, so a digest a chart pins is never overwritten.

## Rebuild or update an image

1. Edit `image.env`: the upstream tag and commit, module versions, or pinned base images.
2. Bump the `-meedio.N` suffix of `IMAGE_TAG`. Bump it for an OS package refresh alone too.
3. Open a PR and read the Grype summary of each check job.
4. After merge, copy the digest from the master run summary into the chart's
   `values.yaml` (`image.repository`, `image.digest`) and `Chart.yaml` (`appVersion`, `version`).

Build one image locally (Docker with buildx):

```bash
images/prepare.sh egress .build/egress
```

```bash
docker buildx build --load -t egress:local -f .build/egress/build/egress/Dockerfile .build/egress
```

```bash
images/verify.sh egress egress:local
```

The build context must be under a directory Docker can bind-mount; `.build/` is gitignored.
