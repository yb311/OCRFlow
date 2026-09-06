#!/usr/bin/env bash
# Installs the llama.cpp xcframework that powers the PaddleOCR-VL engine.
#
# The binary is ~86 MB, so it is not committed; run this once after cloning.
# The build is pinned: upgrading llama.cpp is an explicit edit to LLAMA_BUILD
# here, never a silent drift the next time somebody runs this.
#
# Usage:
#   Scripts/fetch-llama-xcframework.sh            # download the prebuilt release
#   Scripts/fetch-llama-xcframework.sh --source   # build it from source instead
set -euo pipefail

LLAMA_BUILD="b10819"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor"
WORK=""
# Declared at file scope: the trap outlives the function that fills it in.
cleanup() { [[ -n "${WORK}" ]] && rm -rf "${WORK}"; }
trap cleanup EXIT
URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/llama-${LLAMA_BUILD}-xcframework.zip"

verify() {   # verify <path to llama.xcframework>
    local fw="$1/macos-arm64_x86_64/llama.framework"
    [[ -f "$fw/Headers/mtmd.h" ]] || { echo "✗ mtmd.h missing" >&2; return 1; }
    [[ -f "$fw/Headers/mtmd-helper.h" ]] || { echo "✗ mtmd-helper.h missing" >&2; return 1; }
    # The multimodal support is the whole point; a llama-only build is useless
    # here and would fail much later with confusing linker errors.
    local n
    n=$(nm -gU "$fw/Versions/A/llama" 2>/dev/null | grep -c "_mtmd_" || true)
    [[ "$n" -gt 0 ]] || { echo "✗ no mtmd symbols in the binary" >&2; return 1; }
    echo "✓ llama.xcframework ready — ${n} mtmd symbols, $(lipo -info "$fw/Versions/A/llama" | sed 's/.*: //')"
}

build_from_source() {
    command -v cmake >/dev/null || {
        echo "cmake is required to build from source: brew install cmake" >&2
        exit 1
    }
    WORK="$(mktemp -d)"
    echo "Cloning llama.cpp ${LLAMA_BUILD}…"
    git clone --depth 1 --branch "${LLAMA_BUILD}" https://github.com/ggml-org/llama.cpp "${WORK}/llama.cpp"
    ( cd "${WORK}/llama.cpp" && ./build-xcframework.sh macos )
    mkdir -p "${DEST}"
    rm -rf "${DEST}/llama.xcframework"
    cp -R "${WORK}/llama.cpp/build-apple/llama.xcframework" "${DEST}/"
}

download_release() {
    WORK="$(mktemp -d)"
    echo "Downloading llama.cpp ${LLAMA_BUILD} xcframework…"
    curl --fail --location --progress-bar -o "${WORK}/llama.zip" "${URL}"
    unzip -q "${WORK}/llama.zip" -d "${WORK}/x"
    mkdir -p "${DEST}"
    rm -rf "${DEST}/llama.xcframework"
    # The archive wraps the framework in build-apple/.
    mv "${WORK}/x/build-apple/llama.xcframework" "${DEST}/"
}

if [[ "${1:-}" == "--source" ]]; then
    build_from_source
else
    download_release
fi

verify "${DEST}/llama.xcframework"
echo "Installed to ${DEST}/llama.xcframework"
