# hew

hew builds and installs software from source.  Run `hew install PKGs...`.  The PKG tells hew where to get the source (i.e. `github.com/marler8997/msi`).

Install hew on Linux/macOS with:

```sh
sh -c "$(curl -fSL https://gethew.github.io/sh)"
```

Install hew on Windows:

```sh
powershell -c "irm https://gethew.github.io/ps1 | iex"
```

Those install commands download a small script which in turn downloads a prebuilt hew binary and executes `hew install github.com/hew-org/hew`.

# Package Format

```
PKG = HOST/REPO_PATH[,VERSION][,FORGE]
    | path:PATH

HOST = github.com      # these hosts have a known FORGE
     | gitlab.com
     | codeberg.org
     | git.sr.ht
     | (any other)     # requires FORGE

FORGE = github         # github.com or GitHub Enterprise
      | gitlab
      | forgejo        # Forgejo or Gitea, i.e. codeberg.org
      | srht           # sourcehut, i.e. git.sr.ht

VERSION = (omitted)    # in this priority tries latest release, tag or commit on the default branch
        | rev=REVSPEC  # specific tag/commit
        | tip          # latest commit on default branch
```

### Examples:

```sh
hew install github.com/marler8997/msi
hew install github.com/marler8997/msi,rev=v1.0
hew install github.com/marler8997/msi,rev=a8033245765dc3ec94cfe0d6f4f9d7725700c5b9
hew install github.com/marler8997/msi,tip
hew install git.mycompany.com/team/tool,gitlab
```

# Why install from source?

**For users:** pre-built binaries target the lowest common denominator. Building from source lets the compiler optimize for your specific CPU, OS, and architecture.

**For developers:** your source code *is* your distribution. No release workflows, no storing pre-built assets, no wrangling a matrix of OS/arch combinations. Push your code and your users can install it.
