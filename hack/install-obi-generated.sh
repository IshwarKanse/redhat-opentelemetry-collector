#!/bin/sh
# Copy the pre-generated OBI eBPF artifacts (obi-generated/) into the OBI source tree (.obi-src).
#
# The artifacts are not generated in the build: the OBI release generates them with its pinned
# toolchain (clang 22), see the README. Generating them here with the clang of the golang builder
# image (clang 17) produces an eBPF program that the verifier of the RHEL 5.14 kernel rejects
# ("BPF program is too large"), so the obi receiver cannot trace anything.
#
# Needs no network access, so it works in the hermetic ART build.
#
# Usage: hack/install-obi-generated.sh [obi-source-dir]   (default: .obi-src)
set -eu

cd "$(dirname "$0")/.."
OBI_DIR="${1:-.obi-src}"
OVERLAY=obi-generated

[ -f "${OBI_DIR}/go.mod" ] || { echo "ERROR: ${OBI_DIR} is empty or not an OBI source tree, run: git submodule update --init" >&2; exit 1; }
[ -f "${OVERLAY}/OBI_VERSION" ] || { echo "ERROR: ${OVERLAY}/OBI_VERSION is missing, run: make update-obi-generated" >&2; exit 1; }

manifest_version="$(awk '/- gomod: go\.opentelemetry\.io\/obi / {print $NF; exit}' manifest.yaml)"
overlay_version="$(tr -d '[:space:]' < "${OVERLAY}/OBI_VERSION")"
if [ -z "${manifest_version}" ] || [ "${manifest_version}" != "${overlay_version}" ]; then
  echo "ERROR: manifest.yaml has OBI '${manifest_version}', but ${OVERLAY} was generated for '${overlay_version}'." >&2
  echo "       Run: make update-obi-generated" >&2
  exit 1
fi

# The artifacts are only valid for the eBPF C sources they were generated from. This catches an OBI source that was
# moved without refreshing obi-generated, even when manifest.yaml was not changed.
expected_hash="$(tr -d '[:space:]' < "${OVERLAY}/BPF_SOURCES_SHA256" 2>/dev/null || true)"
actual_hash="$(sh hack/obi-bpf-sources-hash.sh "${OBI_DIR}")"
if [ -z "${expected_hash}" ] || [ "${expected_hash}" != "${actual_hash}" ]; then
  echo "ERROR: the eBPF sources of ${OBI_DIR} (${actual_hash}) are not the ones that ${OVERLAY} was generated from (${expected_hash:-none})." >&2
  echo "       Check out the OBI tag of manifest.yaml in ${OBI_DIR} and run: make update-obi-generated" >&2
  exit 1
fi

echo "Installing the pre-generated OBI ${overlay_version} eBPF artifacts into ${OBI_DIR}"
cp -R "${OVERLAY}/." "${OBI_DIR}/"
rm -f "${OBI_DIR}/OBI_VERSION" "${OBI_DIR}/BPF_SOURCES_SHA256"
