#!/usr/bin/env bash
# Compiles and runs the markup-leak check. See check-markup-leaks.swift.
#
# Any .md given as an argument is added to the corpus, so a document that ever
# renders badly can be kept covered from then on.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
# swiftc only allows top-level statements in a file called main.swift.
cp "$root/Scripts/check-markup-leaks.swift" "$build/main.swift"
swiftc -O "$build/main.swift" "$root/OCRFlow/Views/MathSyntax.swift" -o "$build/check"
"$build/check" "$@"
