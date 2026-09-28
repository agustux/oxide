#!/bin/bash
# The Linux half of a release. release.sh runs on the Mac (DMGs, manifest,
# cask, site changelog) and GPUI can't be cross-compiled, so the tarball is
# built here, published to downloads.oxideterminal.com (R2) beside the DMGs,
# mirrored onto the same GitHub release, and added to the update manifest:
#
#   scripts/release-linux.sh            build, sign, upload, bump the AUR PKGBUILD
#   NO_UPLOAD=1 scripts/release-linux.sh   just build and bump
#
# Run it from the release commit (the one tagged v<version>), after
# release.sh has finished. Then push the AUR package:
#
#   cd packaging/aur/oxide-terminal-bin
#   makepkg --printsrcinfo > .SRCINFO
#   git -C <aur clone> ... (see RELEASING.md)
#
# One-time setup is in RELEASING.md ("One-time setup on the Linux box").
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)
TAG="v$VERSION"
ARCH=$(uname -m)
TARBALL="target/oxide-${VERSION}-linux-${ARCH}.tar.gz"
PKGBUILD="packaging/aur/oxide-terminal-bin/PKGBUILD"

BUCKET="${R2_BUCKET:-oxide-releases}"
DOWNLOADS="${DOWNLOADS_URL:-https://downloads.oxideterminal.com}"
UPDATE_KEY="${UPDATE_KEY:-$HOME/.config/oxide-release/update.key}"
PREFIX="oxide/$VERSION"
WRANGLER=(npx --yes wrangler)

# The binary must be what the tag describes. HEAD may sit past the tag as
# long as nothing that goes into the build changed since — docs commits
# after a release are fine, a source change is not.
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: no tag $TAG. Run release.sh on the Mac first, then: git fetch --tags" >&2
  exit 1
fi
if [[ "$(git describe --tags --exact-match 2>/dev/null || true)" != "$TAG" ]]; then
  if ! git diff --quiet "$TAG" HEAD -- Cargo.toml Cargo.lock src assets scripts/linux-package.sh packaging/docker; then
    echo "error: HEAD differs from $TAG in the sources. Build from the tag:" >&2
    echo "       git checkout $TAG" >&2
    exit 1
  fi
  echo "note: HEAD is past $TAG but the sources are identical; building anyway"
fi

if [[ -z "${NO_UPLOAD:-}" ]]; then
  # Everything the upload needs, checked before the slow build.
  command -v minisign >/dev/null || { echo "error: minisign not installed (pacman -S minisign)" >&2; exit 1; }
  command -v jq >/dev/null || { echo "error: jq not installed (pacman -S jq)" >&2; exit 1; }
  [[ -f "$UPDATE_KEY" ]] || { echo "error: update signing key $UPDATE_KEY not found (see RELEASING.md)" >&2; exit 1; }
  if ! "${WRANGLER[@]}" whoami 2>/dev/null | grep -q 'You are logged in'; then
    echo "error: wrangler isn't logged in (npx wrangler login)" >&2
    exit 1
  fi
  gh release view "$TAG" >/dev/null 2>&1 || {
    echo "error: release $TAG doesn't exist yet — run release.sh on the Mac first." >&2
    exit 1
  }
  # The Mac side writes the manifest; this script only adds to it.
  curl -fsS "$DOWNLOADS/releases/$VERSION.json" -o "target/manifest-$VERSION.json" || {
    echo "error: $DOWNLOADS/releases/$VERSION.json isn't there — release.sh didn't finish?" >&2
    exit 1
  }
  if curl -fsI "$DOWNLOADS/$PREFIX/$(basename "$TARBALL")" >/dev/null 2>&1; then
    echo "error: $DOWNLOADS/$PREFIX/ already has the $ARCH tarball; published files are never overwritten" >&2
    exit 1
  fi
fi

scripts/linux-package.sh
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

if [[ -z "${NO_UPLOAD:-}" ]]; then
  # Same shape as the DMG's signature: the trusted comment names the version
  # and platform, so a signature only ever vouches for the file it was made for.
  echo "==> signing the tarball"
  minisign -S -s "$UPDATE_KEY" -m "$TARBALL" -x "$TARBALL.minisig" \
    -t "oxide $VERSION linux-$ARCH" -c "Oxide $VERSION linux-$ARCH"
  minisign -V -p update.pub -m "$TARBALL" -x "$TARBALL.minisig" -q

  put() {  # put <local file> <key> <content-type> <cache-control>
    "${WRANGLER[@]}" r2 object put "$BUCKET/$2" --remote --file "$1" --content-type "$3" --cache-control "$4"
  }
  IMMUTABLE="public, max-age=31536000, immutable"
  NAME=$(basename "$TARBALL")

  echo "==> uploading to $DOWNLOADS/$PREFIX/"
  put "$TARBALL" "$PREFIX/$NAME" application/gzip "$IMMUTABLE"
  put "$TARBALL.minisig" "$PREFIX/$NAME.minisig" text/plain "$IMMUTABLE"
  curl -fsSI --retry 5 --retry-delay 3 --retry-all-errors "$DOWNLOADS/$PREFIX/$NAME" >/dev/null \
    || { echo "error: $DOWNLOADS/$PREFIX/$NAME isn't serving; not touching the manifest" >&2; exit 1; }

  echo "==> mirroring on GitHub"
  gh release upload "$TAG" "$TARBALL" --clobber

  # Add this build to the manifest. Only now, with the tarball confirmed
  # reachable, do installed Linux copies start announcing the release.
  echo "==> adding linux-$ARCH to the update manifest"
  jq --arg k "linux-$ARCH" --arg url "$DOWNLOADS/$PREFIX/$NAME" --arg sha "$SHA" \
     --rawfile sig "$TARBALL.minisig" \
     '.assets[$k] = {url: $url, sha256: $sha, signature: $sig}' \
     "target/manifest-$VERSION.json" > "target/manifest-$VERSION-linux.json"
  jq -e --arg k "linux-$ARCH" '.assets[$k].url' "target/manifest-$VERSION-linux.json" >/dev/null
  put "target/manifest-$VERSION-linux.json" "releases/$VERSION.json" application/json "$IMMUTABLE"
  # stable.json may already have moved on to a newer version (a hotfix on the
  # Mac before this ran); only replace it if it still describes this release.
  STABLE_VERSION=$(curl -fsS "$DOWNLOADS/releases/stable.json" | jq -r .version)
  if [[ "$STABLE_VERSION" == "$VERSION" ]]; then
    put "target/manifest-$VERSION-linux.json" "releases/stable.json" application/json "public, max-age=60"
  else
    echo "note: stable.json is at $STABLE_VERSION, not $VERSION; left it alone"
  fi
fi

# Bump the AUR PKGBUILD to this release. sha256 is the tarball's; pkgrel
# resets to 1 with each new version.
sed -i \
  -e "s/^pkgver=.*/pkgver=$VERSION/" \
  -e "s/^pkgrel=.*/pkgrel=1/" \
  -e "s#^source=.*#source=(\"$DOWNLOADS/oxide/\${pkgver}/oxide-\${pkgver}-linux-x86_64.tar.gz\")#" \
  -e "s/^sha256sums=.*/sha256sums=('$SHA')/" \
  "$PKGBUILD"
echo "bumped $PKGBUILD to $VERSION ($SHA)"
echo
echo "Next: commit the PKGBUILD, then publish it:"
echo "  cd packaging/aur/oxide-terminal-bin && makepkg --printsrcinfo > .SRCINFO"
echo "  (copy PKGBUILD + .SRCINFO into your AUR clone, commit, push)"
