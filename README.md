# 100 Desktop UI & Shader Demos

[![Build](https://github.com/yogaontheway/100desktopuidemos/actions/workflows/build.yml/badge.svg)](https://github.com/yogaontheway/100desktopuidemos/actions/workflows/build.yml)

A curated collection of 100 desktop UI components, interactive effects, and shaders for macOS/iOS built with SwiftUI & Metal.

A monorepo of 100 desktop interaction effects and UI components built with **SwiftUI + Metal (MSL)**. Every demo lives in its own folder and is fully self-contained — no shared dependencies between demos.

## Requirements

- **Xcode 27+** / macOS 26.6+ (the projects are saved by Xcode 27 as *project file format 110*; older Xcode versions cannot open them)
- Metal needs no extra toolchain — every shader is an MSL string compiled at runtime

## CI

Every push to `main` and every pull request triggers an automatic build of all Xcode projects and Swift packages in the repo (`.github/workflows/build.yml`, running on the `xcode-27` runner image). New demos are discovered automatically — no configuration change needed.

## Demos

| # | Demo | Stack / Highlights | Preview | Source |
| :---: | :--- | :--- | :--- | :--- |
| **001** | Black Hole Trashcan | Metal shader, tidal disruption, accretion disk flow, unified occlusion field | ![preview](./001-black-hole-trashcan/preview.gif) | [source](./001-black-hole-trashcan/) |
| **002** | … | … | … | … |

## Adding a demo

1. Create an `NNN-demo-name/` folder containing a standalone Xcode project or playground;
2. Record a `preview.gif` of the demo actually running and put it in that folder;
3. Add one row to the demo table in this README.

## Version tags

When a demo reaches a stable, reproducible state, it gets an annotated tag named `demo-name-vNN` — for example `black-hole-v17` (Demo 001, the unified occlusion field version).

---

Every demo is an independent experiment. The code is free to use.
