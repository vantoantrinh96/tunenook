#!/usr/bin/env bash
# Versioning helpers for CI, driven by Conventional Commit PR titles.
#
#   scripts/release.sh level "<PR title>"   prints major | minor | patch | none
#   scripts/release.sh highest              reads PR titles (one per line) on stdin,
#                                           prints the biggest bump among them
#   scripts/release.sh current              prints the version in project.yml
#   scripts/release.sh bump <level>         bumps project.yml, prints the new version
set -euo pipefail

PROJECT_FILE="${PROJECT_FILE:-project.yml}"
TITLE_PATTERN='^(feat|fix|perf|refactor|docs|test|ci|chore|build|style|revert)(\([A-Za-z0-9 ._/-]+\))?(!)?: .+'

level() {
    local title="$1"
    if [[ ! "$title" =~ $TITLE_PATTERN ]]; then
        echo "invalid"
        return 1
    fi
    local type="${BASH_REMATCH[1]}" breaking="${BASH_REMATCH[3]}"
    if [[ -n "$breaking" ]]; then
        echo "major"
    elif [[ "$type" == "feat" ]]; then
        echo "minor"
    elif [[ "$type" == "fix" || "$type" == "perf" ]]; then
        echo "patch"
    else
        echo "none"
    fi
}

highest() {
    local best=none title level
    while IFS= read -r title || [[ -n "$title" ]]; do
        [[ -z "$title" ]] && continue
        level=$(level "$title") || continue # titles that don't parse don't release
        case "$best:$level" in
            major:*|*:none) ;;
            minor:major|patch:major|none:major) best=major ;;
            patch:minor|none:minor) best=minor ;;
            none:patch) best=patch ;;
        esac
    done
    echo "$best"
}

current() {
    sed -nE 's/^ *MARKETING_VERSION: "?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/p' "$PROJECT_FILE" | head -1
}

build_number() {
    sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' "$PROJECT_FILE" | head -1
}

bump() {
    local level="$1" version major minor patch
    version="$(current)"
    IFS=. read -r major minor patch <<<"$version"
    case "$level" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "unknown level: $level" >&2; return 1 ;;
    esac
    local next="$major.$minor.$patch" build
    build=$(( $(build_number) + 1 ))
    sed -i.bak -E \
        -e "s/^( *MARKETING_VERSION: ).*/\1\"$next\"/" \
        -e "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$build\"/" \
        "$PROJECT_FILE"
    rm -f "$PROJECT_FILE.bak"
    echo "$next"
}

case "${1:-}" in
    level) level "${2:-}" ;;
    highest) highest ;;
    current) current ;;
    bump) bump "${2:-}" ;;
    *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
