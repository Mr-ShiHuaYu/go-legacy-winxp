#!/usr/bin/env bash
# Regenerate patches/0099-Add-Windows-XP-support.patch from xp-files.list.
# Usage: regenerate-xp-patch.sh <win7-base-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="$ROOT/scripts/xp-files.list"
OUT="$ROOT/patches/0099-Add-Windows-XP-support.patch"

usage() {
  echo "usage: $0 <win7-base-dir>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
BASE="$(cd "$1" && pwd)"

if [[ ! -f "$LIST" ]]; then
  echo "missing $LIST" >&2
  exit 1
fi

read_list() {
  local f="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s\n' "$line"
  done <"$f"
}

mapfile -t FILES < <(read_list "$LIST")
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no paths in $LIST" >&2
  exit 1
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/regen-xp-patch.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

body="$tmpdir/body"
: >"$body"

for rel in "${FILES[@]}"; do
  left="$BASE/$rel"
  right="$ROOT/$rel"
  if [[ ! -f "$right" ]]; then
    echo "missing in tree: $rel" >&2
    exit 1
  fi
  # A file that does not exist in the win7 base is new XP-only code; diff it
  # against /dev/null so the patch creates it.
  newfile=0
  if [[ ! -f "$left" ]]; then
    newfile=1
    left=/dev/null
  fi
  # git diff --no-index exits 1 when files differ
  set +e
  git -C "$ROOT" diff --no-index -- "$left" "$right" >"$tmpdir/hunk"
  rc=$?
  set -e
  if [[ $rc -gt 1 ]]; then
    echo "git diff failed for $rel (exit $rc)" >&2
    exit 1
  fi
  if [[ $rc -eq 0 ]]; then
    echo "warning: no diff for $rel (tree matches win7 base)" >&2
    continue
  fi
  # Rewrite paths to a/rel and b/rel (git --no-index uses absolute paths).
  # New files keep their "--- /dev/null" header.
  if [[ $newfile -eq 1 ]]; then
    sed -E \
      -e "s|^diff --git a/.* b/.*|diff --git a/${rel} b/${rel}|" \
      -e "s|^\\+\\+\\+ .*|+++ b/${rel}|" \
      "$tmpdir/hunk" >>"$body"
  else
    sed -E \
      -e "s|^diff --git a/.* b/.*|diff --git a/${rel} b/${rel}|" \
      -e "s|^--- .*|--- a/${rel}|" \
      -e "s|^\\+\\+\\+ .*|+++ b/${rel}|" \
      "$tmpdir/hunk" >>"$body"
  fi
done

if [[ ! -s "$body" ]]; then
  echo "no XP diffs generated against $BASE" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
{
  cat <<'EOF'
From: go-legacy-winxp <maintainers@localhost>
Date: Mon, 31 Aug 2026 00:00:00 +0000
Subject: [PATCH 0010] Add Windows XP support

Preserve Windows XP compatibility: PE 5.1 targeting and dynamic
loading of Vista+ APIs.
---
EOF
  cat "$body"
} >"$OUT"

echo "wrote $OUT"
