#!/usr/bin/env bash

set -euo pipefail

# Purpose: Ensure a GitHub release exists and upload VM image asset(s) to it.
#
# Behaviors:
# - Auto-detects tag from image distro and current month (e.g. jammy-rt-2026-05) if not provided
# - Ensures authenticated gh session; prefers non-interactive token if available
# - Creates the release if missing (with --generate-notes)
# - Uploads provided files or auto-discovers the latest built image(s)
#
# Usage examples:
#   scripts/utils/upload-image.sh --tag jammy-rt-2026-05 artifacts/images/servobox-jammy-rt-6.8.0-rt8.qcow2.xz
#   GITHUB_TOKEN=... scripts/utils/upload-image.sh --all
#   scripts/utils/upload-image.sh                 # auto-tag, auto-latest asset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Defaults
RELEASE_REPO="${RELEASE_REPO:-kvasios/servobox-images}"
TAG="${RELEASE_TAG:-}"
NOTES=""
DISCOVERY_ROOT="${REPO_ROOT}/artifacts/images"
GLOB_PATTERN=""   # if provided, overrides default discovery patterns
UPLOAD_ALL=false   # if true, upload all discovered assets; else newest only

log() { printf "[upload-image] %s\n" "$*"; }
err() { printf "[upload-image][error] %s\n" "$*" 1>&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--repo OWNER/REPO] [--tag TAG] [--glob PATTERN] [--all] [--notes TEXT] [FILES...]

Options:
  --repo OWNER/REPO
                  GitHub repository to upload to. Defaults to ${RELEASE_REPO}.
  --tag TAG       Release tag (e.g. jammy-rt-2026-05). Defaults to RELEASE_TAG, or auto-derived from the image and current month.
  --glob PATTERN  Glob used to discover assets (rooted at ${DISCOVERY_ROOT}). Implies discovery mode.
  --all           Upload all discovered assets instead of only the newest one.
  --notes TEXT    Extra text to include in generated release notes (only when creating release).
  -h, --help      Show this help.

Positional FILES:
  One or more files to upload. If omitted, script will auto-discover image assets under ${DISCOVERY_ROOT}.

Auth:
  Uses existing gh auth session. If not authenticated and GITHUB_TOKEN is set, logs in non-interactively.
  If still not authenticated and running in an interactive TTY, will invoke web-based login.
EOF
}

is_interactive() { [[ -t 0 && -t 1 ]]; }

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --repo)
        shift; RELEASE_REPO="${1:-}" || true; [[ -n "$RELEASE_REPO" ]] || die "--repo requires a value"
        ;;
      --tag)
        shift; TAG="${1:-}" || true; [[ -n "$TAG" ]] || die "--tag requires a value"
        ;;
      --glob)
        shift; GLOB_PATTERN="${1:-}" || true; [[ -n "$GLOB_PATTERN" ]] || die "--glob requires a value"
        ;;
      --all)
        UPLOAD_ALL=true
        ;;
      --notes)
        shift; NOTES="${1:-}" || true; [[ -n "$NOTES" ]] || die "--notes requires a value"
        ;;
      -h|--help)
        usage; exit 0
        ;;
      --)
        shift; break
        ;;
      -*)
        die "Unknown option: $arg"
        ;;
      *)
        # Positional file
        break
        ;;
    esac
    shift || true
  done
  # Remaining args are files
  REMAINING_FILES=("$@")
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

infer_tag_from_asset() {
  local asset_path="$1"
  local asset_name
  asset_name="$(basename -- "$asset_path")"

  # Expected image name: servobox-<ubuntu>-rt-<kernel>.qcow2.xz
  local ubuntu
  ubuntu="$(printf "%s" "$asset_name" | sed -n 's/^servobox-\([^-]\+\)-rt-.*/\1/p')"
  [[ -n "$ubuntu" ]] || return 1

  printf "%s-rt-%s" "$ubuntu" "$(date +%Y-%m)"
}

ensure_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "Authenticating to GitHub using GITHUB_TOKEN"
    # shellcheck disable=SC2312
    if printf "%s" "$GITHUB_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
      return 0
    else
      err "Token-based authentication failed."
    fi
  fi

  if is_interactive; then
    log "Launching browser-based GitHub login (grant 'repo' scope)"
    gh auth login -w -s "repo" || die "GitHub authentication failed"
    return 0
  fi

  die "Not authenticated to GitHub. Set GITHUB_TOKEN or run interactively to login."
}

ensure_release() {
  local tag="$1"
  if gh release view "$tag" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    log "Release $tag exists in $RELEASE_REPO"
    return 0
  fi
  log "Creating release $tag in $RELEASE_REPO with generated notes"
  if [[ -n "$NOTES" ]]; then
    gh release create "$tag" --repo "$RELEASE_REPO" --generate-notes --notes "$NOTES" >/dev/null
  else
    gh release create "$tag" --repo "$RELEASE_REPO" --generate-notes >/dev/null
  fi
}

discover_assets() {
  local -a files=()

  if [[ ${#REMAINING_FILES[@]} -gt 0 ]]; then
    for f in "${REMAINING_FILES[@]}"; do
      [[ -f "$f" ]] || die "File not found: $f"
      files+=("$f")
    done
    printf '%s\n' "${files[@]}"
    return 0
  fi

  [[ -d "$DISCOVERY_ROOT" ]] || die "Discovery root not found: $DISCOVERY_ROOT"

  local find_expr
  if [[ -n "$GLOB_PATTERN" ]]; then
    # Use provided simple glob pattern(s), comma-separated
    IFS=',' read -r -a patterns <<< "$GLOB_PATTERN"
    for pat in "${patterns[@]}"; do
      while IFS= read -r -d '' p; do files+=("$p"); done < <(find "$DISCOVERY_ROOT" -type f -path "$DISCOVERY_ROOT/$pat" -print0 2>/dev/null || true)
    done
  else
    # Default pattern: only compressed qcow2 images
    while IFS= read -r -d '' p; do files+=("$p"); done < <(
      find "$DISCOVERY_ROOT" -type f \
        \( -name "*.qcow2.xz" \) \
        -print0 2>/dev/null || true
    )
  fi

  [[ ${#files[@]} -gt 0 ]] || die "No assets discovered under $DISCOVERY_ROOT"

  if $UPLOAD_ALL; then
    printf '%s\n' "${files[@]}"
    return 0
  fi

  # Pick newest single file
  local newest
  # shellcheck disable=SC2010
  newest="$(ls -1t -- "${files[@]}" 2>/dev/null | head -n1 || true)"
  [[ -n "$newest" ]] || die "Failed to determine newest asset"
  printf '%s\n' "$newest"
}

upload_assets() {
  local tag="$1"; shift
  local -a assets=("$@")
  log "Uploading ${#assets[@]} asset(s) to $RELEASE_REPO release $tag"
  gh release upload "$tag" "${assets[@]}" --repo "$RELEASE_REPO" --clobber
}

main() {
  parse_args "$@"

  require_cmd gh

  ensure_gh_auth

  mapfile -t ASSETS < <(discover_assets)

  if [[ -z "$TAG" ]]; then
    TAG="$(infer_tag_from_asset "${ASSETS[0]}" || true)"
  fi
  [[ -n "$TAG" ]] || die "Release tag not provided and could not be inferred from image name"

  ensure_release "$TAG"

  # Safety: refuse to upload extremely large sets by accident unless --all
  if ! $UPLOAD_ALL && [[ ${#ASSETS[@]} -gt 1 ]]; then
    # Should not happen because discover_assets returns one when --all not set
    ASSETS=("${ASSETS[0]}")
  fi

  upload_assets "$TAG" "${ASSETS[@]}"
  log "Done."
}

main "$@"


