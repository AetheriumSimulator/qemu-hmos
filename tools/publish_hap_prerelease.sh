#!/usr/bin/env bash
# Only the main-push release job calls this after independent evidence verification.
set -euo pipefail
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_EVENT_NAME:?}"
: "${GITHUB_REF:?}"
[[ "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF" == refs/heads/main ]]
assets=${1:?delivery directory required}
tag="test-${GITHUB_SHA}"
# Reject a pre-existing tag pointing at another revision (or an annotated tag).
if tagged=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" --jq '.object.sha' 2>/dev/null); then
  [[ "$tagged" == "$GITHUB_SHA" ]]
fi
# Never replace an existing tag or release asset. A rerun verifies prior delivery.
if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  existing=$(mktemp -d)
  trap 'rm -rf "$existing"' EXIT
  gh release download "$tag" --repo "$GITHUB_REPOSITORY" --dir "$existing"
  for name in aetherium-unsigned.hap aetherium-source.tar.gz release-evidence.json; do
    cmp "$assets/$name" "$existing/$name"
  done
  if [[ $(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft) == true ]]; then
    gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease
  fi
  echo "Existing release matches this delivery: $tag"
  exit 0
fi
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<EOF
Unsigned Aetherium test HAP for $GITHUB_SHA.

Not signed for device installation; no device/guest-boot acceptance is claimed.
The accompanying source candidate and hash-bound review evidence passed the
repository distribution verifier for this build. See release-evidence.json for
payload identities, source members, exact fetched revisions, SDK archive hashes
and review scope. Only the HAP is delivered as a binary; no separate SO or UEFI
binary assets are published.
EOF
# A draft prevents a partially uploaded asset set from becoming a public release.
gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
  --draft --prerelease --title "Unsigned Aetherium test ${GITHUB_SHA:0:12}" \
  --notes-file "$notes" \
  "$assets/aetherium-unsigned.hap" "$assets/aetherium-source.tar.gz" "$assets/release-evidence.json"
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease
