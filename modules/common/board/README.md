# The board toolkit

One isometric board, drawn per pixel by shaders, in two looks (Material, Blueprint): silicon's CPU / GPU / battery board was the first scene, aerial's
Wi-Fi card is the second. This folder and `tools/dev/board_gen/` are the parts that are not either of them. Silicon was re-pointed to it and is proven
unchanged (`docs/agent_added_files_and_folders/aerial_progress/T.md`: shaders byte-identical, its pictures 0 px moved).

A scene is: a **geometry** (boxes, traces, anchors, one JS file read by QML and by the generator), a **description** for the generator, shader
**templates** that say what each shader draws, and a few small QML files that derive from the toolkit's bases. Everything below says what the toolkit
gives and what the scene gives back.

## The pieces

### JS (`.pragma library`, no Qt; a scene's wrapper `.import`s them)
| File | What | Inputs |
|---|---|---|
| `IsoCore.js` | the isometric camera: `project(p, cam)`, `onPlane(px, py, cam, y)`, `fitPoints(pts, w, h, margins)` (whole-pixel origin), `boxCorners(B)`, `projectedRect(pts, cam, pad)` (a live patch's quad), `circleExtent`, `holoRect(anchor, cam, w, base, h, pad, lens, ink)`, `pickBoxes(parts, cam, px, py, frameOf)`, `lightDir(angle, elevation)` | a camera is `{ s, ox, oy }`; points are board mm `[x, y, z]`; `frameOf(part, o, d)` moves the pick ray into the part's group frame and answers `false` to leave a part out |
| `Figures.js` | the 7-segment grammar: `parse`, `pack(str, cells, hasColon)`, `packText`, `code4` / `uncode4`, the alphabet (`BLANK` 11, `MINUS` 10, `DP` +16, `COLON` +32) | strings; `seg7.glsl` reads the codes |
| `BoardLayout.js` | `proj`, `poly`, `rectPoly`, `footprint`, `anchorPx`, `inPoly`, `inRegion`, `zoneAt(regions, x, y, order)`, `groupOf`, `partBox`, `convexHull` | the camera and the geometry the scene draws with |

### QML (derive from these; every one's header says its properties)
| File | What | The scene gives |
|---|---|---|
| `BoardLayerBase.qml` | the board shader's layer scheme: `cached` (a layer re-rendered only when a uniform changes), `hole` (the live patch's rect, left transparent), `patch` / `cardPatch` (a live patch over the part that moves), the camera / light / palette uniforms `view frame light quad palA..palP tuneA tuneB r3s2A` | `vertexShader` / `fragmentShader` (`Qt.resolvedUrl`, the ROOT of a file must), the uniforms its template reads (motion, figures, atlases) |
| `GlowLayerBase.qml` | the live-light layer scheme (not a layer): camera, `pulse` (the idle ladder's live layer), `glowTuneA`, the second palette | `fragmentShader`, its own phases / cores / colours |
| `HoloLayerBase.qml` | a hologram's plane, lens and haze: `anchor`, `target`, `planeW/Base/H`, the entrance (`power`, `powerFrom`), `presence`, `awake`, `live`, `breath`, the idle clock (`time` + the energy's extra tempo, `_cyc(f)`: a fraction of a cycle exact in doubles), the oscillator uniforms `phA phB phC` | `fragmentShader`, what it draws (`look`, `frame`, `quad` ...) |
| `BoardClock.qml` | the scene's one clock: frame-locked pacing (reads the display's grid from `frameSwapped`), the idle ladder's live layer and parking, the theme hold (`gate`, `islandArmed`); `step(dt)` is the whole tick | `scene` (it writes `time` and `live`), `director` (`tick(dt)`, `animating`), and an `onAdvance: (dt, tempo) => { ... }` that integrates its phases (a phase is the sum of rate x dt, never tempo x time) |
| `BoardIsland.qml` | the board keeps moving through a theme switch: a `ThemeIsland` cut out of the crossfade's picture and an old-palette GHOST faded over the live scene | `ghostContent`: a Component whose root is a copy of the scene with every input bound to the live one, `oldMap` / `oldDark` as its palette (`root.oldMap`, `root.oldDark`) |
| `BoardInput.qml` | the one input layer, by arithmetic: hover, hand cursor, click -> `clicked(intent, at)`, the two-finger swipe over a zone (`swiped(zone, dir)`, `gestureWheel(ev)` for the engine's hand-over) | `pickPart(x, y)`, `intentFor(part, x, y)`, `anchorFor(intent)`, `zoneFor(x, y)`, `regions`, `pickReady` |
| `PopupStage.qml` | a popup drawn larger or smaller than the shell's standard by a number of its own (`sizeScale`, `designWidth/Height`; a `ScaleRoot` inside the engine's) | the children |
| `ReadingBeat.qml` | the ONE clock every reading runs on (`baseMs`, `serial`, `beat(serial)`; a reader asks for every Nth beat) | the service declares one |
| `IdleLadder.qml` | `alive` / `calm` / `halt` by `calmAfterMs` / `haltAfterMs`; a touch wins over `open`. The four times are silicon's tuned constants; set others where the ladder is declared | the service and its mock declare one |
| `ErrorTag.qml` | a part's error as a carved tag beside the part (`text`, `maxWidth`, `overlayItem`; presence fades 160 ms) | where to put it (`dipTagPoint` in silicon's layout) |

### GLSL (`shaders/`, spliced into a scene's templates by `// @@INCLUDE`)
| File | What it needs from the template |
|---|---|
| `seg7.glsl` | the generated `SEG_*` constants and `segIndexOf` / `segWindow` / `segCell0` / `segCells` / `segHasColon` (silicon writes them in `segmentLines`); the glass tint uniform `r3s2A`. Verbatim from silicon: its header comment names silicon, and stays so (see "Frozen headers") |
| `holo_common.glsl` | the holo template's uniforms (the names `HoloLayerBase` declares) and the generated `LENS_*` constants; noise, shapes, ink colours, the entrance, flicker, scanlines, the projector cone (`coneHaze`), `lensGlow`, the glitch |
| `board_prims.glsl` | uniforms `view`, `quad`; `V_CAM`, `SILK_RANGE`, `sat`, `pxMm`, `aaMm`, `inside` |
| `board_edges.glsl` | `Surf` (`pl bmin bmax nl pxPerMm group`), `groupNormal`, `CAM_R` / `CAM_U`, `BOARD_Y`, `frame`, `view`, `quad`; the box's edges from the camera (`topEdge`, `sideEdges`), `footprintShadow`, `itemEdgeFade` |
| `board_eva.glsl` | the first palette's slots (`palA` surface, `palB` bevel, `palC` deep shadow, `palD` groove floor, `palE` ink, `palF` sunk part, `palG` well, `palH` metal), `frame.w` = dark; `EvaInk`, `evaInk()`, `evaCarve(...)` |
| `board_ink.glsl` | nothing; `inkLine(dPx, w)`, a line's coverage |

The material maths that is silicon's own (`board_materials.glsl`: which part is which material, how each family paints it) stays in silicon and calls these.
A second scene writes its own `<scene>_materials.glsl` against its own `MAT_*` ids and includes the same pieces.

### The generator (`tools/dev/board_gen/`)
`node tools/dev/board_gen/gen.js <scene> [--check] [names]` assembles a scene's `*.frag.in` / `*.vert.in` templates into its generated shaders; `--check`
is the gate (`<NAME> RESULT PASS|FAIL`, exit status). `lib/` is the machinery: `geometry.js` (the generated block `// @@GEOM`), `cast.js` (the nearest hit,
the camera ray's tests, rows as one primitive, the shadow accumulate), `rows.js`, `traces.js` (the copper, blend groups, the flow coordinates), `fmt.js`.
`scenes/<name>.js` is a scene's description. `tools/dev/silicon_shader_gen.js` is `gen.js silicon`, kept because the gates and docs name it.
Bake with `tools/dev/bake_shaders.sh` (add the scene's `shaders/` dir to its `DIRS`), prove with `tools/dev/shader_glslang_gate.sh`.

Template markers (a line by itself): `// @@GEOM`, `// @@CONSTS` (the constants only, for a shader that does not look at the board), `// @@INCLUDE x.glsl`
(looked for in the scene's src, then here in `shaders/`; an included file may include others) and `// @@<NAME>`, a marker of the scene's own
(`scene.markers.<NAME>(G, ctx)`; silicon has `SEGFIG`, `BOARD_UBO`).

## A NEW SCENE must provide

1. **A geometry module** `modules/<m>/scene/SceneGeometry.js` (`.pragma library`, `json()` returning a JSON string: both QML and the generator read it).
   What the toolkit reads:
   - `MAT`: `{ NAME: id }`, written as `#define MAT_<NAME>`.
   - `PARTS`: `[{ name, group, mat, min: [x, y, z], max: [x, y, z] }]` in cast order (the part table; `PART_<NAME>` defines), optional `shape: "cylY"` (a vertical cylinder in the box),
     `row: { n: [nx, nz], cell: [dx, dy, dz], pitch: [px, pz], k, skip }` (identical cells as ONE primitive: a row of pins, chips, fins), `cast: true` (shadows),
     `bake: true` (drawn by the board only; the glow and particles' casts leave it out), `cut: true` (the part is cut to an outline the shader finds; the board only),
     `cluster: "<name>"` (consecutive parts behind one bound). The board is the part / group named by `scene.basePart`.
   - `TRACES`: `[{ name, kind: "stub"|"power"|"signal", pts: [[x, z] or [x, z, fullWidth], ...], width, blend, blendK, zone, soft, from, fromPack, length, s, g }]`
     (`s` / `g`: the flow coordinates per vertex, the glow only).
   - `ANCHORS`, and whatever the scene's own hooks read (silicon: `ZONE`, `BOARD`, `CARD`, `SEG7` ...).
2. **A scene description** `tools/dev/board_gen/scenes/<name>.js` exporting: `name`, `resultName`, `tool` (what the generated header names), `geometryLabel`,
   `geometrySourceLabel`, `srcDir`, `outDir`, `includeDirs` (its src, then `modules/common/board/shaders`), `sourceLabel(file, resolved)`, `loadGeometry()`,
   `groups` (`{ name: id }`, cast order; `GRP_<NAME>`), `generalGroups` (groups whose frame TURNS the ray: they take the general box tests; the rest take the
   camera ray's cheap ones), `basePart`, `shadowWeight(group)`, `hitSign` (the GLSL expression of the winner's face sign), `optsFor(shaderName)` (`glow`,
   `flow`, `packHalf`: which shader is the board's, the glow's, the particles'), `constantsLines(G)`, `preludeLines(G)`, `extentGrow(part, G)`,
   `groupFrame(G)` (the GLSL of the groups' frames: `groupRay`, flags, `cutPart`, `groupNormal`, `inZone`), `aoBlock(G, opts)` (the contact darkening; return a
   GLSL string with `sceneAo(p, sh, lvl, two)` for the board's shader), `flowTables(G)`, `traceTailLines(G)`, `tailLines(G)`, `markers`. Silicon's is the
   worked example; `lib/geometry.js`'s header says each hook's place in the output.
3. **Shader templates** in the scene's `shaders/src/`: a board template that defines `Surf`, the uniform block, `shadeSurface` / `shadeGround` and includes
   the toolkit's pieces; optionally a glow, a hologram and a particle template. A board shader has its OWN vertex shader (`<name>.vert.in`, Qt's two lines with the
   fragment's uniform block copied whole by a marker): on NVIDIA's ES context that is what links the pair at GLSL ES 3.00. Every variant must be valid for GLSL
   1.20 / ES 1.00 / 3.00 (no array constructors in ES 1.00, no integer clamp; `shader_glslang_gate.sh`). Never leave a big effect in the scene to "prewarm" it.
4. **Palettes per family as Theme tokens**: the board's first palette `palA..palH` (Material: surface, bevel, deep shadow, groove floor, ink, sunk part, well, metal;
   Blueprint: paper, ink, faint ink, grid, face wash), the second `palI..palP` + slot 8 (`r3s2A`), per family and per light / dark, from tokens a scene adds
   to `themes/eva.json` (silicon's `SiliconStyle.qml` fills them; components read `Theme.<token>`, never a literal).
5. **QML derived from the bases**: `BoardLayer` (`BoardLayerBase`), `GlowLayer`, `HoloLayer` if it has holograms, `<Scene>Clock` (`BoardClock` + `onAdvance`),
   `<Scene>Island` (`BoardIsland` + `ghostContent`), `<Scene>Input` (`BoardInput` + the four functions), `<Scene>Camera.js` (the fit: which points must be in view;
   the patches' rects with `Core.projectedRect`; the pick with `Core.pickBoxes` and the groups' frames of right now), `<Scene>Layout.js` (zones, what a click on a
   part means, where each part's secondary hangs from, with `BoardLayout.js`), `Figures.js` for its displays, a popup that derives from `PopupStage`.
6. **Hit intents and anchors**: `intentFor(part, x, y)` returns an intent string ("" for none) from the part picked, and from where nothing of the board answers
   (a hologram); `anchorFor(intent)` the item px a secondary hangs from; `zoneFor` the zone a swipe belongs to. The pick takes every group in the frame it is in
   RIGHT NOW (a moved part is picked where it is drawn).
7. **The service's readings** on one `ReadingBeat` and one `IdleLadder` (a slow reader lands ON a fast beat).

## What stayed in silicon, and why
`SceneGeometry.js` (the geometry), `board_materials.glsl` / `cutouts.glsl` / `glow_materials.glsl` / `holo_beam|symbols|fractals.glsl` / `particles_*.glsl` (the
materials, the symbols, the particles: each is written against silicon's parts), `silicon_event_walk.js` (the battery's pulse), `MotionDirector` /
`MotionScripts` / `ParticleField` / `SiliconScene` / `SiliconStyle` (the scene's own numbers and choreography), the fit's hologram headroom and name plate room, the
live patches' choice of what moves (the package, the card), the integrated beam and its ghost card (`IsoCamera.js`), the intents (`PopupLayout.js`), and
the CPU's figures (`Figures.js`). Where a file mixed both, the generic half moved only where the cut was clean: a piece that would have changed one byte of
a generated shader stayed.

## Frozen headers
A generated `.frag` begins with a header naming its sources. Silicon's say `modules/silicon/shaders/src/seg7.glsl` and `holo_common.glsl` where those files
were, and do not list the four small pieces `board_materials.glsl` now includes: `scenes/silicon.js` `sourceLabel` keeps them so the six generated shaders stay
byte for byte what they were (the baked packs do not carry comments). A new scene's `sourceLabel` returns the real path (or `null` to leave a file out).

## Proving a change here
Silicon is the proof: `node tools/dev/silicon_shader_gen.js --check`, `tools/dev/bake_shaders.sh` (nothing changed), `tools/dev/shader_glslang_gate.sh`,
`tools/dev/silicon_board_probe.sh` (and `LOCK_ENV=<name> SHIM=1 ...` for the NVIDIA path), the silicon states of the reference sheet 0 px moved
(`ONLY=silicon tools/dev/sheet_render.py <out>`, then `tools/dev/sheet_compare.py sheet <base> <out>`; arm a one-pixel change once to see it fail),
`tools/dev/smoke.sh tools/dev/qml/board_toolkit_probe.qml` (the toolkit's own types and cores, with no scene behind them).
