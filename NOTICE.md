# Notices and attributions

ConstellationAR is a personal, non-commercial app. It bundles data derived from the sources below.
Every licence statement is quoted from the source itself. Pinned URLs, versions and SHA-256 hashes are in
`tools/sources.json` and `tools/narration_sources.json`; `tools/build_catalog.py` and
`tools/generate_narration.py` rebuild every bundled file from them.

Bundled into the app: `Data/*.bin`, `Data/*.json`, `Data/artwork/`. Not bundled: `Data/test/`, `Data/fixtures/`.

## Share-alike and non-commercial summary

| Bundled file | Derived from | Licence |
|---|---|---|
| `stars.bin` | Hipparcos Catalogue (ESA) via CDS | CC BY-NC 3.0 IGO (non-commercial) |
| `solver_db.bin` | `stars.bin` (V ≤ 5.0), pattern table built with an algorithm from tetra3 / Cedar-Solve | CC BY-NC 3.0 IGO (data); Apache-2.0 (algorithm) |
| `roman1875.json` | Roman (1987), CDS VI/42 | no licence stated; CDS terms |
| `lines.json`, `artwork.json` (anchors) | Stellarium modern sky culture | CC BY-SA 4.0 |
| `artwork/*.png` | Stellarium, art by Johan Meuris | Free Art License |
| `names.json` | IAU WGSN Catalog of Star Names | public domain (names) |
| `constellations.json` | Wikipedia (genitives), IAU | CC BY-SA 4.0 |
| `asterisms.json`, `milkyway.json` | d3-celestial (Olaf Frohn) | BSD-3-Clause; upstream terms unstated |
| `dso.json` | OpenNGC (Mattia Verga) | CC BY-SA 4.0 |
| `narration.json` | Wikipedia summaries, Allen (1899), Aratus tr. Mair (1921), generated with Gemini | CC BY-SA 4.0 |

The Hipparcos licence is non-commercial. Any commercial release of this app needs a replacement star catalogue or
permission from ESA. The CC BY-SA 4.0 files and Free Art License artwork may be redistributed only under the same
licences, with attribution.

## Star catalogue: Hipparcos (ESA) via CDS VizieR I/239

- Used for: `stars.bin` (positions propagated to epoch 2026.5, V magnitude, B−V, parallax), and the star facts in
  `narration.json`.
- Source: ESA 1997, *The Hipparcos and Tycho Catalogues*, ESA SP-1200; CDS VizieR catalogue I/239,
  `hip_main.dat`, <https://cdsarc.cds.unistra.fr/ftp/I/239/>.
- Licence, from the I/239 ReadMe: "License: CC-BY-NC-3.0 IGO"
  (<https://creativecommons.org/licenses/by-nc/3.0/igo/>).
- Changes: proper motion applied from J1991.25 to J2026.5; converted to unit vectors; stars fainter than V 6.5
  dropped, except four kept because they are used in constellation figures or artwork anchors.

## CDS VizieR

- "This research has made use of the VizieR catalogue access tool, CDS, Strasbourg, France
  (DOI : 10.26093/cds/vizier). The original description of the VizieR service was published in 2000, A&AS 143, 23"
- CDS terms (<https://cds.unistra.fr/vizier-org/licences_vizier.html>): "The data retrieved with VizieR are free of
  usage in a scientific context ; however, as it is the usage in scientific publication, the original authors and
  publication references including the publisher have to be explicitely cited". It also says: "The commercial usage
  of the data is subject to rules depending of the origin". For catalogues from other producers: "Please refer to
  the ReadMe file associated to the catalogue to verify if a "copyright" exists."

### Constellation identification: Roman (1987), VI/42

- Used for: `roman1875.json`, the point-in-constellation lookup table, and neighbour lookups for narration.
- Citation: Roman N.G. 1987, "Identification of a Constellation from a Position", Pub. Astron. Soc. Pac. 99, 695
  (1987PASP...99..695R); CDS VizieR VI/42, `data.dat`.
- Licence: the VI/42 ReadMe states no licence or copyright, so the CDS terms above apply.

### Constellation boundaries: Davenhall & Leggett (1989), VI/49

- Used for: `Data/test/vi49_bounds.json`, which is test data and is not bundled.
- Citation: Davenhall A.C., Leggett S.K. 1989, "Catalogue of Constellation Boundary Data", Royal Obs. Edinburgh
  (1997yCat.6049....0D); CDS VizieR VI/49, `bound_18.dat`. The boundaries follow Delporte, E. 1930, "Delimitation
  Scientifique des Constellations".
- Licence: the VI/49 ReadMe states no licence or copyright, so the CDS terms above apply.

## Star names: IAU Working Group on Star Names (WGSN)

- Used for: `names.json` (IAU proper names keyed by HIP number), and star names in `narration.json`.
- Source: IAU Catalog of Star Names (CSN) table at <https://exopla.net/star-names/modern-iau-star-names/>, pinned to
  the Wayback Machine snapshot of 2026-10-17T21:36:55Z.
- Terms, from the page's "CSN Usage (Credits)" section: "IAU-star names are free to use and not subject to
  copyright or intellectual property licensing; they are scientific standards (like the unit of measure “meter” or
  “light-year”), belong to the public domain and are not owned by anybody (neither the IAU nor WGSN)." Only the
  names are used. The page's etymology texts, which it puts under CC BY, are not used.

## Constellation figures and artwork: Stellarium "Modern" sky culture

- Used for: `lines.json` (stick figures), `artwork.json` (image anchors) and `artwork/*.png` (85 illustrations).
- Source: Stellarium v26.3, `skycultures/modern/` (`index.json`, `illustrations/`),
  <https://github.com/Stellarium/stellarium/tree/v26.3/skycultures/modern>.
- Licence, from `skycultures/modern/description.md`: "Authors: Stellarium's team"; "Text and data: CC BY-SA 4.0";
  "Illustrations: Free Art License".
- Artist, from Stellarium `CREDITS.md`: "Constellation art, GUI buttons, logo created by Johan Meuris (Jomejome) …
  http://www.johanmeuris.eu/ License: released under the Free Art License (http://artlibre.org/licence.php/lalgb.html)".
- Changes: figure segments are deduplicated and converted to JSON keyed by IAU ID. The PNG files are copied
  unmodified, because all are already 512 px or smaller. Anchors are rescaled to the actual pixel size, and art
  is keyed by constellation ID.
- `lines.json` and `artwork.json` are adaptations licensed under CC BY-SA 4.0
  (<https://creativecommons.org/licenses/by-sa/4.0/>). The illustrations stay under the Free Art License 1.3
  (<https://artlibre.org/licence/lal/en/>). Originals are available at the Stellarium URL above.

## Constellation names and genitives: Wikipedia

- Used for: `constellations.json` (English name and genitive for the 88 IAU constellations).
- Source: Wikipedia, "IAU designated constellations", revision 1381140789,
  <https://en.wikipedia.org/w/index.php?title=IAU_designated_constellations&oldid=1381140789>.
- Licence, from the Wikipedia page footer: "Text is available under the Creative Commons Attribution-ShareAlike 4.0
  License" (<https://creativecommons.org/licenses/by-sa/4.0/>).

## Asterisms and Milky Way: d3-celestial

- Used for: `asterisms.json` and `milkyway.json`.
- Source: d3-celestial by Olaf Frohn, commit 7e720a3de062059d4c5400a379146a601d9010e0,
  `data/asterisms.json` and `data/mw.json`, <https://github.com/ofrohn/d3-celestial>.
- Licence, from `LICENSE`: "Copyright (c) 2015, Olaf Frohn. All rights reserved." It is the BSD 3-Clause licence:
  "Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
  following conditions are met: …"
- Upstream data, as credited in d3-celestial's readme:
  - `mw.json` comes from the "Milky Way Outline Catalog, Jose R. Vieira" (<http://www.skymap.com/milkyway_cat.htm>).
  - `asterisms.json` comes from "Saguaro Astronomy Club Asterisms" (<http://saguaroastro.org/sac-downloads/>).
  - Neither upstream source states a licence that I could find.
- Changes: longitudes converted to RA 0–360°; Milky Way rings regrouped by brightness level; asterism
  lines converted to JSON.

## Deep-sky objects: OpenNGC

- Used for: `dso.json`, which holds all Messier objects plus NGC/IC objects with V (or else B) ≤ 11.0.
- Source: OpenNGC by Mattia Verga, release v20260501 (commit 36cb178a0f69dba8bfc03a99c10512831edf1c6b),
  `database_files/NGC.csv` and `addendum.csv`, <https://github.com/mattiaverga/OpenNGC>.
- Licence, from `README.md`: "OpenNGC is released under CC-BY-SA-4.0 license". The README's credit line is
  "Credits: Mattia Verga".
- Changes: filtered by magnitude; duplicate and non-existent entries removed; RA/Dec converted to degrees.
  `dso.json` is licensed under CC BY-SA 4.0.

## Narration: `narration.json`

Each card lists its own sources, with URL and licence. The texts are generated by Google Gemini through Vertex AI;
the model ID is in `Config/Config.xcconfig`. The model writes the summary, finding tips, mythology and quotes, using
only the sources below. Brightest stars, magnitudes and distances are added by code from Hipparcos and WGSN. Every
quote is checked word for word against its source.

- **Wikipedia**: REST page summaries of each constellation article, one pinned revision each. The licence is
  CC BY-SA 4.0, as above. Because the prose is adapted from these summaries, `narration.json` is licensed under
  CC BY-SA 4.0.
- **Allen (1899)**: Richard Hinckley Allen, *Star-Names and Their Meanings*, G. E. Stechert, New York, 1899.
  - Transcription used: LacusCurtius by Bill Thayer,
    <https://penelope.uchicago.edu/Thayer/E/Gazetteer/Topics/astronomy/_Texts/secondary/ALLSTA/home.html>.
  - Each page says: "This webpage reproduces a section of Star Names Their Lore and Meaning by Richard Hinckley Allen
    as reprinted in the Dover edition, 1963 The text is in the public domain."
  - Only Allen's text is used. Thayer's notes, links and page markers are removed.
- **Aratus, *Phaenomena***: translated by A. W. Mair and G. R. Mair, Loeb Classical Library 129, William
  Heinemann, London, 1921.
  - Published in 1921, so it is in the public domain in the United States.
  - Transcription used: Theoi Classical Texts Library, <https://www.theoi.com/Text/AratusPhaenomena.html>. The site
    states "Theoi Project © Copyright 2000 - 2017 Aaron J. Atsma".
  - Only the 1921 translation text is used. Theoi's headings and bracketed glosses are removed.

## Plate solving: tetra3 and Cedar-Solve (Apache-2.0)

- Used for: automatic star alignment. `tools/build_solver_db.py` (database builder, Python) and
  `Packages/SkyCore/Sources/SkyCore/PlateSolve/PlateSolver.swift`, `SolverDatabase.swift` (solver, Swift) are
  re-implementations of the algorithms in **tetra3** and **Cedar-Solve**; no code was copied or linked, and the
  upstream packages are not used. `Data/solver_db.bin` is the database that builder writes.
- tetra3: <https://github.com/esa/tetra3>, `tetra3/tetra3.py`: "Copyright 2019 the European Space Agency", "Licensed
  under the Apache License, Version 2.0". tetra3 is "Free and Open-Source Software based on `Tetra` rewritten by
  Gustav Pettersson at ESA."
- Cedar-Solve: <https://github.com/smroid/cedar-solve>, `tetra3/tetra3.py`, `tetra3/fov_util.py`,
  `tetra3/breadth_first_combinations.py`: "Copyright 2023 Steven Rosenthal smr@dt3.org", "Licensed under the Apache
  License, Version 2.0". Cedar-Solve is a fork of tetra3.
- Neither repository has a `NOTICE` file, so there is no NOTICE text to reproduce (Apache-2.0 section 4(d)).
- The Apache License 2.0 text, with the original Tetra notice that tetra3 ships beside it, is in
  `tools/licenses/tetra3-LICENSE.txt` (Apache-2.0 section 4(a)).
- Original Tetra: J. Brown, K. Stubis and K. Cahoy, "TETRA: Star Identification with Hash Tables", Proceedings of the
  AIAA/USU Conference on Small Satellites, 2017, <https://github.com/brownj4/Tetra>. Its MIT notice, as reproduced in
  tetra3: "Copyright (c) 2016 brownj4. Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal in the Software without restriction
  ... The above copyright notice and this permission notice shall be included in all copies or substantial portions of
  the Software." The full text is in the same licence file.
- Ported from them (Apache-2.0 section 4(b), changes stated):
  - Database: 4-star patterns; sorted edge ratios binned at 1/(4 × max error); key hash `Σ keyᵢ·binsⁱ`, table index
    `hash × 2654435761 mod prime`, quadratic probing, 16-bit key check, stored largest edge; stars of each pattern
    ordered by distance from the pattern centroid; cluster-busting separation `0.6 · fov / √stars_per_fov`; Fibonacci
    lattice of overlapping fields with brightest-first breadth-first combinations; multiscale FOV steps; the 16-bit
    key check and largest-edge gate come from Cedar-Solve.
  - Solver: brightest-first breadth-first pattern enumeration over cluster-busted centroids; edge-ratio key ranges
    searched nearest-first; FOV/scale gate from a prior; pattern rotation from Wahba's problem; catalogue stars in the
    field matched one-to-one within a radius; false-match probability from a binomial tail with two degrees of freedom
    removed, accepted below `threshold / patterns`; rotation and focal length refit on all matches.
  - Changed: a single catalogue (Hipparcos, V ≤ 5.0) and a pinhole camera model with Apple's per-frame intrinsics
    (no distortion fit); Davenport q-method with a hand-written 4×4 Jacobi solver instead of SVD; permutation retry for
    ambiguous star pairing; the per-star chance of a random match uses the area fraction of the match circles; the
    database is a flat binary file read directly; the star detector and the conversion to a device attitude are new.

## Runtime services (not bundled)

- **CelesTrak** (Dr. T.S. Kelso, <https://celestrak.org>): satellite orbital elements are fetched at runtime.
  CelesTrak states no data licence; it asks users to follow its usage policy
  (<https://celestrak.org/usage-policy.php>): "Only download the data you need, when you are going to use it, and only
  download data once per update. For GP data, updates are once every 2 hours."

## Swift packages (linked into the app)

- **AstronomyKit** 4.1.0, <https://github.com/heirloomlogic/AstronomyKit>: "MIT License, Copyright (c) 2025 Heirloom
  Logic LLC". It wraps **Astronomy Engine**, <https://github.com/cosinekitty/astronomy>: "MIT License, Copyright (c)
  2019-2025 Don Cross".
- **SatelliteKit** 2.1.2, <https://github.com/gavineadie/SatelliteKit>: "The MIT License (MIT), Copyright (c) 2018-25
  Gavin Eadie".

The MIT licence requires its copyright and permission notice to be included with copies of the software. The full
texts are in each package's `LICENSE` file.

## Build and test tools only (not bundled)

These are pinned in `tools/requirements.txt`:

| Package | Version | Licence |
|---|---|---|
| Skyfield | 1.55 | MIT |
| Astropy | 8.0.2 | BSD-3-Clause |
| PyERFA | 2.0.1.5 | BSD-3-Clause |
| NumPy | 2.5.4 | BSD-3-Clause and others |
| jplephem | 2.24 | MIT |
| sgp4 | 2.27 | MIT |
| Requests | 2.34.2 | Apache-2.0 |
