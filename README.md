# Constellation AR

Point your iPhone at the sky and see the constellations drawn over the live camera — stars, figures, artwork, planets, satellites — aligned to the real sky and narrated.

Built for iOS 27 / iPhone 17 Pro Max with Swift 6 (strict concurrency), Metal and SwiftUI.

## Features

- **Live sky overlay** on the camera at 120 Hz: true-north attitude from Core Motion (100 Hz, interpolated to each frame's timestamp), per-frame camera intrinsics, refraction.
- **Constellation lock**: the constellation you point at locks in, draws itself in and shows its Stellarium artwork; a compact card expands to narration and a Gemma "tell me more" that starts automatically.
- **Tap to focus**: tap any part of the sky to pin the constellation whose IAU boundary contains it — dashed boundary, edge arrow when off screen, animated artwork outline, and an info sheet with tonight's rise/transit/set, brightest stars, deep-sky objects and planets inside it.
- **Grounded Q&A**: ask about the pinned constellation; answers cite retrieved passages (BM25) and are checked by a verifier (quotes, magnitudes, distances). Unsupported questions fall back to a clearly labelled general-knowledge answer.
- **Illustrated sky**: toggle gold artwork for every visible constellation.
- **Alignment**: tap the Sun, Moon, a bright planet or a star to correct the compass; at night, automatic alignment plate-solves the camera image (tetra3 / Cedar-Solve method) with a multi-star Wahba fit and a live ±accuracy readout.
- **Lenses**: 0.5×, 1× and 4×; daylight autofocus, locked far focus at night.
- **Sky-inspired visual style**: sparkle stars, glowing lines, translucent rounded panels, red night mode.
- Satellites (ISS and others), Milky Way, deep-sky objects, day/night/twilight lighting, settings remembered between sessions.

## Data

| Source | Used for |
| --- | --- |
| ESA Hipparcos catalogue | Star positions, magnitudes, colours, parallax distances; plate-solver pattern database |
| Yale Bright Star Catalogue | Bayer/Flamsteed designations, magnitude cross-check |
| IAU constellation boundaries (CDS VI/49) | Tap hit-testing and boundary drawing |
| Stellarium (western sky culture) | Constellation figures and artwork |
| AstronomyKit | Sun, Moon and planet positions |
| SatelliteKit + orbital elements | Satellite passes |
| Wikipedia, Allen's *Star Names*, Aratus's *Phaenomena* | Narration and Q&A passages |
| astrometry.net + Tycho-2 index | Mac-side cross-check of plate solves |

Sky math (bias-precession-nutation, aberration, sidereal time, refraction) is validated against Skyfield and astropy: under 1″ for positions, under 0.3 s for rise/set and satellite pass times. Licences and attributions are in [NOTICE.md](NOTICE.md).

## Layout

- `App/` — the iOS app (capture, motion, Metal renderer, sky engine, focus, narration, styling)
- `Packages/SkyCore/` — Swift package with the astronomy, alignment, plate-solving and focus logic (174 tests)
- `Data/` — prebuilt catalogues and assets bundled into the app
- `tools/` — Python build scripts (catalogue, solver database, narration, outlines, passages), session analysis and lens calibration

## Building

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), an Apple ID (a free Personal Team works).

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # add your API key, cloud project and signing team; git-ignored
xcodegen generate
open ConstellationAR.xcodeproj
```

Model IDs live in `Config/Config.xcconfig`. Keep your Vertex AI API key, Google Cloud project ID and `DEVELOPMENT_TEAM` in the git-ignored `Config/Secrets.xcconfig`. The sky works offline; narration and Q&A need the Vertex AI key.

The public bundle identifier is `org.constellationar.app`. To keep an existing local installation's identity, set `APP_BUNDLE_IDENTIFIER` in `Secrets.xcconfig`; keep personal identifiers out of tracked files. For public commits, use a GitHub `noreply` email address.

Tests: `swift test` in `Packages/SkyCore`, and the `ConstellationAR` scheme's test action for the app.
