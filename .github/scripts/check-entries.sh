#!/usr/bin/env bash
# Checks what a pull request changes in the index. Everything it reads from
# the pull request is data: it runs nothing the pull request contains.
#
#   check-entries.sh BASE HEAD AUTHOR KOMP
#
# Every new [[version]] is fetched at its pinned commit or checksum, must
# name the package and version its entry says, and must check as a
# dependency of a new project. A toolchain's (`kind = "toolchain"`) is a
# kflat release archive instead, holding kflat-<version>/install.sh and the
# VERSION it installs.
# Prints the verdict last:
#
#   trusted   only new versions of existing packages whose line in the
#             checked-out trusted.toml names AUTHOR
#   review    anything else, for a maintainer
#
# and exits 1 when an entry is invalid.
set -euo pipefail

base=$1 head=$2 author=$3 komp=$4
verdict=trusted
failed=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say() { echo "$*" >&2; }
invalid() { say "invalid: $*"; failed=1; }
needs_review() { say "review: $*"; verdict=review; }

# The path rule, as komp computes it.
expected_path() {
    local name=$1 n=${#1}
    if [ "$n" -le 2 ]; then echo "$n/$name.toml"
    elif [ "$n" -eq 3 ]; then echo "3/${name:0:1}/$name.toml"
    else echo "${name:0:2}/${name:2:2}/$name.toml"
    fi
}

# From the checked-out base branch as it is now, so revoking trust is
# immediate, and a pull request cannot trust itself.
trusts() {
    grep -Eq "^$1 *= *\[[^]]*\"$2\"" trusted.toml 2>/dev/null
}

# One line per [[version]] block: version|git|rev|tarball|checksum.
version_blocks() {
    awk '
        function flush() { if (inblock) print v "|" g "|" r "|" t "|" c }
        function quoted(key,   s) {
            s = $0
            if (!match(s, key " *= *\"[^\"]*\"")) return ""
            s = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s); return s
        }
        /^\[\[version\]\]/ { flush(); inblock = 1; v = g = r = t = c = ""; next }
        inblock && /^version *=/  { v = quoted("version") }
        inblock && /^source *=/   { g = quoted("git"); r = quoted("rev"); t = quoted("tarball") }
        inblock && /^checksum *=/ { c = quoted("checksum") }
        END { flush() }
    '
}

manifest_field() {
    sed -n "s/^$2 *= *\"\(.*\)\"/\1/p" "$1/kf.toml" | head -1
}

# Fetches one version into a fresh directory and prints the crate root.
fetch_version() {
    local git=$1 rev=$2 tarball=$3 checksum=$4 dir
    dir=$(mktemp -d "$work/source.XXXXXX")
    if [ -n "$git" ]; then
        git clone --quiet --no-checkout "$git" "$dir" >&2 &&
            git -C "$dir" checkout --quiet --detach "$rev" >&2 || return 1
        echo "$dir"
        return 0
    fi
    curl -fsSL -o "$dir.tar.gz" "$tarball" || return 1
    [ "sha256:$(sha256sum "$dir.tar.gz" | cut -d' ' -f1)" = "$checksum" ] || { say "checksum mismatch"; return 1; }
    tar -xzf "$dir.tar.gz" -C "$dir" || return 1
    if [ ! -f "$dir/kf.toml" ]; then
        rm -rf "$dir" && mkdir "$dir" && tar -xzf "$dir.tar.gz" -C "$dir" --strip-components=1 || return 1
    fi
    echo "$dir"
}

allowed_url() {
    case "$1" in
        https://*) return 0 ;;
        file://*) [ "${INDEX_CHECK_ALLOW_FILE_URLS:-}" = 1 ] ;;
        *) return 1 ;;
    esac
}

# A toolchain release archive, as `komp toolchain install` takes it.
check_toolchain_version() {
    local name=$1 line=$2 version git rev tarball checksum dir
    IFS='|' read -r version git rev tarball checksum <<< "$line"
    local what="$name $version"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { invalid "$what: version is not MAJOR.MINOR.PATCH"; return; }
    [ -z "$git" ] && [ -n "$tarball" ] || { invalid "$what: a toolchain's source is a tarball"; return; }
    allowed_url "$tarball" || { invalid "$what: tarball must be an https:// URL"; return; }
    [[ "$checksum" =~ ^sha256:[0-9a-f]{64}$ ]] || { invalid "$what: checksum must be sha256:<64 hex digits>"; return; }
    dir=$(mktemp -d "$work/toolchain.XXXXXX")
    curl -fsSL -o "$dir.tar.gz" "$tarball" || { invalid "$what: its archive could not be fetched"; return; }
    [ "sha256:$(sha256sum "$dir.tar.gz" | cut -d' ' -f1)" = "$checksum" ] || { invalid "$what: checksum mismatch"; return; }
    tar -xzf "$dir.tar.gz" -C "$dir" "kflat-$version/install.sh" "kflat-$version/VERSION" 2> /dev/null ||
        { invalid "$what: its archive holds no kflat-$version/install.sh and VERSION"; return; }
    [ "$(cat "$dir/kflat-$version/VERSION")" = "$version" ] || { invalid "$what: its archive installs another version"; return; }
    say "ok: $what"
}

check_version() {
    local name=$1 line=$2 version git rev tarball checksum root
    IFS='|' read -r version git rev tarball checksum <<< "$line"
    local what="$name $version"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { invalid "$what: version is not MAJOR.MINOR.PATCH"; return; }
    if [ -n "$git" ]; then
        allowed_url "$git" || { invalid "$what: git source must be an https:// URL"; return; }
        [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { invalid "$what: rev must be a full 40-character commit id"; return; }
    elif [ -n "$tarball" ]; then
        allowed_url "$tarball" || { invalid "$what: tarball must be an https:// URL"; return; }
        [[ "$checksum" =~ ^sha256:[0-9a-f]{64}$ ]] || { invalid "$what: checksum must be sha256:<64 hex digits>"; return; }
    else
        invalid "$what: source names neither git nor tarball"; return
    fi
    root=$(fetch_version "$git" "$rev" "$tarball" "$checksum") || { invalid "$what: its source could not be fetched"; return; }
    [ -f "$root/kf.toml" ] || { invalid "$what: its source has no kf.toml at its root"; return; }
    [ "$(manifest_field "$root" name)" = "$name" ] || { invalid "$what: its kf.toml names another crate"; return; }
    [ "$(manifest_field "$root" version)" = "$version" ] || { invalid "$what: its kf.toml has another version"; return; }
    checks_as_dependency "$name" "$git" "$rev" "$tarball" "$checksum" || { invalid "$what: komp check failed"; return; }
    say "ok: $what"
}

# A project depending on the version, checked as a user's would be: komp
# fetches it into a cache, where its own `core`, `alloc` and `std` are the
# ones bundled with komp, and compiles it as a dependency.
checks_as_dependency() {
    local name=$1 git=$2 rev=$3 tarball=$4 checksum=$5 probe libs row
    probe=$(mktemp -d "$work/probe.XXXXXX")
    # The libraries beside the kflatc komp runs, through the link an install leaves.
    libs=$(cd "$(dirname "$(readlink -f "$(dirname "$komp")/kflatc")")/../libs" && pwd)
    if [ -n "$git" ]; then row="$name = { git = \"$git\", rev = \"$rev\" }"
    else row="$name = { tarball = \"$tarball\", checksum = \"$checksum\" }"
    fi
    mkdir "$probe/src"
    printf '[project]\nname = "index_probe"\nkind = "lib"\n\n[dependencies]\n%s\ncore = { path = "%s/core" }\nalloc = { path = "%s/alloc" }\n' \
        "$row" "$libs" "$libs" > "$probe/kf.toml"
    printf 'pub fun index_probe(): int32 { return 0 }\n' > "$probe/src/lib.kf"
    KFLAT_CACHE="$work/cache" "$komp" check "$probe" >&2
}

while IFS=$'\t' read -r status path rest; do
    case "$path" in
        [0-9a-z_][0-9a-z_]/*.toml | [0-9a-z_]/*.toml) ;;
        *) needs_review "$path is not a package entry"; continue ;;
    esac
    name=$(basename "$path" .toml)
    if ! [[ "$name" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || [ "$path" != "$(expected_path "$name")" ]; then
        invalid "$path: not where the package \`$name\` belongs (expected $(expected_path "$name"))"
        continue
    fi
    case "$status" in
        D) needs_review "$path removes a package"; continue ;;
        A) needs_review "$path adds the package $name" ;;
        M) ;;
        *) needs_review "$path: $status"; continue ;;
    esac
    new=$(git show "$head:$path")
    old=$([ "$status" = M ] && git show "$base:$path" || true)
    if [ -n "$old" ] && [ "${new:0:${#old}}" != "$old" ]; then
        needs_review "$path changes a published version, not only appends"
        appended=$new
    else
        appended=${new:${#old}}
    fi
    grep -q '^schema = 1$' <<< "$new" || invalid "$path: schema is not 1"
    grep -q "^name = \"$name\"$" <<< "$new" || invalid "$path: name is not \"$name\""
    duplicates=$(version_blocks <<< "$new" | cut -d'|' -f1 | sort | uniq -d)
    [ -z "$duplicates" ] || invalid "$path: lists $duplicates more than once"
    trusts "$name" "$author" || needs_review "$author is not trusted to publish $name"
    blocks=$(version_blocks <<< "$appended")
    [ -n "$blocks" ] || needs_review "$path adds no version"
    check=check_version
    grep -q '^kind = "toolchain"$' <<< "$new" && check=check_toolchain_version
    while IFS= read -r line; do
        [ -n "$line" ] && "$check" "$name" "$line"
    done <<< "$blocks"
done < <(git diff --no-renames --name-status "$base" "$head")

[ "$failed" -eq 0 ] || exit 1
echo "$verdict"
