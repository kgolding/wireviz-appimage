# WireViz AppImage builder

Packages [WireViz](https://github.com/wireviz/WireViz) — a Python CLI tool
for documenting cables and wiring harnesses — as a portable AppImage that
runs on most Linux distros without needing Python or Graphviz installed
system-wide.

## Why this exists

WireViz ships as a PyPI package (`pip install wireviz`), not a compiled
binary, so there's no upstream AppImage. This script builds one by:

1. Creating an embedded Python venv inside the AppDir and `pip install`ing
   `wireviz` into it.
2. Copying a `dot` (Graphviz) binary and its shared libraries into the
   AppDir, since WireViz shells out to Graphviz to render diagrams.
3. Wrapping everything with an `AppRun` script that sets `PATH`,
   `LD_LIBRARY_PATH`, and `GVBINDIR` so the bundled Python and Graphviz
   are used instead of (or in absence of) any system copies.
4. Running `appimagetool` to produce `wireviz-0.41.AppImage`.

## Requirements (on the build machine)

- Linux x86_64
- Internet access
- `python3` + `python3-venv`
- `wget`
- `sudo apt-get` available as a fallback if Graphviz isn't already
  installed (only used to fetch `dot` for bundling — feel free to swap
  this for your distro's package manager, e.g. `dnf`/`pacman`)

This sandbox has no network access, so the script hasn't been executed
here — run it yourself with:

```bash
chmod +x build-appimage.sh
./build-appimage.sh            # builds the latest known-good version (0.4.1)
./build-appimage.sh 0.4.1      # or pin an explicit wireviz PyPI version
```

Output: `build/wireviz-0.41.AppImage`

## Using the result

```bash
./wireviz-0.41.AppImage path/to/myharness.yml
```

This behaves exactly like the `wireviz` CLI — same flags, same `--help`.

## Automated builds via GitHub Actions

`.github/workflows/build-appimage.yml` watches the upstream
[wireviz/WireViz](https://github.com/wireviz/WireViz) repo and does the
packaging for you:

- **Schedule**: runs daily (`cron: '17 6 * * *'`), checks
  `wireviz/WireViz`'s latest GitHub release via the API.
- **Skips redundant work**: if a release already exists in *this* repo
  for that WireViz version (tagged `wireviz-<version>`), the build is
  skipped.
- **Manual runs**: trigger via the Actions tab (`workflow_dispatch`),
  optionally specifying an exact `version` input to force-build (this
  always rebuilds even if a matching release already exists, useful for
  fixing a broken artifact).
- **Also runs on push** to `main` when the build script or workflow
  file itself changes, so you can verify edits immediately.
- **Outputs**:
  - A build artifact (`wireviz-appimage-<version>`) attached to the
    workflow run, downloadable from the Actions tab.
  - A GitHub Release tagged `wireviz-<version>` with the `.AppImage`
    file attached, linking back to the corresponding upstream release.

To use it:
1. Commit `build-appimage.sh` and this workflow file to your repo (paths
   matter — the workflow expects `build-appimage.sh` at the repo root).
2. No extra secrets are needed; it uses the default `GITHUB_TOKEN` to
   check/create releases.
3. Optionally adjust the cron schedule or the base image
   (`ubuntu-22.04`) in the workflow to suit your compatibility needs.

## Notes / things you may want to tweak

- **Icon**: the script generates a plain placeholder PNG so
  `appimagetool` doesn't complain about a missing icon. Swap in a real
  logo by replacing `usr/share/icons/hicolor/256x256/apps/wireviz.png`
  and the top-level `wireviz.png` before packing.
- **Graphviz portability**: bundling `dot`'s shared-lib dependencies via
  `ldd` works well when the build machine's glibc is reasonably close to
  the target machines'. For maximum compatibility, build on an older
  base (e.g. Ubuntu 20.04 or the `appimagecrafters/appimage-builder`
  Docker image) so the bundled glibc symbols stay backward-compatible.
- **Pinning WireViz**: pass a specific version as the first argument, or
  edit the script to `pip install -e .` against a local git checkout of
  the `dev` branch if you want the AppImage to track unreleased code.
- **Terminal app**: WireViz is a CLI, so the `.desktop` entry sets
  `Terminal=true` — double-clicking the AppImage in a file manager will
  open a terminal. This is normal for CLI-style AppImages.
