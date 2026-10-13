#!/bin/sh
# Runs every benchmark in release mode and stores the results with the machine details.
# Usage: ./run.sh [output-directory]   (default: results/<date>)
set -eu
cd "$(dirname "$0")"
out="${1:-results/$(date +%Y-%m-%d)}"
mkdir -p "$out"

swift build -c release

{
    echo "- Date: $(date +%Y-%m-%d)"
    echo "- Machine: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores"
    echo "- OS: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "- Swift: $(swift --version 2>&1 | head -1)"
} > "$out/environment.md"

for bench in Storage Locks Throttling Latency Scenarios; do
    echo "Running $bench..."
    ".build/release/$bench" > "$out/$(echo "$bench" | tr '[:upper:]' '[:lower:]').md"
done
echo "Results in $out"
