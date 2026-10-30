#!/bin/sh
# Installs a pinned shfmt release (the shell parser the review gate's Bash checks will use, claude-ship #135) as
# <dest-file>: scripts/fetch-shfmt.sh <dest-file>. Downloads the release asset for this machine, checks it against
# the sha256 pinned below, and moves it into place atomically. Nothing is installed when the check fails, and an
# existing <dest-file> is then left untouched. When <dest-file> already has the pinned hash, nothing is downloaded.
# Linux x86_64 and aarch64/arm64 only. Needs curl and sha256sum (or shasum).
# Exit: 0 installed or already current; 1 unsupported machine, no hash tool, download failed or hash mismatch;
# 2 usage (docs/scripts.md).
set -eu

version=v3.14.1
# sha256 of the official release assets (https://github.com/mvdan/sh/releases/tag/v3.14.1). mvdan/sh publishes no
# checksum file; these come from downloading each asset over https and running sha256sum on it. To bump the
# version, do the same for the new tag and change all three lines together. There is deliberately no way to skip
# or override the check.
sha256_linux_amd64=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
sha256_linux_arm64=5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
	echo "usage: fetch-shfmt.sh <dest-file>" >&2
	exit 2
fi
dest=$1

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
Linux/x86_64) asset=linux_amd64 want=$sha256_linux_amd64 ;;
Linux/aarch64 | Linux/arm64) asset=linux_arm64 want=$sha256_linux_arm64 ;;
*)
	echo "fetch-shfmt: unsupported platform $os/$arch (only Linux x86_64 and aarch64/arm64)." >&2
	exit 1
	;;
esac

# hash_of <file>: prints the file's sha256. Each step's status is checked (a pipe would hide a failure).
hash_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		out=$(sha256sum "$1") || return 1
	elif command -v shasum >/dev/null 2>&1; then
		out=$(shasum -a 256 "$1") || return 1
	else
		return 1
	fi
	printf '%s\n' "${out%% *}"
}
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
	echo "fetch-shfmt: needs sha256sum or shasum to check the download." >&2
	exit 1
fi

if [ -f "$dest" ]; then
	have=$(hash_of "$dest") || have=
	if [ "$have" = "$want" ]; then
		# The bytes are right but the mode may not be (a copy without its execute bit): restore it.
		chmod 755 "$dest" || {
			echo "fetch-shfmt: couldn't make $dest executable." >&2
			exit 1
		}
		echo "fetch-shfmt: $dest is current (shfmt $version)."
		exit 0
	fi
fi

# Next to <dest-file>, so the final mv stays on one filesystem and replaces it atomically.
dir=$(dirname "$dest")
tmp=$(mktemp "$dir/.shfmt.XXXXXX") || {
	echo "fetch-shfmt: can't create a temporary file in $dir." >&2
	exit 1
}
trap 'rm -f "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

url=https://github.com/mvdan/sh/releases/download/$version/shfmt_${version}_$asset
if ! curl -fsSL --retry 2 --proto '=https' --proto-redir '=https' -o "$tmp" "$url"; then
	echo "fetch-shfmt: couldn't download $url." >&2
	exit 1
fi
got=$(hash_of "$tmp") || {
	echo "fetch-shfmt: couldn't compute the sha256 of the download." >&2
	exit 1
}
if [ "$got" != "$want" ]; then
	echo "fetch-shfmt: sha256 mismatch for $url: got $got, wanted $want. Nothing installed." >&2
	exit 1
fi
chmod 755 "$tmp"
mv -f "$tmp" "$dest"
echo "fetch-shfmt: installed shfmt $version to $dest."
