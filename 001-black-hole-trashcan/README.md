# 001 · Black Hole Trashcan

Drag a file into the window and its card is torn apart by the black hole's tidal force into three glowing filaments. They wind along the spin direction, fall inward, spread into an accretion disk, and are finally devoured — roughly 3 seconds end to end, all in a single Metal shader.

![preview](./preview.gif)

## Run it

```bash
cd BlackHole
open BlackHole.xcodeproj   # then Cmd+R in Xcode
```

Drag any file onto the window to trigger the effect.

## How it works

- **Unified matter flow field** (`renderStream`): filaments and disk are not two separate layers — a filament is freshly infalling matter (narrow and hot), the disk is its sediment (viscous spreading, `width ∝ √age`). Tearing, winding, disk formation and dissipation are all driven by one time function.
- **Continuous tidal disruption**: no slicing, no fan-out. The card is stretched and brightened by a continuous deformation field; 28 slice nodes are tiled and a 48-segment arc-length table is inverted to keep it seamless.
- **Gravitational anchoring**: the birth point is the grab point, passed to the shader in polar coordinates. The filament head advances along `φ = ω·u^1.45`; the handoff to the disk uses a time-reversed mirrored spiral for C1 continuity (no kink).
- **Unified occlusion field (v17)**: a single soft boundary `occ = smoothstep(1.0·Rsh, 1.55·Rsh, r)` darkens the surroundings in all directions, with a near-side azimuthal exemption so foreground bands can sweep in front of the hole and occlude the lower part of the horizon. This removes the "chimera" gaps caused by several suppression contours overlapping.
- **Doppler beaming**: the side turning toward the observer brightens (×3.2), the receding side dims, giving the disk a physically plausible asymmetric brightness.
- **Gravitational lensing approximation**: Schwarzschild radial remapping plus azimuthal bending lifts the far side of the disk above the horizon.

## Key parameters

| Parameter | Value | Meaning |
| :-- | :-- | :-- |
| `DUR` | 3.0 s | Total duration of the devouring sequence |
| `OMEGA` | 19 rad | Total angular travel of the spiral |
| `RISCO` | 0.265 | Disk inner edge (innermost stable circular orbit, in screen-height units) |
| `diskIncline` | 0.62 | Disk inclination cosI (smaller = more edge-on) |
| `FIL_GAIN / SED_GAIN` | 2.6 / 0.34 | Filament brightness / sediment disk brightness |
| `shardCount` | 28 | Number of disruption slices |

## Layout

```
001-black-hole-trashcan/
├── BlackHole/                  # full Xcode project (SwiftUI + Metal)
│   ├── BlackHole.xcodeproj
│   └── BlackHole/BlackHoleApp.swift   # all logic and the MSL shader live in this one file
├── blackhole_preview.html      # WebGL2 port (open directly in a browser; ships with a
│                               #   timeline and parameter sliders, used for frame-by-frame
│                               #   shader verification on machines without Metal)
├── preview.gif                 # recorded run
└── README.md
```

## Iteration history

The shader went through 17 rounds (v1 playground prototype → v17 unified occlusion field), each stage focused on one thing:
disruption shape (v4–v5) → ring timing (v6–v8) → joint continuity (v7, v9–v10) → hole/disk spacing (v11–v14) → performance (v12) → seam removal (v13, v16) → unified occlusion field (v17).
