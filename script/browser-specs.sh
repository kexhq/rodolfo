#!/bin/sh
# Runs every example's browser specs (`spec/browser/`) with its own
# `tey test:browser`, and fails if any of them failed. Headless by default;
# SHAKESPEARE_WATCH=1 (what `tey test:watch` sets) opens a visible, paced
# Chrome instead. Name examples to run only those:
#
#   sh script/browser-specs.sh library chat
set -u
cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
  set -- $(for spec in examples/*/spec/browser; do basename "$(dirname "$(dirname "$spec")")"; done)
fi

failed=""
for example in "$@"; do
  echo "== $example"
  (cd "examples/$example" && tey test:browser) || failed="$failed $example"
done

if [ -n "$failed" ]; then
  echo "Browser specs failed in:$failed" >&2
  exit 1
fi
