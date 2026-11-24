#!/usr/bin/env node
// tools/dev/panorama_engine/gen_node.js <setups.json> <engine.lua> <out.lua> -- the shell's generation function
// (modules/panorama/data/EngineGenerate.js) run under node, for the generation case of tools/dev/panorama_cases.lua.
"use strict";
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../../../modules/panorama/data/EngineGenerate.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
// eslint-disable-next-line no-new-func
const G = new Function(src + "\nreturn { generate: generate };")();
const [setups, engine, out] = process.argv.slice(2);
fs.writeFileSync(out, G.generate(fs.readFileSync(setups, "utf8"), fs.readFileSync(engine, "utf8")));
