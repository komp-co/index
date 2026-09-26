# The KFlat package index

The index komp reads when a `kf.toml` asks for a package by version:

```toml
[dependencies]
json = "0.1"
```

komp clones this repository into its cache, picks the highest version the
requirement allows, fetches that version's `source`, and records the result in
the project's `kf.lock`. A build with a lock never reads the index.

## Layout

One file per package, named after it and placed by its name:

| Name length | Path |
|---|---|
| 1 | `1/<name>.toml` |
| 2 | `2/<name>.toml` |
| 3 | `3/<first letter>/<name>.toml` |
| 4 or more | `<letters 1-2>/<letters 3-4>/<name>.toml` |

So `json` is `js/on/json.toml` and `yml` is `3/y/yml.toml`. Names are
lowercase `snake_case`, because a crate name becomes a C identifier.

## An entry

```toml
schema = 1
name = "json"

[[version]]
version = "0.1.0"
source = { git = "https://github.com/komp-co/json", rev = "f1bd0aee61045540f52524d793c075cbb091cb2e" }

[[version]]
version = "0.0.9"
source = { tarball = "https://example.org/json-0.0.9.tar.gz" }
checksum = "sha256:<hex digest>"
yanked = true
```

- `source` is a `git` repository with the full commit `rev`, or a `tarball`
  with its `checksum`. Never a tag or a branch alone: those can move, and an
  entry records exactly what was reviewed.
- `deps` lists the index packages a version needs, as `{ name = "0.2" }`.
  `core`, `alloc` and `std` come with komp and are never listed.
- `yanked = true` keeps a version resolvable for projects that already lock
  it, and hides it from new resolution.
- Versions are appended, never edited: a published version is immutable.

## Adding a package or a version

In the package's repository, with the version in `kf.toml` tagged `vX.Y.Z`
and pushed:

```console
$ komp publish
```

It writes the entry, pinned to the tagged commit, and opens the pull request
here through `gh`; `komp publish --status` shows where it stands. A pull
request written by hand is checked the same way.

Every pull request is checked by `.github/workflows/check-entries.yml` with the
latest released komp: each new version is fetched at its pinned commit or
checksum, must be the package and version its entry says, and must pass
`komp check`. Then:

- **A trusted version bump merges itself**: a pull request that only appends
  versions to packages whose line in [`trusted.toml`](trusted.toml) names its
  author.
- **Everything else waits for a maintainer** of the komp-co organisation: a new
  package, an edit to a published version, a change to `trusted.toml`, this
  README or the checks. A maintainer approves every new package name.

A pull request cannot change how it is judged: the checks run as they are on
`main`, and never run anything from the pull request.
