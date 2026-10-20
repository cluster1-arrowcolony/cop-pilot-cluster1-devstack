#!/usr/bin/env bash
# Download the pinned CLI tools into .devstack/bin, checked against checksums.txt. Docker is the
# only host prerequisite.
#
#   tools.sh [up]        install the tools
#   tools.sh checksums   rewrite checksums.txt from the upstream checksum files after a version
#                        bump in versions.env; review the diff before committing it
source "$(dirname "$0")/lib.sh"

CHECKSUMS="$ROOT/checksums.txt"
TOOLS="k3d kubectl helm colonies"
PLATFORMS="linux/amd64 linux/arm64 darwin/amd64 darwin/arm64"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# version <tool>: its pinned version, from <TOOL>_VERSION in versions.env.
version() {
	local var
	var="$(echo "$1" | tr '[:lower:]' '[:upper:]')_VERSION"
	echo "${!var}"
}

# url <tool> <os> <arch>: where the pinned version of the tool is downloaded from.
url() {
	case "$1" in
	k3d) echo "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-$2-$3" ;;
	kubectl) echo "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$2/$3/kubectl" ;;
	helm) echo "https://get.helm.sh/helm-$HELM_VERSION-$2-$3.tar.gz" ;;
	colonies) echo "https://github.com/colonyos/colonies/releases/download/$COLONIES_VERSION/colonies_${COLONIES_VERSION#v}_$2_$3.tar.gz" ;;
	esac
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# upstream_sum <tool> <os> <arch>: the checksum the tool's release publishes for that download.
# Runs inside $(...), where bash 3.2 ignores set -e, so the steps check their own status.
upstream_sum() {
	local u
	u="$(url "$@")" || return
	case "$1" in
	k3d) curl -fsSL "${u%/*}/checksums.txt" | awk -v f="_dist/${u##*/}" '$2 == f { print $1 }' ;;
	kubectl) curl -fsSL "$u.sha256" ;;
	helm) curl -fsSL "$u.sha256sum" | awk '{ print $1 }' ;;
	colonies) curl -fsSL "${u%/*}/colonies_${COLONIES_VERSION#v}_checksums.txt" | awk -v f="${u##*/}" '$2 == f { print $1 }' ;;
	esac
}

checksums() {
	local tool platform sum
	need curl awk
	{
		echo "# sha256 of every download scripts/tools.sh makes: <tool> <version> <os>/<arch> <sha256>."
		echo "# Written by 'make checksums' from the upstream checksum files after a version bump."
		for tool in $TOOLS; do
			for platform in $PLATFORMS; do
				sum="$(upstream_sum "$tool" "${platform%/*}" "${platform#*/}")" ||
					die "cannot fetch the upstream checksum of $tool $(version "$tool") $platform"
				[[ "$sum" =~ ^[0-9a-f]{64}$ ]] ||
					die "no upstream checksum for $tool $(version "$tool") $platform"
				echo "$tool $(version "$tool") $platform $sum"
			done
		done
	} >"$tmp/checksums.txt"
	mv "$tmp/checksums.txt" "$CHECKSUMS"
	ok "wrote checksums.txt; review the diff and commit it with versions.env"
}

# expected <tool>: the checksum of the tool's download for this platform, from checksums.txt.
expected() {
	awk -v t="$1" -v v="$(version "$1")" -v p="$os/$arch" \
		'$1 == t && $2 == v && $3 == p { print $4 }' "$CHECKSUMS"
}

# have <tool>: true if this version, with this checksum, was installed here before (see stamp).
have() { [[ -x "$BIN/$1" && "$(cat "$BIN/.$1.version" 2>/dev/null)" == "$(version "$1") $(expected "$1")" ]]; }
stamp() { echo "$(version "$1") $(expected "$1")" >"$BIN/.$1.version"; }

# fetch_checked <tool> <file>: download the tool for this platform and check its checksum.
fetch_checked() {
	local want got
	want="$(expected "$1")"
	[[ -n "$want" ]] ||
		die "checksums.txt has no entry for $1 $(version "$1") $os/$arch; run 'make checksums' after changing a version"
	fetch "$(url "$1" "$os" "$arch")" "$2"
	got="$(sha256 "$2")"
	[[ "$got" == "$want" ]] || die "checksum mismatch for $1 $(version "$1") $os/$arch: got $got, expected $want"
}

up() {
	need docker curl tar awk
	command -v sha256sum >/dev/null || need shasum
	docker info >/dev/null 2>&1 || die "docker is not running (or you lack access to its socket)"

	if ! have k3d; then
		info "k3d $K3D_VERSION"
		fetch_checked k3d "$tmp/k3d"
		chmod +x "$tmp/k3d"
		mv "$tmp/k3d" "$BIN/k3d"
		stamp k3d
	fi

	if ! have kubectl; then
		info "kubectl $KUBECTL_VERSION"
		fetch_checked kubectl "$tmp/kubectl"
		chmod +x "$tmp/kubectl"
		mv "$tmp/kubectl" "$BIN/kubectl"
		stamp kubectl
	fi

	if ! have helm; then
		info "helm $HELM_VERSION"
		fetch_checked helm "$tmp/helm.tgz"
		tar -xzf "$tmp/helm.tgz" -C "$tmp"
		mv "$tmp/$os-$arch/helm" "$BIN/helm"
		stamp helm
	fi

	if ! have colonies; then
		info "colonies $COLONIES_VERSION"
		fetch_checked colonies "$tmp/colonies.tgz"
		mkdir "$tmp/colonies"
		tar -xzf "$tmp/colonies.tgz" -C "$tmp/colonies"
		mv "$(find "$tmp/colonies" -type f -name colonies | head -1)" "$BIN/colonies"
		chmod +x "$BIN/colonies"
		stamp colonies
	fi

	ok "tools in $BIN: k3d $K3D_VERSION, kubectl $KUBECTL_VERSION, helm $HELM_VERSION, colonies $COLONIES_VERSION (checksums verified)"
}

case "$(uname -s)" in
Linux) os=linux ;;
Darwin) os=darwin ;;
*) die "unsupported OS $(uname -s); use Linux, macOS or WSL2" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
arm64 | aarch64) arch=arm64 ;;
*) die "unsupported architecture $(uname -m)" ;;
esac

case "${1:-up}" in
up) up ;;
checksums) checksums ;;
*) die "usage: tools.sh [up|checksums]" ;;
esac
