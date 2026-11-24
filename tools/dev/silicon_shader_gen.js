#!/usr/bin/env node
// silicon_shader_gen.js -- silicon's shader generator is the board toolkit's generator on silicon's scene description:
//   node tools/dev/silicon_shader_gen.js [--check] [names]   =   node tools/dev/board_gen/gen.js silicon [--check] [names]
// Kept under this name because the gates (shell_gates.sh), tools/silicon/calibrate_overhead.sh, the docs and the generated headers name it.
// The machinery is tools/dev/board_gen/ (lib/), silicon's own tables are tools/dev/board_gen/scenes/silicon.js.
"use strict";
const { run } = require("./board_gen/gen.js");
const scene = require("./board_gen/scenes/silicon.js");
if (require.main === module)
    run(scene, process.argv.slice(2));
module.exports = { scene };
