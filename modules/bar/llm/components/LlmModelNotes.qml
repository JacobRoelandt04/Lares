pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// LlmModelNotes.qml
//
// What each installed model is FOR, for the picker's row tooltip. Same shape as
// LlmTopicIcons: the rules are data -- an ordered list of regexes against the
// lowercased model id, first match wins -- so a host can extend or replace them
// without editing this file. One entry per installed tag, then one per family as the fallback
// for a tag that is not listed (a new quantisation, `:latest`).
//
//   notesFor(modelId) -> { strengths: [string], caveats: [string],
//                          compare: string, source: string }   // or null
//
// The tip is 200 px wide at figure size, so every line is a fact and a
// number, nothing else: strengths first (what to pick it for), caveats
// fainter (what it costs, where it loses), the compare sentence last (the
// honest verdict against its nearest neighbour ON THIS MACHINE). Every
// installed model has its own notes, the shape is the one above, no line is
// left to fill in, and a strength fits two tip lines.
//
// WHERE THE NUMBERS COME FROM. Benchmarks are the publishers' own tables
// (ollama.com/library, the Hugging Face model cards, Google's model card,
// IBM's vendor table). A publisher's table flatters its own model -- the same
// Gemma 4 31B scores 52 on SWE-bench Verified in Ornith's table and 66.6 in
// Meta's -- so a line that compares two models takes both from ONE table and
// the caveats say whose it is.
//
// "On this card" figures were MEASURED here with tools/llm/llm_tokps.py: NVIDIA
// RTX 4060 Laptop, 8 GiB VRAM, 22 GiB RAM, Intel Ultra 9 185H, ollama 0.33.2,
// every model at Q4_K_M, num_ctx 8192, 128 generated tokens, median of 3 warm
// runs after a 16-token warm-up, one model resident at a time, the server's
// own eval_count / eval_duration.
// "In VRAM" is /api/ps size_vram / size for that run: a model mostly in
// system RAM is a different machine from one on the card, which is why the
// speed is never given without it. Load seconds are wall time of the
// warm-up call and depend on the disk cache (the 31b's 136 s was the one
// cold read).
//
//   model             tok/s   in VRAM   resident   load
//   gemma4:e2b        109     100 %      1.6 GiB   10 s
//   granite4.2:3b      87     100 %      2.7 GiB    5 s
//   gemma4:e4b         57     100 %      3.0 GiB   17 s
//   granite4.2:8b      43     100 %      6.1 GiB    8 s
//   ornith-1.5:9b      40     100 %      5.3 GiB   10 s
//   ornith-1.5:35b     40      28 %     21.0 GiB   70 s   MoE, ~3 B active
//   gemma4:26b         34      30 %     17.5 GiB   44 s   MoE, 3.8 B active
//   gemma4:12b         18      83 %      7.6 GiB   15 s
//   muse-glimmer:30b    4.0    32 %     16.3 GiB   32 s   dense
//   qwen3.8:27b         3.8    27 %     17.2 GiB   42 s   dense
//   granite4.2:30b      3.8    35 %     18.8 GiB   60 s   dense
//   gemma4:31b          3.1    26 %     20.1 GiB  136 s   dense
//
// The line is drawn by the card: a dense model up to ~9 B runs whole in
// VRAM at 40+ tok/s; a dense 27-31 B has three quarters of itself in
// system RAM and decodes at 3-4 tok/s, ten times slower than a 9 B and a
// minute and a half for a 200-word answer; a MoE the same size runs at
// 34-40 tok/s from the same place, because only 8 of its 128-256 expert
// blocks are read per token.
//
// WHAT THE BENCHMARK NAMES MEAN (plain words, the glossary behind the lines):
//   SWE-bench Verified / Pro  fixing real GitHub issues in real repos, judged
//                             by the project's tests (Pro: harder, held-out).
//   Terminal-Bench 2.1        finishing multi-step jobs in a shell (build,
//                             configure, debug) inside an agent harness.
//   GPQA Diamond              graduate-level science questions written so a
//                             web search does not help.
//   HLE                       "Humanity's Last Exam": expert-written questions
//                             across every field; the frontier-hard set.
//   MMLU-Pro                  a 14-subject exam, ten choices per question;
//                             the broad-knowledge score.
//   AIME                      US olympiad-qualifier maths with numeric answers.
//   LiveCodeBench             fresh competitive-programming problems.
//   Codeforces                a contest rating, like a chess Elo, for code.
//   MCP-Atlas                 multi-step tasks over real MCP tool servers.
//   tau2 / tau3-bench         a simulated customer-service agent that must
//                             follow policy with tools while a user talks back.
//   BFCL                      Berkeley Function-Calling Leaderboard: the right
//                             function with the right arguments.
//   Toolathlon                long-horizon tasks across many real apps/tools.
//   BrowseComp, WideSearch,   finding hard-to-find facts by browsing the web.
//   DeepSearch QA
//   OSWorld                   operating a real desktop from screenshots.
//   MMMU-Pro                  university exam questions that need reading
//                             charts, diagrams and photos.
//   MATH-Vision, CharXiv      maths posed as pictures; reasoning over charts.
//   OmniDocBench              reading document pages (PDF) accurately.
//   MRCR, RULER, AA-LCR       finding and using several facts buried in a
//                             very long context (long-context recall).
//   MMMLU                     MMLU translated into many languages.
//   IFBench                   following precise formatting instructions.
//   Arena-Hard                how often a judge prefers its chat answers.
//   CoVoST                    speech-to-text translation (audio input).
//
// THE REDUNDANCY VERDICT, argued once here and echoed in the compare lines.
//
//   ornith-1.5:9b vs gemma4:31b. The 9b is a dense Qwen3.5 9B tuned by RL
//   on self-generated tasks; the 31b is Google's dense flagship. On this
//   card the 31b runs at 3 tok/s with a quarter of it in VRAM; the 9b at 40
//   whole on the card. Ornith's table has the 9b ahead on coding (SWE-bench
//   Verified 70.6 vs 52), shell agents (46.2 vs 42.1), science (86.4 vs
//   84.3) and HLE (20.2 vs 19.5), and behind on long-horizon tool work
//   (Toolathlon 41.2 vs 52.8). What the 31b wins is in Google's table,
//   which Ornith did not run: breadth (MMLU-Pro 85.2), 140+ languages
//   (MMMLU 88.4), long-context recall (MRCR at 128K 66.4 against 44 for
//   every other Gemma), charts and photos (MMMU-Pro 76.9 vs the 9b's
//   unpublished), policy-following tool agents (tau2 76.9). So: NOT
//   redundant in what it knows, redundant in what you wait for -- and
//   gemma4:26b, the MoE, keeps 97 % of its exam score (82.6 vs 85.2) at
//   eleven times its speed here, so what the 31b alone earns its disk for
//   is a long document (MRCR) or a rare language, when a minute per answer
//   is acceptable. For everything else the 9b is the everyday model.
//
//   ornith-1.5:35b (MoE: 256 experts, 8 per token, ~3 B active) vs dense.
//   It reads 8 of 256 expert blocks per token, so on this card it decodes
//   at 40 tok/s with 72 % of its 21 GiB in system RAM, where a dense model
//   the same size crawls at 3-4. Its table beats gemma4:31b everywhere it
//   ran (SWE-bench Verified 79 vs 52, GPQA 89.2 vs 84.3, MCP-Atlas 70.2 vs
//   55) and the 9b by 3-20 points on every set. The dense model that still
//   beats it is the newer qwen3.8:27b -- Terminal-Bench 73 vs 67.8,
//   SWE-bench Pro 61.7 vs 59.6, HLE 30.8 vs 25.6 -- which is where the
//   per-token depth a 3 B active model does not have shows, at a tenth of
//   the speed. The 35b is the working model here; the 9b is kept for the
//   10 s load and the 15 GiB of RAM it does not take.
//
//   The dense 27-31 B four (gemma4:31b, qwen3.8:27b, granite4.2:30b,
//   muse-glimmer:30b) are one speed class on this card, 3-4 tok/s, and
//   each keeps one thing the others lack: the 31b recall and languages,
//   qwen3.8 the strongest coding and computer-use scores on the machine,
//   muse-glimmer the best MCP tool-chaining and the newest knowledge
//   (January 2026), granite4.2:30b the best function-calling score, Dutch
//   and RAG tuning -- but text only, and beaten by qwen3.8 on every coding
//   set, so it is the one that is redundant outright; the 8b is the
//   Granite to keep. Among the small ones granite4.2:3b is redundant next
//   to gemma4:e4b (same MMLU-Pro, e4b reads images and hears audio) unless
//   Dutch or the fastest tool-caller is the point; gemma4:e2b is a lookup
//   at twice e4b's speed, not a thinker.
// =============================================================================
QtObject {
    id: registry

    // Regex rules against the model id (lowercased), first match wins.
    // Installed tags first, families last.
    property var patternNotes: [
        // -- Ornith 1.5 (DeepReinforce / ornith.ai; MIT) ------------------------
        { re: /^ornith-1\.5:35b/, notes: {
            strengths: [
                "Fixes real GitHub issues: SWE-bench Verified 79 % (gemma4:31b 52)",
                "Shell agent, multi-step terminal jobs: Terminal-Bench 68 % (gemma4:31b 42)",
                "Graduate science 89 % (GPQA Diamond); expert-hard questions 26 % (HLE)",
                "Tool chains over MCP servers 70 % (MCP-Atlas); web research 68 % (BrowseComp)",
                "On this card: 40 tok/s with 28 % of it in VRAM — 8 of 256 experts per token"
            ],
            caveats: [
                "21 GiB resident, 15 GiB of it system RAM; 70 s to load",
                "~3 B active per token: qwen3.8:27b beats it on the hardest sets (HLE 31 vs 26)",
                "Thinks by default; the publisher's own table"
            ],
            compare: "Beats gemma4:31b on every published coding, science and agent score at 13× its speed here — the working model.",
            source: "huggingface.co/ornith-ai/Ornith-1.5-35B-A3B · ornith.ai/ornith_1_5.html · tools/llm/llm_tokps.py 2026-09-05"
        } },
        { re: /^ornith-1\.5:9b/, notes: {
            strengths: [
                "Fits the card whole: 40 tok/s, 5.3 GiB in VRAM, 10 s to load",
                "Fixes real GitHub issues: SWE-bench Verified 71 % (gemma4:31b 52)",
                "Graduate science 86 % (GPQA Diamond); shell agent 46 % (Terminal-Bench)",
                "Reads images; 256 K context; MIT licence"
            ],
            caveats: [
                "Long-horizon tool work trails gemma4:31b (Toolathlon 41 vs 53)",
                "9 B of knowledge: rare facts, languages and long documents go to the big dense models",
                "Thinks by default; the publisher's own table"
            ],
            compare: "The everyday model here; the 35b beats it by 3–20 points everywhere but needs 70 s and 15 GiB of RAM to load.",
            source: "huggingface.co/ornith-ai/Ornith-1.5-9B · tools/llm/llm_tokps.py 2026-09-05"
        } },

        // -- Gemma 4 (Google DeepMind) ------------------------------------------
        { re: /^gemma4:31b/, notes: {
            strengths: [
                "Widest knowledge here: MMLU-Pro 85 % (a 14-subject exam)",
                "Long documents: 8 facts buried at 128 K, MRCR 66 % (every other Gemma 44)",
                "140+ languages (MMMLU 88 %); charts and photos (MMMU-Pro 77 %)",
                "Policy-following tool agent 77 % (tau2-bench); Codeforces rating 2150"
            ],
            caveats: [
                "On this card: 3 tok/s, 26 % in VRAM, 136 s to load — 90 s for a 200-word answer",
                "Coding agents trail: SWE-bench Verified 52–67 by table; ornith 35b 79",
                "Knowledge ends January 2025"
            ],
            compare: "Not redundant in what it knows, redundant in what you wait for: gemma4:26b keeps 97 % of its exam score at 11× the speed; keep 31b for a long document or a rare language.",
            source: "ai.google.dev/gemma/docs/core/model_card_4 · tools/llm/llm_tokps.py 2026-09-05"
        } },
        { re: /^gemma4:26b/, notes: {
            strengths: [
                "Gemma's knowledge at MoE cost: MMLU-Pro 83 % (31b 85), 3.8 B active",
                "Maths and code near the 31b: AIME 88 %, LiveCodeBench 77 %",
                "Charts and photos (MMMU-Pro 74 %); 140+ languages; 256 K context",
                "On this card: 34 tok/s with 30 % of it in VRAM — 8 of 128 experts per token"
            ],
            caveats: [
                "17.5 GiB resident, 12 GiB of it system RAM; 44 s to load; no audio",
                "Long-context recall at the 12b's level (MRCR 44 vs the 31b's 66)",
                "Tool agent below the 31b (tau2-bench 68 vs 77)"
            ],
            compare: "The Gemma to actually run here: nearly the 31b's scores at 11× its speed; ornith 35b still out-codes it.",
            source: "ai.google.dev/gemma/docs/core/model_card_4 · tools/llm/llm_tokps.py 2026-09-06"
        } },
        { re: /^gemma4:12b/, notes: {
            strengths: [
                "Hears audio: speech to text and translation (CoVoST 38.5) — the largest here that does",
                "Solid all-rounder: MMLU-Pro 77 %, GPQA 79 %, AIME 78 %",
                "Charts and photos (MMMU-Pro 69 %); 140+ languages; 256 K context",
                "On this card: 18 tok/s, 83 % in VRAM (7.6 GiB resident), 15 s to load"
            ],
            caveats: [
                "A sixth of it spills to system RAM: half the 9b's speed",
                "No published SWE-bench score; ornith 9b is the coder at this size"
            ],
            compare: "Pick it for audio or a language the ornith models lack; for code and agent work the 9b is twice as fast and stronger.",
            source: "ai.google.dev/gemma/docs/core/model_card_4 · tools/llm/llm_tokps.py 2026-09-06"
        } },
        { re: /^gemma4:e4b/, notes: {
            strengths: [
                "Quick: 57 tok/s, 3.0 GiB whole on the card, 17 s to load",
                "Hears audio (speech to text and translation) and reads images",
                "Knows enough for short answers: MMLU-Pro 69 %, GPQA 59 %",
                "128 K context"
            ],
            caveats: [
                "Hard maths and code are weak: AIME 43 %, LiveCodeBench 52 %",
                "Tool use is unreliable (tau2-bench 42 %)"
            ],
            compare: "The quick-answer and audio model; ornith 9b is worth the 1.4× slower speed for anything that needs thinking.",
            source: "ai.google.dev/gemma/docs/core/model_card_4 · tools/llm/llm_tokps.py 2026-09-05"
        } },
        { re: /^gemma4:e2b/, notes: {
            strengths: [
                "Fastest here: 109 tok/s, 1.6 GiB whole on the card, 10 s to load",
                "Hears audio and reads images",
                "Short factual answers: MMLU-Pro 60 %; 128 K context"
            ],
            caveats: [
                "Reasoning falls off: GPQA 43 %, AIME 38 %, tool agent 25 %",
                "e4b is 10 points better on every set for 1.4 GiB more"
            ],
            compare: "A lookup, not a thinker: twice e4b's speed at half its size; anything with a second step goes to e4b or the 9b.",
            source: "ai.google.dev/gemma/docs/core/model_card_4 · tools/llm/llm_tokps.py 2026-09-06"
        } },

        // -- Qwen 3.8 (Alibaba; Apache 2.0) -------------------------------------
        { re: /^qwen3\.8:27b/, notes: {
            strengths: [
                "Strongest coder here: Terminal-Bench 73 %, SWE-bench Pro 62 %, LiveCodeBench 90 %",
                "Drives a desktop from screenshots (OSWorld 84 %); reads document pages (OmniDocBench 91)",
                "Graduate science 89 % (GPQA Diamond); expert-hard 31 % (HLE) — top scores here",
                "Hybrid linear attention: long contexts cost little memory; video input"
            ],
            caveats: [
                "On this card: 3.8 tok/s, 27 % in VRAM (17 GiB resident) — the 31b's speed class",
                "Thinks at 'xhigh' effort by default: long reasoning first",
                "The publisher's own table, vs Qwen and Claude only"
            ],
            compare: "Beats ornith 35b on the hardest coding and reasoning sets at a tenth of its speed; for when the answer matters more than the wait.",
            source: "huggingface.co/Qwen/Qwen3.8-27B · tools/llm/llm_tokps.py 2026-09-06"
        } },

        // -- Granite 4.2 (IBM; Apache 2.0; text only) ---------------------------
        { re: /^granite4\.2:30b/, notes: {
            strengths: [
                "Calls functions correctly: BFCL v4 61 %, the best tool-calling score here",
                "Long-context recall 81 % (RULER 128 K); 12 languages including Dutch",
                "Enterprise tuning: RAG, extraction, JSON output; a low-effort thinking mode"
            ],
            caveats: [
                "Text only: no images, PDF pages or audio",
                "Coding trails: SWE-bench Verified 57, Terminal-Bench 29 (qwen3.8 73)",
                "On this card: 3.8 tok/s, 35 % in VRAM (19 GiB resident) — the 31b's speed class"
            ],
            compare: "Redundant here: qwen3.8:27b is the same speed class, far stronger, and reads images; the 8b is the Granite to keep.",
            source: "ibm.com/granite (vendor table) · ollama.com/library/granite4.2 · tools/llm/llm_tokps.py 2026-09-06"
        } },
        { re: /^granite4\.2:8b/, notes: {
            strengths: [
                "Fits the card whole: 43 tok/s, 6.1 GiB in VRAM, 8 s to load",
                "Competition maths 87 % (AIME25); MMLU-Pro 74 %",
                "Function calling 50 % (BFCL v4); policy agent 58 % (tau3-bench); Dutch among 12 languages",
                "Low-effort thinking mode; JSON output; 128 K context"
            ],
            caveats: [
                "Text only: no images, PDF pages or audio",
                "Coding agent trails ornith 9b: SWE-bench Verified 48 vs 71"
            ],
            compare: "Keep it for Dutch, structured extraction and tool calls with no image involved; ornith 9b otherwise, at the same speed.",
            source: "ibm.com/granite (vendor table) · ollama.com/library/granite4.2 · tools/llm/llm_tokps.py 2026-09-06"
        } },
        { re: /^granite4\.2:3b/, notes: {
            strengths: [
                "Small and quick: 87 tok/s, 2.7 GiB whole on the card, 5 s to load",
                "Routing, classification, extraction; function calling as good as the 8b (BFCL v4 52 %)",
                "12 languages including Dutch; 128 K context"
            ],
            caveats: [
                "Text only; no agent training (that starts at the 8b)",
                "MMLU-Pro 68 %: gemma4:e4b matches it and reads images and audio"
            ],
            compare: "Redundant next to gemma4:e4b unless you want the fastest tool-caller, or Dutch, on the smallest budget.",
            source: "ibm.com/granite (vendor table) · ollama.com/library/granite4.2 · tools/llm/llm_tokps.py 2026-09-06"
        } },

        // -- Muse Glimmer (Meta; Apache 2.0) ------------------------------------
        { re: /^muse-glimmer:30b/, notes: {
            strengths: [
                "Best agent here: chains MCP tools 76 % (MCP-Atlas; gemma4:31b 54), recovers when a tool fails",
                "Web research 75 % (DeepSearch QA); competition maths 95 % (AIME 2026)",
                "Newest knowledge here: cut-off January 2026",
                "Long-context reasoning 80 % (AA-LCR); charts 79 % (CharXiv)"
            ],
            caveats: [
                "On this card: 4 tok/s, 32 % in VRAM (16 GiB resident) — the 31b's speed class",
                "Coding trails qwen3.8:27b (SWE-bench Pro 51 vs 62)",
                "No audio; video as frames; the publisher's own table"
            ],
            compare: "The model for tool-driven work if you will wait for it; for plain chat the ornith models answer 10× sooner.",
            source: "huggingface.co/meta-models/Muse-Glimmer-30B · tools/llm/llm_tokps.py 2026-09-06"
        } },

        // -- Families: a tag not listed above -----------------------------------
        { re: /^ornith/, notes: {
            strengths: [
                "Ornith 1.5: a Qwen3.5 base tuned by RL on self-generated tasks",
                "Coding and agent work first: SWE-bench, Terminal-Bench, MCP-Atlas",
                "Reads images; 256 K context; MIT licence"
            ],
            caveats: [ "Thinks by default; the publisher's own table" ],
            compare: "The 9b is the everyday model here, the 35b the working one.",
            source: "ollama.com/library/ornith-1.5"
        } },
        { re: /^gemma4/, notes: {
            strengths: [
                "Google's Gemma 4: broad knowledge, 140+ languages, charts and photos",
                "e2b, e4b and 12b also hear audio; 12b and up have 256 K context"
            ],
            caveats: [ "Knowledge ends January 2025" ],
            compare: "On this card e2b to 12b run mostly in VRAM; 26b is the MoE, 31b the flagship at 3 tok/s.",
            source: "ollama.com/library/gemma4"
        } },
        { re: /^qwen/, notes: {
            strengths: [
                "Alibaba's Qwen: the strongest coding and computer-use scores here",
                "Reads images, documents and video; 256 K context"
            ],
            caveats: [ "Thinks at high effort by default" ],
            compare: "The 27b beats ornith 35b on the hardest sets at a tenth of its speed here.",
            source: "ollama.com/library/qwen3.8"
        } },
        { re: /^granite/, notes: {
            strengths: [
                "IBM's Granite 4.2: tool calling, RAG, JSON output, 12 languages including Dutch",
                "Thinking switch with a low-effort mode; 128 K context; Apache 2.0"
            ],
            caveats: [ "Text only" ],
            compare: "The 8b is the Granite to keep here; the 30b is the 31b's speed class.",
            source: "ollama.com/library/granite4.2"
        } },
        { re: /^muse/, notes: {
            strengths: [
                "Meta's Muse Glimmer: local agents, tool chains, failure recovery",
                "Reads images; 128 K context; Apache 2.0"
            ],
            caveats: [ "Dense 30 B: the 31b's speed class here" ],
            compare: "The agent model if you will wait for it.",
            source: "ollama.com/library/muse-glimmer"
        } }
    ]

    function notesFor(model) {
        const id = String(model || "").toLowerCase().trim();
        if (id.length === 0)
            return null;
        for (let i = 0; i < registry.patternNotes.length; i++) {
            const rule = registry.patternNotes[i];
            if (rule && rule.re && rule.re.test(id))
                return rule.notes;
        }
        return null;
    }
}
