pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/system"

// =============================================================================
// LlmModelLogos.qml
//
// Model id -> the vendor mark to carve above the empty state. Same shape as
// LlmTopicIcons.qml, and for the same reason: the rules are data, so a host
// can extend or replace a row without editing this file.
//
//   assetFor("gemma4:12b")   -> file:///.../assets/logos/googlegemini.png
//   assetFor("phi4:14b")     -> ""   (Microsoft has no mark -- see below)
//
// Resolution is by REGEX on the model id, first match wins, ordered specific
// before generic (codegemma before gemma is not needed -- both are Google --
// but codestral before mistral matters, and qwq is Qwen without the letters).
// A model that matches nothing returns `defaultAsset`, which is EMPTY: a
// vendor whose mark we do not have gets no logo at all rather than a stand-in
// that would be a small lie about who made the model. A host that would
// rather show something can set `defaultAsset` to the ollama mark, which ships
// here for exactly that.
//
// WHERE THE MARKS CAME FROM
// Every file in assets/logos/ is baked by tools/bake_logo_relief.py from a
// source in assets/logos/src/. Most of those are the official brand SVG that
// Simple Icons (CC0) serves at https://cdn.simpleicons.org/<slug>; two are
// supplied copies of marks Simple Icons does not carry (see below). The
// marks themselves stay their owners' trademarks; this is a personal shell
// showing which company made the model that is loaded, which is what a
// trademark is for.
//
// Two of the rows are stand-ins, and say so:
//   - GEMMA has no mark of its own. Google's GEMINI mark stands in for the
//     whole Gemma family, which is at least Google's own AI brand rather than
//     a generic Google G.
//   - LLAMA has no mark of its own either; Meta's does the same job, and Meta
//     is also the right mark for `muse-glimmer`, which is theirs.
//
// AND WHERE THEY DID NOT
// Simple Icons has no icon at all for IBM (granite), Microsoft (phi), OpenAI
// (gpt-oss), Cohere (command-r), AI2 (olmo), TII (falcon), Zhipu (glm),
// OpenBMB (minicpm), Nomic, mixedbread, BAAI, BigCode (starcoder) or Liquid AI
// (lfm2) -- the first three by the owner's own trademark-removal request, so
// they will not appear from there later either. All of those models have no
// logo except granite, which carries IBM's mark (below). The
// slug `falcon` DOES resolve, and is deliberately not used: it is the Falcon
// software project, not TII's model. `x` likewise is Twitter, not xAI.
//
// GRANITE, and why the mark is IBM's 8 bars
// Granite's own mark is two shaded cubes, and a relief cannot carry it: the
// artwork is nine linear gradients painted over ONE opaque hexagon, so its
// alpha -- which is all the baker reads -- is that hexagon. Baked, it is a
// featureless hexagonal plate whose relief spread is 5 in dark, where a mark
// needs 6.0 to read as a relief. The cubes' geometry can be recovered as an
// edge trace, but that is a line drawing we would have made, so granite
// carries IBM's 8-bar wordmark from the supplied copy in
// assets/logos/src/ibm.svg. Its alpha IS the wordmark, and it bakes into the
// strongest relief on the sheet (spread 18 light / 15 dark, against 6-9 for
// the other marks), because 37 separate bars are exactly what the island rule
// exists for. It draws 170x71 in a 170 slot, so there is air above and below
// it.
//
// ORNITH, and why a painting can be carved
// ornith-1.5 (published by Ornith AI -- ornith.ai, huggingface.co/ornith-ai; a
// Qwen-3.5 derived line) has no flat mark: Simple Icons has no `ornith` slug,
// and the only mark the publisher shows is a full-colour illustration -- a
// cartoon cockatiel in a hoodie on a dark disc, beside a wordmark, in one
// raster strip (assets/logos/src/ornith_logo.png). The disc's ALPHA is a plain
// circle and carries nothing, but the ARTWORK inside it is sharply bimodal --
// 65% of the pixels inside the disc below 0.30 luminance, 31% above 0.70,
// 0.9% in the whole of the middle -- so a plain threshold returns the
// illustrator's own contour, not an interpretation of it: baked at 0.35 / 0.45
// / 0.55 / 0.65 the depth ramp moves by at most 0.64 of one 8-bit level in the
// mean. Nothing is traced and nothing is redrawn; a potrace round-trip would
// change the ramp by only 0.25 levels mean / 2 at p99, because the 1045 px
// source already matches the bake's 1049 px fine grid.
// Two choices in it:
//   - LIGHT is the ink. Dark-as-ink is numerically fine and reads as a heavy
//     filled pillow with the bird as a hole in it, out of family with every
//     open silhouette that ships here.
//   - The HEAD only. The hoodie's two drawstrings survive the threshold as a
//     pair of loose ticks hanging under the chin, so components whose top row
//     lies below 0.80 of the height are dropped with the specks.
// Reproduce the asset from the source with:
//     tools/mask_from_photo.py assets/logos/src/ornith_logo.png /tmp/o.png
//     tools/bake_logo_relief.py /tmp/o.png assets/logos/ornith.png
// The mark is the publisher's, not Qwen's, although the weights descend from
// Qwen: the mark says who published the model, not what it was trained from.
// The Ornith WORDMARK (`--keep right --raw-alpha`) is not shipped: at 4.22:1
// it draws 170x40 in a 170 slot, and it is the shallowest relief on the sheet
// -- spread 6 in dark, exactly the floor, against 9 for the bird and 15 for
// IBM. It is a design call, not a measurement: a thin flat band in a mostly
// empty box.
// =============================================================================
QtObject {
    id: registry

    // Where the baked textures live, relative to this file.
    property url assetDir: "file://" + RepoRoot.dir + "/assets/logos/"

    // Shown when nothing matches. Empty means "no logo", which is the honest
    // answer for a vendor we have no mark for. Set to "ollama" for a generic.
    property string defaultAsset: ""

    // Regex rules against the model id (lowercased), first match wins.
    property var patternAssets: [
        // -- Google: Gemma, and every gemma-derived line ---------------------
        { re: /^(gemma|codegemma|embeddinggemma|medgemma|shieldgemma|translategemma|functiongemma)/, asset: "googlegemini" },
        // -- Alibaba: Qwen, including qwq, which is the same lab -------------
        { re: /^(qwen|qwq)/, asset: "qwen" },
        // -- Meta: Llama and its descendants, plus muse-glimmer --------------
        { re: /^(llama|codellama|tinyllama|muse-glimmer)/, asset: "meta" },
        // -- Mistral AI: every -stral, plus ministral and mixtral ------------
        { re: /^(mistral|ministral|mixtral|codestral|devstral|magistral|mathstral)/, asset: "mistralai" },
        // -- DeepSeek --------------------------------------------------------
        { re: /^deepseek/, asset: "deepseek" },
        // -- NVIDIA ----------------------------------------------------------
        { re: /^nemotron/, asset: "nvidia" },
        // -- Hugging Face: SmolLM is theirs ----------------------------------
        { re: /^smollm/, asset: "huggingface" },
        // -- LG AI Research --------------------------------------------------
        { re: /^exaone/, asset: "lg" },
        // -- IBM: Granite's own cubes cannot be carved, IBM's bars can -------
        { re: /^granite/, asset: "ibm" },
        // -- Ollama's own mark, for a model ollama itself publishes ----------
        { re: /^ollama/, asset: "ollama" },
        // -- Ornith AI: the bird, cut out of their painting (header) --------
        { re: /^ornith/, asset: "ornith" }
    ]

    // The mark's file for a model id, or "" when there is none.
    function nameFor(model) {
        const id = (model || "").toLowerCase().trim();
        if (id.length === 0)
            return registry.defaultAsset;
        for (let i = 0; i < registry.patternAssets.length; i++) {
            const rule = registry.patternAssets[i];
            if (rule && rule.re && rule.re.test(id))
                return rule.asset;
        }
        return registry.defaultAsset;
    }

    // The url LogoRelief wants. Empty url when the model has no mark.
    function assetFor(model) {
        const name = registry.nameFor(model);
        return name.length > 0 ? registry.assetDir + name + ".png" : "";
    }
}
