#!/bin/sh
# Print one SHA-256 over all files of the eBPF C sources (bpf/) of an OBI source tree.
# The pre-generated artifacts in obi-generated/ are only valid for these exact sources.
#
# Usage: hack/obi-bpf-sources-hash.sh <obi-source-dir>
set -eu

dir="${1:?usage: $0 <obi-source-dir>}"
[ -d "${dir}/bpf" ] || { echo "ERROR: ${dir}/bpf does not exist, ${dir} is not an OBI source tree" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then sum() { sha256sum; }; else sum() { shasum -a 256; }; fi

(cd "${dir}" && find bpf -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sum < "$f" | awk '{print $1}')" "$f"; done) | sum | awk '{print $1}'
