#!/usr/bin/env bash
# Fail when a workflow or action references something by a mutable ref.
#
#   uses: owner/repo[/path]@<40 lowercase hex>      (also reusable workflows)
#   uses: ./local/path
#   uses: docker://image@sha256:<64 hex>
#   *_IMAGE: / image: values must be pinned with @sha256:<64 hex>
#
# A SHA pin without a trailing "# vX" comment only produces a warning.
#
# Usage: check-pins.sh [file...]
# With no arguments it scans .github/workflows/* and every action.yml/action.yaml
# (the test fixtures under .github/pin-check-fixtures are skipped).
# SC2094: the helpers only print; they never write to the file being read.
# SC2016: the single-quoted ${{ is a literal match, not an expansion.
# shellcheck disable=SC2094,SC2016
set -euo pipefail

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(
    { find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
      find . -path ./.git -prune -o -path ./.github/pin-check-fixtures -prune -o \
        -type f \( -name action.yml -o -name action.yaml \) -print
    } | sed 's|^\./||' | sort -u
  )
fi

sha_re='^[^[:space:]@]+/[^[:space:]@]+@[0-9a-f]{40}$'
docker_re='^docker://[^[:space:]@]+@sha256:[0-9a-f]{64}$'
image_re='^[^[:space:]@]+@sha256:[0-9a-f]{64}$'
version_re='#[[:space:]]*v?[0-9]'

# "- uses: 'x'  # c", "uses: x # c"  ->  value in group 1, rest of line in group 2
uses_re="^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*(\"([^\"]*)\"|'([^']*)'|[^[:space:]#]+)(.*)$"
# "FOO_IMAGE: x", "image: x"
image_key_re="^[[:space:]]*(-[[:space:]]+)?([A-Za-z0-9_]*_IMAGE|image):[[:space:]]*(\"([^\"]*)\"|'([^']*)'|[^[:space:]#]+)(.*)$"

errors=0
warnings=0
fail() { echo "ERROR $1:$2: $3"; errors=$((errors + 1)); }
warn() { echo "WARN  $1:$2: $3"; warnings=$((warnings + 1)); }

for f in "${files[@]}"; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in [[:space:]]'#'*|'#'*) continue ;; esac

    if [[ $line =~ $uses_re ]]; then
      ref=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
      [ -n "$ref" ] || ref=${BASH_REMATCH[2]}
      rest=${BASH_REMATCH[5]}
      if [[ $ref == ./* ]]; then
        :
      elif [[ $ref =~ $docker_re ]]; then
        :
      elif [[ $ref =~ $sha_re ]]; then
        [[ $rest =~ $version_re ]] || warn "$f" "$n" "pinned to a SHA but no '# vX' version comment: $ref"
      else
        fail "$f" "$n" "uses is not pinned to a commit SHA (or sha256 digest): $ref"
      fi
    elif [[ $line =~ $image_key_re ]]; then
      ref=${BASH_REMATCH[4]}${BASH_REMATCH[5]}
      [ -n "$ref" ] || ref=${BASH_REMATCH[3]}
      rest=${BASH_REMATCH[6]}
      if [[ $ref =~ $image_re ]]; then
        [[ $rest == *'#'* ]] || warn "$f" "$n" "image digest has no version comment: $ref"
      elif [[ $ref == *'${{'* || $ref == '$'* ]]; then
        :  # value comes from elsewhere; the source of that value is checked on its own line
      else
        fail "$f" "$n" "container image is not pinned by @sha256:<64 hex>: $ref"
      fi
    fi
  done < "$f"
done

echo "pin check: ${#files[@]} file(s), $errors error(s), $warnings warning(s)"
[ "$errors" -eq 0 ]
