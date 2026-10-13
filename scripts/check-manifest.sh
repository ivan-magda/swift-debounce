#!/bin/sh
# Fails if the root package would pull anything extra into apps that depend on it:
# no dependencies, no unsafe flags, and only the Debounce and DebounceSwiftUI library products.
set -eu
cd "$(dirname "$0")/.."
swift package dump-package | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
problems = []
if manifest["dependencies"]:
    problems.append("the root package must not have dependencies")
if "unsafeFlags" in json.dumps(manifest["targets"]):
    problems.append("the root package must not use unsafeFlags")
products = [p["name"] for p in manifest["products"]]
if products != ["Debounce", "DebounceSwiftUI"]:
    problems.append(f"expected only the Debounce and DebounceSwiftUI products, found {products}")
for problem in problems:
    print("error:", problem)
sys.exit(1 if problems else 0)
'
echo "Root manifest is clean."
