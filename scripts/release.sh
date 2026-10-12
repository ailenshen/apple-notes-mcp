#!/bin/sh
# Bumps the npm package version, commits, and tags v<version>. Pushing the tag starts
# .github/workflows/publish.yml, which builds, signs and publishes the app to npm.
# Usage: scripts/release.sh 2.0.0-beta.2 && git push && git push --tags
set -eu
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/release.sh <version>}
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
sed -i '' "s/\"version\": *\"[^\"]*\"/\"version\": \"$version\"/" npm/package.json
git add npm/package.json
git diff --cached --quiet || git commit -m "$version"  # the version may already be set
git tag "v$version"
echo "tagged v$version; push with: git push && git push --tags"
