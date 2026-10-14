# RHOSDT OpenTelemetry Collector Distribution

This repository configures a build of the OpenTelemetry Collector with the supported components for a Red Hat OpenShift distributed tracing product.

## Update collector version

1. Update Makefile and manifest.yaml to select the desired upstream version and component selection for the product release. 
1. Run `make build generate-schemas` or `make build-in-podman`
1. Update changelog in [RPM spec](./opentelemetry-collector.spec.in)
1. Create a pull request with the changes, including changes in the `_build` directory.

## Update OBI version

The OpenTelemetry eBPF Instrumentation (OBI) receiver is pinned in three places
that must be kept in sync:

- **`manifest.yaml`** declares the module version, e.g. `go.opentelemetry.io/obi v0.10.0`.
- **`.obi-src`** is a git submodule (see [`.gitmodules`](./.gitmodules)) pinned to the tag of
  that version. A `replace` directive in `manifest.yaml`
  (`go.opentelemetry.io/obi => ../.obi-src`) redirects the module to this local
  checkout, so the submodule commit is what actually gets built.
- **`obi-generated/`** holds the pre-generated eBPF artifacts (`*_bpfel.o` and their Go
  wrappers) of that version. They are copied over `.obi-src` before the build
  (`hack/install-obi-generated.sh`, run by `Dockerfile.art` and `make generate-obi`).

The eBPF artifacts are not generated in our build. The OBI release generates them with its
pinned toolchain (clang 22) and publishes them in `obi-<version>-source-generated.tar.gz`,
which is also what the upstream collector build uses. Generating them with the clang of the
golang builder image (clang 17) produces an eBPF program that the verifier of the RHEL 5.14
kernel rejects (`BPF program is too large. Processed 1000001 insn`), so the `obi` receiver
traces nothing on OpenShift 4.x (ART-24676). The ART build is hermetic, so the artifacts are
committed here instead of being downloaded during the build.

To bump to a new OBI release (e.g. `v0.11.0`):

1. Move the submodule to the matching upstream tag:
   ```
   git -C .obi-src fetch --tags
   git -C .obi-src checkout v0.11.0
   git add .obi-src
   ```
1. Update the module version string in [`manifest.yaml`](./manifest.yaml) to match
   (`go.opentelemetry.io/obi v0.11.0`).
1. Run `make update-obi-generated`. It downloads the generated source tarball of that
   release, verifies it against the `SHA256SUMS` of the release, and refreshes
   `obi-generated/`. `make verify-obi-generated` checks that `obi-generated/` still matches
   the release.
1. Run `make build generate-schemas` or `make build-in-podman`. This updates the contents of
   the `_build` directory.
1. Create a pull request with the changes, including the updated submodule pointer,
   `manifest.yaml`, `obi-generated/` and the `_build` directory. A build fails when
   `obi-generated/` was generated for another OBI version than the one in `manifest.yaml`, or
   from other eBPF sources than the ones in `.obi-src` (`obi-generated/OBI_VERSION` and
   `obi-generated/BPF_SOURCES_SHA256` record both).

The OBI release tarball also contains a rebuilt `obi-java-agent.jar`, which differs from the
one committed in the OBI source. The build keeps using the committed jar, as it always did,
so only the eBPF artifacts are taken from the release.

The number and the order of the `FROM` lines of `Dockerfile.art` have to match `from.builder`
of the image config in ocp-build-data, so keep them when you change the Dockerfile.

## Release

```
git tag v0.48.0 && git push origin v0.48.0
```

## RPM

To build `srpm` and `rpm`s we used [packit](https://packit.dev/).

```
# build srpm 
make clean packit/srpm

# build rpm (includes srpm)
make clean packit/rpm/mock
```

## Install from Copr

```
dnf copr enable frzifus/redhat-opentelemetry-collector-main 
dnf install -y opentelemetry-collector
```

## Tests

The end-to-end tests are located at [openshift/distributed-tracing-qe/tests/e2e-otel](https://github.com/openshift/distributed-tracing-qe/tree/main/tests/e2e-otel).