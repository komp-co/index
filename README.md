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

Open a pull request that adds the file, or appends a `[[version]]` to it.
A maintainer of the komp-co organisation approves every new package name; a
new version of an existing package is reviewed the same way. Before approving,
the reviewer checks that the source fetches, that a tarball matches its
checksum, and that `komp check` passes on the crate at that source.
