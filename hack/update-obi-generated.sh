#!/bin/bash
# Refresh (or check) obi-generated/ from the generated source tarball of the OBI release in manifest.yaml.
#
# The OBI release publishes obi-<version>-source-generated.tar.gz, the source with all generated eBPF
# artifacts, produced with OBI's pinned toolchain. This is also what the upstream collector build uses.
# Only the eBPF objects and their Go wrappers (*_bpfel.o, *_bpfel.go) are taken from it. The script fails when the
# tarball has other generated files that it does not handle, so that a new kind of generated file is not dropped silently.
# The tarball also ships a rebuilt obi-java-agent.jar, which differs from the one committed in the OBI source. The build
# has always used the committed one, so it is not taken here.
#
# Usage: hack/update-obi-generated.sh [update|check]   (default: update)
#   update  replace obi-generated/ with the files of the release tarball
#   check   fail when obi-generated/ differs from the release tarball (the checksum is verified too)
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-update}"
OBI_DIR="${OBI_DIR:-.obi-src}"
OVERLAY=obi-generated

fail() { echo "ERROR: $*" >&2; exit 1; }
[ "${MODE}" = update ] || [ "${MODE}" = check ] || fail "usage: $0 [update|check]"

version="$(awk '/- gomod: go\.opentelemetry\.io\/obi / {print $NF; exit}' manifest.yaml)"
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "could not read an OBI release version from manifest.yaml (got '${version}')"

# The artifacts only fit the source of the release, so the submodule must be at the tag of that release.
[ -d "${OBI_DIR}/.git" ] || [ -f "${OBI_DIR}/.git" ] || fail "${OBI_DIR} is not checked out, run: git submodule update --init"
if ! git -C "${OBI_DIR}" rev-parse -q --verify "refs/tags/${version}^{commit}" >/dev/null; then
  git -C "${OBI_DIR}" fetch --depth 1 origin "refs/tags/${version}:refs/tags/${version}"
fi
tag_commit="$(git -C "${OBI_DIR}" rev-parse "refs/tags/${version}^{commit}")"
head_commit="$(git -C "${OBI_DIR}" rev-parse HEAD)"
[ "${tag_commit}" = "${head_commit}" ] || fail "${OBI_DIR} is at ${head_commit}, not at the tag ${version} (${tag_commit}). Check it out and rerun."

base="https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/releases/download/${version}"
tarball="obi-${version}-source-generated.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Fetching ${tarball}"
curl --fail --show-error --silent --location --retry 3 --retry-delay 1 --output "${tmp}/${tarball}" "${base}/${tarball}"
curl --fail --show-error --silent --location --retry 3 --retry-delay 1 --output "${tmp}/SHA256SUMS" "${base}/SHA256SUMS"

expected="$(awk -v f="${tarball}" '{n=$2; sub(/^\*/, "", n); if (n == f) {print $1; exit}}' "${tmp}/SHA256SUMS")"
[ -n "${expected}" ] || fail "${tarball} is not listed in SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "${tmp}/${tarball}" | awk '{print $1}')"; else actual="$(shasum -a 256 "${tmp}/${tarball}" | awk '{print $1}')"; fi
[ "${expected}" = "${actual}" ] || fail "checksum of ${tarball} does not match SHA256SUMS (expected ${expected}, got ${actual})"
echo "SHA256 verified: ${tarball}"

mkdir -p "${tmp}/src" "${tmp}/overlay"
tar xzf "${tmp}/${tarball}" --strip-components=1 -C "${tmp}/src"

# eBPF objects and their Go wrappers only. Keep the paths relative to the OBI root.
(cd "${tmp}/src" && find . -type f \( -name '*_bpfel.o' -o -name '*_bpfel.go' \) | sort | sed 's#^\./##') > "${tmp}/files.txt"
count="$(wc -l < "${tmp}/files.txt" | tr -d ' ')"
[ "${count}" -gt 0 ] || fail "the tarball has no eBPF artifacts"
while read -r f; do
  case "${f}" in
    *.o) [ -f "${tmp}/src/${f%.o}.go" ] || fail "${f} has no Go wrapper in the tarball" ;;
    *.go) [ -f "${tmp}/src/${f%.go}.o" ] || fail "${f} has no eBPF object in the tarball" ;;
  esac
done < "${tmp}/files.txt"

# Every file of the tarball that is new or different compared to the OBI source must be handled above (or be a dependency
# file or the Java agent), otherwise a new kind of generated file would be left out.
unhandled="$(diff -rq -x .git "${OBI_DIR}" "${tmp}/src" 2>/dev/null | awk -v base="${tmp}/src" '
  /^Only in / { dir = $3; sub(/:$/, "", dir); if (index(dir, base) == 1) { p = substr(dir, length(base) + 2); print (p == "" ? $4 : p "/" $4) } }
  /^Files / { n = split($0, a, " and "); f = a[2]; sub(/ differ$/, "", f); if (index(f, base) == 1) print substr(f, length(base) + 2) }
' | sort | grep -v -x -F -f "${tmp}/files.txt" | grep -v '\.d$' | grep -v -x 'pkg/internal/java/embedded/obi-java-agent.jar' || true)"
[ -z "${unhandled}" ] || fail "the tarball has generated files that are not copied, extend this script: $(echo "${unhandled}" | tr '\n' ' ')"

(cd "${tmp}/src" && tar -cf - -T "${tmp}/files.txt") | tar -xf - -C "${tmp}/overlay"
printf '%s\n' "${version}" > "${tmp}/overlay/OBI_VERSION"
sh hack/obi-bpf-sources-hash.sh "${OBI_DIR}" > "${tmp}/overlay/BPF_SOURCES_SHA256"

if [ "${MODE}" = check ]; then
  diff -r "${tmp}/overlay" "${OVERLAY}" >/dev/null || fail "${OVERLAY} differs from ${tarball}, run: make update-obi-generated"
  echo "${OVERLAY} matches ${tarball} (${count} files)"
else
  rm -rf "${OVERLAY}"
  mv "${tmp}/overlay" "${OVERLAY}"
  echo "Updated ${OVERLAY} for OBI ${version}: ${count} files"
fi
