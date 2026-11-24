pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// LlmAttachmentLoader.qml
//
// The LLM module's attachment pipeline, headless. `load(path)` probes the
// file, resolves it into one of six kinds and emits the finished attachment
// object; the popup only forwards chips. Everything runs through external
// Processes, ONE at a time (the queue is preserved across loads), and nothing
// here draws: the component's proof is the objects it emits.
//
// Attachment shape (every field always present):
//   { attachKey, path, name, mime, kind, isImage, b64, textContent, images, pageCount,
//     durationMs, peaks, pending, failed, failReason,
//     includeImages, imagesRendered, imageMode, imageCount, imagePages,
//     imageTokens, imageDupes, imageNote, pageThumbB64, thumbB64, opts }
//
// Kinds:
//   image  b64 of the file itself (rides the wire as an image).
//   text   textContent read DIRECTLY off the file with `cat` -- no base64
//          round-trip, so no decode and no deprecated Qt.atob. Files over
//          `attachTextCapBytes` are refused, empty files too.
//   pdf    pdftotext -layout for textContent (truncated at the same cap),
//          pdfinfo for pageCount, and pictures into images[] -- see "PDF
//          PICTURES" below.
//   video  `videoFrameCap` evenly-spaced frames (ffmpeg, at d*(i+.5)/n) as
//          base64 PNGs into images[], durationMs from ffprobe. Frames-as-
//          images is the only video support today's wire has -- measured.
//   audio  refused: failed with "audio cannot reach the model yet" (Ollama
//          0.33.2 silently drops audio on both wires -- measured).
//          Still resolved with durationMs and ~`audioPeakCount` amplitude
//          peaks 0..1 (ffmpeg to mono u8, max-abs per bucket) so the chip's
//          waveform tooltip can draw what it cannot send.
//   other  refused on the chip, quietly.
//
// -----------------------------------------------------------------------------
// PDF PICTURES. A question about "page 7" needs the pictures that are IN the
// document, each carrying the page it came from: a render of page 7 that
// nothing in the message identifies as page 7 is useless, and everything past
// a page cap is never sent at all. So `imageMode` defaults to "embedded" and
// EXTRACTS them:
//
//   1. INVENTORY. `pdfimages -list` names every image XObject with its page,
//      pixel size and object id. Only rows whose type is `image` are pictures:
//      poppler also lists `smask` rows (a picture's alpha channel -- 27 of the
//      59 rows in the test deck) and `stencil` rows (1-bit paint masks).
//      Counting those would inflate every number the user sees, and sending
//      one would send a silhouette instead of a picture.
//   2. EXTRACT. One `pdfimages -png -p -print-filenames` writes every image
//      into a temp dir as `<root>-<page>-<num>.png`, where <num> is the SAME
//      counter as the `num` column of `-list`. So the pairing between a list
//      row and its file is by name, not by position -- a smask file can never
//      be mistaken for a picture even if poppler skips a row. Verified on the
//      test deck: 59 rows, 59 files, page and num equal on every one, and
//      every file's pixel size equal to its row's.
//   3. FILTER. Two floors, both measured against the test deck:
//      `pdfImageMinArea` 10000 px^2 throws out bullets and icons. Its smallest
//      real picture is 127x129 = 16383 px^2, so the floor has 1.6x of room; a
//      decorative glyph is 64x64 = 4096 or less.
//      `pdfImageMinBytesPerPixel` 0.02 throws out DECORATIONS, which the area
//      floor cannot: 9 of the 32 placements in this deck are arrows and rules
//      up to 902x782 px stored as a solid black fill plus an alpha mask. As
//      extracted they are blank rectangles -- worse than nothing, since each
//      would still cost the model ~256 tokens. A picture that carries no
//      information deflates to almost nothing, and the gap is enormous: the 9
//      decorations come out at 0.003-0.009 B/px, the 23 real pictures at
//      0.14-1.69 B/px. 0.02 sits 2.2x above the worst decoration and 7x below
//      the cheapest picture; it leans towards the picture because dropping a
//      real one costs content while keeping a decoration only costs tokens.
//   MASK-DRAWN IMAGES, counted rather than composited. Some PowerPoint
//      exports store a drawing as a SOLID-COLOUR rgb object plus an /SMask
//      that carries the whole picture; extracted on its own the rgb is a blank
//      rectangle, which is why the density floor drops it. Nine of the 32
//      placements in the test deck are like that (8 objects, pages 41, 44,
//      51, 54) and 33 in the heaviest deck of the same set.
//      Compositing them -- the rgb painted through its mask onto white -- is
//      the obvious fix and it does not work (measured).
//      Composited, the 41 mask-drawn objects across those two decks are 4 real
//      figures (three burn-down charts and a kanban screenshot) and 37
//      arrows, dashed connectors, strike-through rules, crossing-out X marks
//      and drop-shadow plates -- and their densities INTERLEAVE: the four
//      figures land at 0.022-0.031 B/px, BELOW 29 of the 37 decorations (which
//      run up to 0.142). No floor separates them. Compositing therefore means
//      sending every arrow and shadow plate to gain four charts, and on the
//      test deck it gains ZERO figures while adding eight crossing-out
//      X strokes whose meaning inverts once they are away from the text they
//      cross out. It would also make ImageMagick a runtime dependency.
//      So they are COUNTED and NAMED instead: the note says "8 images, on
//      pages 41, 44, 51 and 54, are drawn as transparency masks and could not
//      be extracted; page mode can send those pages". The omission is visible,
//      and it points at the mode that renders those pages exactly as drawn --
//      which is what actually gets those burn-down charts to the model.
//   4. DEDUP. By object id first (free, exact: three objects in this deck are
//      placed on two pages each), then by md5 of the extracted bytes (the same
//      logo stored twice as two objects). Every dropped placement counts into
//      `imageDupes`. A repeated picture rides ONCE, listed at the page it
//      first appears on, and `imageNote` says so.
//   5. PAGE ATTRIBUTION. The script emits page, width, height and the base64
//      on ONE line, so `imagePages[]` is built from the same lines as
//      `images[]` and cannot drift out of order. That mapping is the whole
//      point of the feature: LlmService names it on the wire.
//
// COST, measured on gemma4:e4b (prompt_eval_count against a 21-token baseline
// question). Unlike a page render, an extracted picture does NOT cost a flat
// 256: the model's own geometry is a 16 px patch pooled 3x3, so one token
// covers 48x48 px of the picture, and a picture smaller than the encoder's
// 768x768 input costs less. Eighteen pictures from this deck measured 44..212
// tokens each (and a 902x782 decoration, big enough to fill the encoder, 257
// -- the ceiling), and
//
//      tokens ~ clamp(round(w*h / 2304), 50, 258)          (2304 = 48^2)
//
// predicts them to within 14% each and -2.7% in aggregate over 12 pictures
// held out of the fit. The whole deck: 21 pictures measured 1534 tokens on the
// wire against 1500 predicted (-2.2%). That is what `imageTokens` publishes.
// For comparison, the same deck in "pages" mode costs 266 tokens PER PAGE
// (measured here; 268 on the wire): 24 pages =
// 6432 tokens while missing pages 25-74, all 74 pages = 19832. Extraction is
// four times cheaper AND complete.
//
// CAPS. `pdfImageCap` 32 pictures. The service gives pictures half the window,
// and at the 25600 the ctx tuner verified for gemma4:e4b on this machine that
// is 12800 tokens -- 32 pictures cost 8256 in the worst case (all of them at
// the 258 ceiling) and 2300 on this deck's average, so the cap is a decision
// the user can see and turn off rather than a limit that ever binds silently;
// on a small window the service's own budget takes over and names its cut. The
// cap exists for the pathological file: 300 pictures is 21000 tokens at this
// deck's average and 77000 at the ceiling -- either way past the largest
// window the tuner will build. The 74-page test deck yields 21, so it rides
// whole, which is the point.
// `pdfImageScanCap` 400 placements bounds the WORK rather than the wire:
// poppler decodes every image twice (once to list, once to write), which is
// 1.2 s and 1.4 MB of temp for this deck but 14 s and 6.3 MB for the heaviest
// one in the same folder. 400 is 12x the picture cap, so the filters would
// have to reject 92% of what they see before the scan cap could starve it.
// Both cuts are stated in `imageNote`; nothing is ever dropped silently.
//
// VECTOR ART. A deck whose figures are drawn rather than placed yields NOTHING
// to extract -- five of the six pdfs in a folder of course material have zero
// image placements. That is why the page-render path survives as an explicit
// `imageMode: "pages"`, one code path per mode with no hybrid guessing, and
// why `imageNote` says "vector art" instead of leaving an empty chip
// unexplained. In "pages" mode: pages 1..`pdfPageCap` at `pdfDpi`, 268 tokens
// each, `imagePages` = 1..n.
//   pdfPageCap 24 = 6432 tokens; pdfDpi 110 because 768 is the encoder's input
//   edge and 110 is the first round number that upscales no common page size
//   (A4/letter portrait need 93/90, a 4:3 or 16:9 slide 102.4). Measured: a
//   5 pt line reads as "ECHO-VIRLAN-55" at 90 dpi and correctly as
//   "ECHO-VORLAN-55" at 110; above 110 the reading gets no better and the
//   bytes grow. Neither figure moves with resolution -- one page sent at 90,
//   110, 130 and 150 dpi comes back at prompt_eval_count 305 every time, and
//   page 7 of THIS deck at 90/110/150 dpi comes back at 287 every time.
//
// The user can turn the pictures off per attachment -- `includeImages`, which
// the chip toggles and the service honours at wire time. It defaults to
// `pdfImagesByDefault` (true), and the pictures are produced ONCE: switching
// it on for a pdf that has none yet runs the pipeline then (`setIncludeImages`,
// the attachment goes `pending` while it runs), switching it off leaves them
// in the object so switching back is free. `imagesRendered` is what makes that
// a promise rather than a hope.
//
// RE-EXTRACTION. The caps are the user's own settings -- the pdf
// menu edits `pdfImageCap` / `pdfImageMinArea` / `pdfPageCap` / `imageMode`
// on a slider -- so a pdf that already resolved can have its picture pass run
// AGAIN under the caps of the moment: `reextract(att)`. Only the pass runs;
// the text and the page count stay as read. The attachment goes `pending` and
// comes back through `resolved` as a fresh object, exactly like a load, so
// the host has one path for both. Calls COALESCE: the menu fires as a slider
// settles, and a second call while the pass is running supersedes the first
// -- that run's result is dropped, never resolved, and the pass runs once
// more under the current caps. One resolve per burst, always the last caps.
// The running child is deliberately NOT killed: sh has no TERM trap, so a
// SIGTERM ends it at once without its EXIT trap, leaving pdfimages orphaned
// and its temp directory behind; the pass is 1.2 s on the test deck, and
// letting it finish and discarding it is cheaper than that mess.
//
// PER-FILE SETTINGS. The caps are not global. A deck whose
// figures are vector art wants "pages", the next file wants 32 pictures, and
// one setting for both is a setting for neither -- so every attachment carries
// its OWN overrides:
//
//      att.opts = { imageCap, imageMinArea, pageCap, imageMode }   // any subset
//
// A picture pass resolves each of those four PER KEY (`_opt`): the
// attachment's own value first, the loader's property second. An attachment
// that overrides the mode alone still follows the panel's caps, and the
// loader's properties stay what a NEWLY attached file runs under.
// `setOpts(att, opts)` merges (a null value REMOVES an override, putting that
// one setting back on the loader's property) and re-extracts THAT attachment
// under the merged values -- it is `reextract` with a merge in front of it,
// coalescing exactly as it does.
// `opts` rides the shallow copy `_finish` makes, so every generation of an
// attachment shares ONE opts object: a menu holding a chip across a resolve
// is still editing the settings the next pass will read, and settings written
// on the `queued` chip land on the load that is already in flight.
// The coalescing matches the attachment by IDENTITY, not by path: the same
// file can be attached twice with different settings, and a path match would
// let a change to one chip supersede -- and silently swallow the resolve of --
// the other's pass.
// The host cannot compare identities, because every resolve is a FRESH object
// -- so the identity is PUBLISHED as `attachKey`: a short string handed out
// once, when the attachment is created, and carried unchanged through every
// copy `_finish` makes and every `reextract`, `setOpts` and
// `setIncludeImages`. The chip from `queued` and every later `resolved` for
// that chip share one key; two attachments of the same file never do. It is
// the key a host matches a resolve on -- `path` cannot tell twins apart, and
// `path` + `pending` hands one twin's result to the other.
//
// THE PAGE THUMBNAIL. `images[0]` is page 1 only while the pipeline renders
// pages; in embedded mode it is the first PICTURE, so a 74-page deck would
// show whatever logo sits on page 2.
// `pageThumbB64` is a page-1 render for EVERY pdf -- whatever the mode,
// whatever `includeImages`, whatever the caps -- produced in the SAME child as
// the text and the page count, so it costs no extra process and no extra
// round through the queue. It is a thumbnail and never a payload: nothing here
// puts it in `images[]`, and LlmService copies a fixed list of fields into a
// stored attachment, so it reaches neither the wire nor the store.
// `pdfThumbPx` 640, the LONGEST EDGE (`pdftoppm -scale-to`), not a dpi: the
// chip's hover tip fits a preview into 280x200 logical px and decodes at up to
// 2x, so 640x480 device px is the most any page shape has to supply (a 4:3
// slide is the tightest; a 16:9 slide needs 560x315, A4 portrait 283x400). A
// dpi would give the same picture a size that depends on the paper -- 60 dpi
// is 800x450 on a slide and 4000 px wide on an A0 sheet. MEASURED, one
// render at 640: the 74-page slide deck 30 ms and 27 KB of base64, the
// A4 text deck 47 ms and 87 KB, against a pdf text stage of 45 ms.
//
// THE THUMBNAIL THAT IS KEPT. `pageThumbB64` is built to be thrown away --
// 27-87 KB of PNG per pdf, deliberately kept out of the store -- so on its own
// a chip above a SENT prompt would have no preview, nor would an image's tip
// after a reload once the payload cap has stripped its b64.
// `thumbB64` is the preview that SURVIVES: one small JPEG for every pictorial
// kind, produced at load and persisted with the message, whitelisted by
// LlmService's store copy and exempt from LlmStore's payload caps because it
// is the one payload that must outlive them. It is never on the wire: the
// service's wire builder reads b64 / images / textContent and nothing else.
//   image  the file itself, scaled;  pdf  page 1;  video  the FIRST FRAME
//   THE MODEL SEES (frame 1 of n, at d/2n -- not t=0, which is so often a
//   black fade-in that it would preview nothing).
// ONE RULE FOR ALL THREE, and the numbers behind it, measured on this machine:
//   `thumbPx` 240 = the LONGEST EDGE, never upscaled (a 100 px icon stays
//   100 px). The chip's tip fits a preview into 280x200 logical px and this
//   display is scale 1, so 240 shows 1:1 at 86% of the box; 280 would fill
//   it but puts a 4:3 photo at 17 KB of base64, and 12 KB is the budget --
//   a store of 200 conversations that each kept two photos would carry 4.8
//   MB of thumbnails at 12 KB, 65 ms of JSON at the store's measured 13.5
//   ms/MiB, and that is the worst case, not the usual one.
//   JPEG, through ONE encoder for every kind: ffmpeg's mjpeg at -q:v 8. On
//   the 240 px resize of a 4400x1886 wheat-field photo -- the noisiest
//   source to hand -- that is 30.5 dB PSNR against the lossless resize for
//   5.4 KB of JPEG (7.2 KB as base64), the PSNR libjpeg gives at quality 85
//   for 71% of its bytes. PNG
//   is not a candidate: the same photo is 41 KB as PNG at this size, and a
//   slide, the one thing PNG compresses well, is 6.7 KB as PNG against 4.2
//   KB as JPEG.
//   Base64 cost at 240 px, -q:v 8, through the shipped pipeline: the
//   74-page deck 4284 B (240x135),
//   an A4 text page 8392 B (portrait, 170x240), the photo 7204 B (240x103;
//   a 4:3 photo comes to ~12.6 KB at its 0.29 B/px), a shell screenshot
//   3712 B (240x109), a 2880x1620 video frame 5400 B (240x135). Time per
//   preview: 40 ms for a pdf page (pdftoppm at 240 plus the encode), 45 ms
//   for the screenshot, 0.30 s for the 9.6 MB photo (its decode is the
//   cost), 140 ms for a decoded 2880x1620 frame's PNG.
//   Transparent pixels are flattened on WHITE (the tip's surface is light in
//   both themes' terms of what a picture sits on) rather than the black a
//   bare JPEG conversion produces -- measured: the corner of a transparent
//   png comes out (255,255,255), and the same filter on an opaque jpeg is
//   the identity. EXIF orientation is applied by ffmpeg itself (a 400x200
//   jpeg tagged orientation 6 comes out 120x240, the right way up).
//   Qt decodes it under either `data:image/png` or `data:image/jpeg`
//   (measured: the reader sniffs the magic bytes), so a consumer's existing
//   prefix keeps working.
// `pageThumbB64`, the 640 px PNG, is read by the chip only when an object
// carries no `thumbB64`.
// =============================================================================

Item {
    id: root

    visible: false
    width: 0
    height: 0

    // ---- Options -----------------------------------------------------------
    // Text files ride inline, but only whole ones the model can actually eat.
    property int attachTextCapBytes: 49152

    // How a pdf becomes pictures: "embedded" extracts the images that are IN
    // the document, each tagged with its page; "pages" renders whole pages.
    // Embedded is the default because it is sharper, four times cheaper and
    // complete; pages is the answer for a deck drawn in vector art. One code
    // path per mode -- the loader never guesses between them.
    property string imageMode: "embedded"

    // -- embedded mode. All four argued from measurement in the header.
    property int pdfImageCap: 32
    property int pdfImageScanCap: 400
    property int pdfImageMinArea: 10000
    property real pdfImageMinBytesPerPixel: 0.02

    // -- pages mode. Argued from measurement in the header.
    property int pdfPageCap: 24
    property int pdfDpi: 110

    // The chip's page-1 thumbnail, longest edge in pixels. Argued and
    // measured in THE PAGE THUMBNAIL above; it is never sent to a model.
    property int pdfThumbPx: 640
    // The PERSISTED preview's longest edge, every pictorial kind, never
    // upscaled -- argued and measured in THE THUMBNAIL THAT IS KEPT above.
    property int thumbPx: 240
    // ffmpeg's mjpeg quality dial for it (2 best .. 31 worst): 8 is 30.5 dB
    // on the reference photo for 5.4 KB -- see the header for the sweep.
    readonly property int _thumbQ: 8

    // What a NEW pdf attachment's `includeImages` starts as. True is the
    // answer for a vision model; a host that would rather pay for pictures
    // only when asked sets this false and the chip's toggle produces them.
    property bool pdfImagesByDefault: true
    // Frames of a clip that ride as images. Four keeps a clip representative
    // without flooding a small model's context.
    property int videoFrameCap: 4
    // Buckets for the audio waveform tooltip.
    property int audioPeakCount: 96

    // The next attachment's key. Monotonic for the life of the loader, which
    // is the life of the host: nothing here has to survive a restart, because
    // a key only ever names a chip that is on screen now.
    property int _nextKey: 1

    // ---- Signals -----------------------------------------------------------
    signal queued(var att)      // the pending chip, immediately on load()
    signal resolved(var att)    // the finished object, same `path` key

    // ---- API ---------------------------------------------------------------
    function load(path) {
        if (!path || path.length === 0)
            return;
        const key = "a" + root._nextKey;
        root._nextKey = root._nextKey + 1;
        const att = {
            // This chip's identity on the wire between loader and host: see
            // PER-FILE SETTINGS. Never reassigned, never reused.
            attachKey: key,
            path: path,
            name: path.substring(path.lastIndexOf("/") + 1),
            mime: "",
            kind: "",
            isImage: false,
            b64: "",
            textContent: "",
            images: [],
            pageCount: 0,
            durationMs: 0,
            peaks: [],
            pending: true,
            failed: false,
            failReason: "",
            // The pdf picture flag and its bookkeeping. Present on every kind
            // -- true is the fail-safe value, and it is only ever read for a
            // pdf -- so no consumer has to test the kind first. The five
            // reporting fields below are pdf-only and stay at zero elsewhere,
            // where images[] speaks for itself.
            includeImages: true,
            imagesRendered: false,
            imageMode: "",
            imageCount: 0,
            imagePages: [],
            imageTokens: 0,
            imageDupes: 0,
            imageNote: "",
            // A small page-1 render, for the chip to draw. Every pdf gets
            // one; it never rides the wire. Empty on every other kind.
            pageThumbB64: "",
            // The small JPEG preview that is persisted with the message and
            // never sent: image, pdf page 1, video frame 1. Empty elsewhere.
            thumbB64: "",
            // This file's own picture settings, any subset of
            // { imageCap, imageMinArea, pageCap, imageMode }. An absent key
            // means the loader's property. Shared by reference with every
            // copy of this attachment -- see PER-FILE SETTINGS.
            opts: {}
        };
        root._queue.push({ att: att, task: "load" });
        root.queued(Object.assign({}, att));
        root._pump();
    }

    // Turn a pdf attachment's pictures on or off AFTER it was attached -- the
    // chip's toggle. The flag is written on the object the caller handed in
    // (that object, not this loader, is what the service reads at wire time)
    // and the pictures are produced if turning on is the first time anyone
    // asked for them; `resolved` then arrives with the patched attachment, as
    // it does for a fresh load. Returns the same object, so a host can install
    // it straight into its array.
    //
    // Every call that could leave a chip waiting ends in a `resolved` -- even
    // the ones with nothing to do (a failed pdf, a pdf whose pictures already
    // came back empty). Nothing here produces pictures that exist.
    function setIncludeImages(att, on) {
        if (!att)
            return att;
        const want = (on !== false);
        att.includeImages = want;
        if (att.pending)            // a resolve is already on its way
            return att;
        if (!want)                  // the pictures stay in the object, unsent
            return att;
        if (att.images && att.images.length > 0)
            return att;             // produced once, kept for free
        if (att.kind === "pdf" && !att.failed && !att.imagesRendered
                && att.pageCount > 0)
            root._enqueue(att, "images");
        else
            root._enqueue(att, "settle");
        return att;
    }

    // Run the picture pass of a pdf that already resolved AGAIN, under the
    // loader's caps and mode as they are NOW -- the pdf menu calls this as a
    // slider settles. The text and page count are not re-read. The object
    // goes `pending` and comes back through `resolved` as a fresh object,
    // like a load; returns the same object, as `setIncludeImages` does.
    // Coalesced: a call for an attachment whose job is running marks that
    // job -- its result is dropped and the pass runs once more under the
    // settings of the moment (`_finish`); a call for one still waiting in the
    // queue marks the record the same way, and a pass reads the settings when
    // it starts. Either way exactly one `resolved` follows, with the last
    // settings. THIS attachment, by identity: two chips of the same file keep
    // their own settings and their own resolve (see PER-FILE SETTINGS).
    // Not a pdf, or one that never read: nothing to run, nothing goes
    // pending, and the object comes back untouched with no resolve to wait
    // for -- the host calls this on every pdf chip it holds.
    function reextract(att) {
        if (!att || att.kind !== "pdf" || att.failed || !(att.pageCount > 0))
            return att;
        if (root._job !== null && root._job === att) {
            att.pending = true;
            root._again = true;
            return att;
        }
        for (let i = 0; i < root._queue.length; i++) {
            if (root._queue[i].att === att) {
                att.pending = true;
                root._queue[i].again = true;
                return att;
            }
        }
        root._enqueue(att, "images");
        return att;
    }

    // This ONE file's picture settings. `opts` is any subset of
    // { imageCap, imageMinArea, pageCap, imageMode }: the keys given are
    // merged into `att.opts` and the picture pass runs again for this
    // attachment alone under the merged values. A key given as null is
    // REMOVED, which puts that setting back on the loader's property; a key
    // given as undefined is left alone, so a caller may pass a whole record
    // with holes in it. Everything else is `reextract`: the coalescing, the
    // fresh object through `resolved`, and the same object returned.
    function setOpts(att, opts) {
        if (!att)
            return att;
        if (!att.opts)
            att.opts = {};
        const o = opts || {};
        for (const k in o) {
            if (o[k] === undefined)
                continue;
            if (o[k] === null)
                delete att.opts[k];
            else
                att.opts[k] = o[k];
        }
        return root.reextract(att);
    }

    // One picture setting for one attachment: its own override first, the
    // loader's property second, per key.
    function _opt(att, name, dflt) {
        const o = att ? att.opts : null;
        return (o && o[name] !== undefined && o[name] !== null) ? o[name] : dflt;
    }

    // ---- Pipeline ----------------------------------------------------------
    // The queue holds jobs, not attachments: a first load, a lazy picture run
    // for an attachment that already resolved, and a "settle" that does
    // nothing and exists only so a toggle the loader cannot act on still comes
    // back to the host instead of leaving a chip pending for ever.
    property var _queue: []
    property var _job: null          // the attachment being resolved
    property string _stage: ""       // "probe" | "extract" | "pages" | "embedded"
    // A `reextract` landed on the running job: whatever it is producing is
    // stale. Cleared when a picture pass starts (that pass reads the current
    // caps, so the request is met), consumed by `_finish` otherwise.
    property bool _again: false

    function _enqueue(att, task) {
        att.pending = true;
        root._queue.push({ att: att, task: task });
        root._pump();
    }

    function _pump() {
        if (root._job !== null || root._queue.length === 0)
            return;
        const rec = root._queue.shift();
        root._job = rec.att;
        root._again = (rec.again === true);
        if (rec.task === "images") {
            root._startImages();
            return;
        }
        if (rec.task === "settle") {
            // Not inline: _finish() pumps, and re-entering the pump from
            // inside it is how a queue starts eating its own tail.
            Qt.callLater(root._settle);
            return;
        }
        root._stage = "probe";
        // One child, two answers: the mime type and the size. The loader
        // decides what kind of attachment that adds up to.
        _proc.command = ["sh", "-c", 'file --brief --mime-type "$1"; stat -c %s "$1"', "_", root._job.path];
        _proc.running = true;
    }

    function _settle() {
        if (root._job !== null)
            root._finish({});
    }

    function _finish(patch) {
        const att = root._job;
        // Superseded by a `reextract` while it ran: this result is dropped,
        // never resolved, and the picture pass runs once more under the caps
        // of the moment. A pdf that could not be read has no pass to run and
        // finishes as it is.
        if (root._again) {
            root._again = false;
            if (att.kind === "pdf" && !att.failed && patch.failed !== true
                    && att.pageCount > 0) {
                root._startImages();
                return;
            }
        }
        root._job = null;
        root._stage = "";
        for (const k in patch)
            att[k] = patch[k];
        att.pending = false;
        // A FRESH object every time: the host's delegates compare identities,
        // and an in-place patch of the object they already hold is a change
        // nothing in QML can see.
        root.resolved(Object.assign({}, att));
        root._pump();
    }

    // Textual application/* types `file` reports for code and config that
    // plain text/* misses.
    readonly property var _textualMimes: ["application/json", "application/javascript", "application/xml", "application/x-shellscript", "application/x-yaml", "application/yaml", "application/toml", "application/x-perl", "application/x-ruby", "application/csv"]

    function _kindOf(mime) {
        if (mime.indexOf("image/") === 0)
            return "image";
        if (mime === "application/pdf")
            return "pdf";
        if (mime.indexOf("video/") === 0)
            return "video";
        if (mime.indexOf("audio/") === 0)
            return "audio";
        if (mime.indexOf("text/") === 0 || root._textualMimes.indexOf(mime) >= 0)
            return "text";
        return "other";
    }

    function _onProbed(code, out) {
        const firstNl = out.indexOf("\n");
        if (code !== 0 || firstNl < 0) {
            root._finish({ failed: true, failReason: "could not read the file" });
            return;
        }
        const mime = out.substring(0, firstNl).trim();
        const size = parseInt(out.substring(firstNl + 1).trim(), 10) || 0;
        const kind = root._kindOf(mime);
        const att = root._job;
        att.mime = mime;
        att.kind = kind;
        att.isImage = (kind === "image");
        const p = att.path;
        switch (kind) {
        case "image":
            root._stage = "extract";
            _proc.command = ["sh", "-c", root._imageScript, "_", p, String(root.thumbPx)];
            _proc.running = true;
            break;
        case "text":
            if (size === 0) {
                root._finish({ failed: true, failReason: "empty file" });
            } else if (size > root.attachTextCapBytes) {
                root._finish({ failed: true, failReason: "too large to inline (" + Math.floor(root.attachTextCapBytes / 1024) + " KB cap)" });
            } else {
                // Read the text straight off the file: no base64 round-trip,
                // no decode, no Qt.atob (deprecated, warned on every attach).
                root._stage = "extract";
                _proc.command = ["cat", p];
                _proc.running = true;
            }
            break;
        case "pdf":
            // The pictures are a policy the user can change, so they are their
            // own stage; this one is the text and the page count, which are
            // needed either way.
            att.includeImages = root.pdfImagesByDefault;
            root._stage = "extract";
            _proc.command = ["sh", "-c", root._pdfTextScript, "_", p, String(root.attachTextCapBytes), String(root.pdfThumbPx), String(root.thumbPx)];
            _proc.running = true;
            break;
        case "video":
            root._stage = "extract";
            _proc.command = ["sh", "-c", root._videoScript, "_", p, String(root.videoFrameCap), String(root.thumbPx)];
            _proc.running = true;
            break;
        case "audio":
            root._stage = "extract";
            _proc.command = ["sh", "-c", root._audioScript, "_", p, String(root.audioPeakCount)];
            _proc.running = true;
            break;
        default:
            // Neither image, text, pdf nor av: the chip says no, quietly,
            // instead of a dialog saying it loudly.
            root._finish({ failed: true, failReason: "unsupported file type" });
            break;
        }
    }

    // ---- Extract scripts ----------------------------------------------------
    // Line protocol on stdout: "@@ATT-META <key> <value>", "@@ATT-IMG <b64>",
    // "@@ATT-IMGP <page> <w> <h> <b64>", "@@ATT-B64 <b64>" (an image's own
    // file), "@@ATT-PEAKS <v v v...>", and one raw text block between
    // "@@ATT-TEXT-BEGIN" / "@@ATT-TEXT-END".

    // The one thumbnail encoder, as a shell function every script defines
    // first: `thumb <file-or->` prints the base64 of a JPEG whose longest
    // edge is $TP, never upscaled, transparent pixels flattened on white.
    // Argued in THE THUMBNAIL THAT IS KEPT. Empty output on any failure (an
    // svg, a codec ffmpeg lacks) -- the callers then publish no preview.
    readonly property string _thumbFn:
        "thumb() { ffmpeg -v error -i \"$1\" -vf \""
        + "scale=w='if(gt(iw,ih),min(iw,$TP),-1)':h='if(gt(iw,ih),-1,min(ih,$TP))':flags=lanczos,"
        + "format=rgba,split[a][b];[a]drawbox=c=white:t=fill[w];[w][b]overlay=format=auto,format=rgb24\""
        + " -frames:v 1 -f image2pipe -c:v mjpeg -q:v " + root._thumbQ
        + " - 2>/dev/null | base64 -w0; }\n"

    // An image: its preview, then the file itself. The file's base64 goes
    // straight from `base64` to stdout behind its tag -- never through a
    // shell variable, a 40 MB photo is not something to copy.
    readonly property string _imageScript: 'p="$1"; TP="$2"\n' + root._thumbFn
        + 't=$(thumb "$p")\n' + '[ -n "$t" ] && echo "@@ATT-META thumb $t"\n'
        + 'printf "@@ATT-B64 "\n' + 'base64 -w0 "$p" || exit 2\n' + 'echo ""\n'

    // The text, the page count and both page-1 thumbnails: one child for
    // all of them, because they are what every pdf needs whatever its picture
    // settings say. The thumbnails go out as meta -- base64 -w0 is one line
    // with no spaces in it -- and before the text block, which is lifted out
    // by index before any line is read. `pagethumb` is the 640 px PNG the
    // chip falls back to; `thumb` is the persisted JPEG.
    readonly property string _pdfTextScript: 'p="$1"; txcap="$2"; pthumb="$3"; TP="$4"\n' + root._thumbFn + 'n=$(pdfinfo "$p" 2>/dev/null | awk \'/^Pages:/{print $2}\')\n' + '[ -n "$n" ] || n=0\n' + 'echo "@@ATT-META pages $n"\n' + 'if [ "$n" -gt 0 ]; then\n' + '  t=$(pdftoppm -png -scale-to "$pthumb" -f 1 -l 1 -singlefile "$p" 2>/dev/null | base64 -w0)\n' + '  [ -n "$t" ] && echo "@@ATT-META pagethumb $t"\n' + '  s=$(pdftoppm -png -scale-to "$TP" -f 1 -l 1 -singlefile "$p" 2>/dev/null | thumb -)\n' + '  [ -n "$s" ] && echo "@@ATT-META thumb $s"\n' + 'fi\n' + 'echo "@@ATT-TEXT-BEGIN"\n' + 'pdftotext -layout "$p" - 2>/dev/null | head -c "$txcap"\n' + 'echo ""\n' + 'echo "@@ATT-TEXT-END"\n'

    // Pages 1..m, one pdftoppm each so nothing has to reach the filesystem.
    // It STOPS at the first page that will not render rather than skipping it:
    // "pages 1-N" has to be true, and a hole in the middle would make it a lie.
    readonly property string _pdfPagesScript: 'p="$1"; m="$2"; dpi="$3"\n' + 'i=1\n' + 'while [ "$i" -le "$m" ]; do\n' + '  b=$(pdftoppm -png -r "$dpi" -f "$i" -l "$i" -singlefile "$p" 2>/dev/null | base64 -w0)\n' + '  [ -n "$b" ] || break\n' + '  echo "@@ATT-IMG $b"\n' + '  i=$((i+1))\n' + 'done\n'

    // The embedded-picture pipeline: inventory, extract, filter, dedup, cap.
    // Every stage is argued in the header; the shell only has to be careful
    // about two things -- pairing a `-list` row to its file by the page and
    // number in the file's NAME (never by position), and cleaning up its temp
    // directory on every exit path.
    readonly property string _pdfEmbedScript: 'p="$1"; mina="$2"; minb="$3"; cap="$4"; scan="$5"\n'
        + 'd=$(mktemp -d) || exit 1\n'
        + 'trap \'rm -rf "$d"\' EXIT\n'
        + 'pdfimages -list "$p" > "$d/l" 2>/dev/null || exit 3\n'
        + 'set -- $(awk -v S="$scan" \'NR>2 && $3=="image"{n++; if(n<=S) z=$1+0} END{printf "%d %d", n+0, z+0}\' "$d/l")\n'
        + 'echo "@@ATT-META picplace ${1:-0}"\n'
        + 'if [ "${1:-0}" -lt 1 ]; then\n'
        + '  echo "@@ATT-META picscan 0"; echo "@@ATT-META picdrop 0"\n'
        + '  echo "@@ATT-META picdupes 0"; echo "@@ATT-META pictotal 0"; exit 0\n'
        + 'fi\n'
        + 'pdfimages -png -p -print-filenames -l "${2:-1}" "$p" "$d/i" > "$d/n" 2>/dev/null\n'
        + 'find "$d" -maxdepth 1 -type f -name \'i-*.png\' -printf \'%s %p\\n\' > "$d/s" 2>/dev/null\n'
        + 'awk -v NF_="$d/n" -v SF="$d/s" -v ST="$d/t" -v LF="$d/l" -v LAST="${2:-1}" -v MINA="$mina" -v MINB="$minb" \'\n'
        + 'BEGIN{ while((getline v < NF_)>0){ b=v; sub(/^.*\\//,"",b)\n'
        + '         k=split(b,q,"-"); if(k<3) continue\n'
        + '         m=q[k]; sub(/\\..*$/,"",m); F[(q[k-1]+0)":"(m+0)]=v }\n'
        + '       while((getline v < SF)>0){ i=index(v," "); if(i>0) S[substr(v,i+1)]=substr(v,1,i-1)+0 }\n'
        + '       while((getline v < LF)>0){ n=split(v,r," ")\n'
        + '         if(n>=11 && r[3]=="smask") MK[(r[11]+0)":"(r[4]+0)"x"(r[5]+0)]=1 } }\n'
        + 'NR>2 && $3=="image" && ($1+0)<=(LAST+0) {\n'
        + '  scan++\n'
        + '  f=F[($1+0)":"($2+0)]; if(f=="" || !(f in S)){ lost++; next }\n'
        + '  a=($4+0)*($5+0)\n'
        + '  if(a < MINA+0){ drop++; next }\n'
        + '  if(S[f]/a < MINB+0){ drop++\n'
        + '    if((($11+0)":"($4+0)"x"($5+0)) in MK){\n'
        + '      if(!(($11+0) in MO)){ MO[$11+0]=1; nmask++ }\n'
        + '      if(!(($1+0) in MP)){ MP[$1+0]=1; mpg = mpg (mpg==""?"":",") ($1+0) } }\n'
        + '    next }\n'
        + '  o=$11+0; if(o in O){ dupe++; next }\n'
        + '  O[o]=1\n'
        + '  printf "%d %d %d %s\\n", $1+0, $4+0, $5+0, f\n'
        + '}\n'
        + 'END{ printf "%d %d %d %d %d %s", scan+0, drop+0, dupe+0, lost+0, nmask+0, (mpg==""?"-":mpg) > ST }\n'
        + '\' "$d/l" > "$d/k"\n'
        + 'set -- $(cat "$d/t" 2>/dev/null)\n'
        + 'dupe2=0; seen=" "\n'
        + ': > "$d/k2"\n'
        + 'while read -r pg w h f; do\n'
        + '  z=$(md5sum "$f" | cut -d\' \' -f1)\n'
        + '  case "$seen" in *" $z "*) dupe2=$((dupe2+1)); continue;; esac\n'
        + '  seen="$seen$z "\n'
        + '  printf \'%s %s %s %s\\n\' "$pg" "$w" "$h" "$f" >> "$d/k2"\n'
        + 'done < "$d/k"\n'
        + 'echo "@@ATT-META picscan ${1:-0}"\n'
        + 'echo "@@ATT-META picdrop ${2:-0}"\n'
        + 'echo "@@ATT-META picdupes $((${3:-0} + dupe2))"\n'
        + 'echo "@@ATT-META picmasked ${5:-0}"\n'
        + 'echo "@@ATT-META picmaskedpages ${6:--}"\n'
        + 'echo "@@ATT-META pictotal $(grep -c . "$d/k2")"\n'
        + 'i=0\n'
        + 'while read -r pg w h f; do\n'
        + '  [ "$i" -lt "$cap" ] || break\n'
        + '  b=$(base64 -w0 "$f") || continue\n'
        + '  [ -n "$b" ] || continue\n'
        + '  echo "@@ATT-IMGP $pg $w $h $b"\n'
        + '  i=$((i+1))\n'
        + 'done < "$d/k2"\n'

    // Each frame is decoded ONCE, into a temp file: the wire's PNG is read
    // off it, and for frame 1 so is the thumbnail -- a second seek into the
    // video for a 240 px preview would cost what the frame itself cost.
    readonly property string _videoScript: 'p="$1"; cap="$2"; TP="$3"\n' + root._thumbFn + 'd=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$p" 2>/dev/null)\n' + 'case "$d" in ""|N/A) exit 3;; esac\n' + 'echo "@@ATT-META dur $d"\n' + 'f=$(mktemp) || exit 1\n' + 'trap \'rm -f "$f"\' EXIT\n' + 'i=0\n' + 'while [ "$i" -lt "$cap" ]; do\n' + '  t=$(awk -v d="$d" -v i="$i" -v n="$cap" \'BEGIN{printf "%.3f", d*(i+0.5)/n}\')\n' + '  : > "$f"\n' + '  ffmpeg -v error -y -ss "$t" -i "$p" -frames:v 1 -f image2 -update 1 -c:v png "$f" 2>/dev/null\n' + '  b=$(base64 -w0 "$f")\n' + '  if [ "$i" -eq 0 ] && [ -n "$b" ]; then\n' + '    s=$(thumb "$f")\n' + '    [ -n "$s" ] && echo "@@ATT-META thumb $s"\n' + '  fi\n' + '  [ -n "$b" ] && echo "@@ATT-IMG $b"\n' + '  i=$((i+1))\n' + 'done\n'

    readonly property string _audioScript: 'p="$1"; nb="$2"\n' + 'd=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$p" 2>/dev/null)\n' + 'case "$d" in ""|N/A) ;; *) echo "@@ATT-META dur $d";; esac\n' + 'ffmpeg -v error -i "$p" -ac 1 -ar 4000 -f u8 - 2>/dev/null | od -An -v -tu1 | awk -v n="$nb" \'{for(j=1;j<=NF;j++){v=$j-128; if(v<0)v=-v; a[c++]=v}} END{if(c<1){print "@@ATT-PEAKS"; exit} for(i=0;i<c;i++){b=int(i*n/c); if(a[i]>pk[b])pk[b]=a[i]} s=""; for(i=0;i<n;i++){s=s sprintf("%.3f ", pk[i]/128)} print "@@ATT-PEAKS " s}\'\n'

    // ---- Extract parsing ----------------------------------------------------

    function _onExtracted(code, out) {
        const att = root._job;
        switch (att.kind) {
        case "image": {
            const parsed = root._parseProtocol(out);
            if (code !== 0 || parsed.b64.length === 0) {
                root._finish({ failed: true, failReason: "could not read the file" });
                return;
            }
            root._finish({ b64: parsed.b64, thumbB64: parsed.meta.thumb || "" });
            return;
        }
        case "text": {
            if (code !== 0) {
                root._finish({ failed: true, failReason: "could not read the file" });
                return;
            }
            root._finish({ textContent: out });
            return;
        }
        case "pdf": {
            const parsed = root._parseProtocol(out);
            const pages = parseInt(parsed.meta.pages, 10) || 0;
            if (code !== 0 || pages === 0) {
                root._finish({ failed: true, failReason: "could not read the pdf" });
                return;
            }
            att.pageCount = pages;
            att.textContent = parsed.text.replace(/\n$/, "");
            // The chip's page 1, whatever the pictures do next -- the 640 px
            // PNG fallback and the small JPEG that is persisted.
            att.pageThumbB64 = parsed.meta.pagethumb || "";
            att.thumbB64 = parsed.meta.thumb || "";
            // Still pending: the pictures are the same attachment, so the host
            // sees one resolve, not a chip that flickers finished and back.
            if (att.includeImages) {
                root._startImages();
                return;
            }
            root._finish({});
            return;
        }
        case "video": {
            const parsed = root._parseProtocol(out);
            const dur = parseFloat(parsed.meta.dur);
            if (code !== 0 || !(dur > 0) || parsed.images.length === 0) {
                root._finish({ failed: true, failReason: "could not read the video" });
                return;
            }
            root._finish({ durationMs: Math.round(dur * 1000), images: parsed.images,
                           thumbB64: parsed.meta.thumb || "" });
            return;
        }
        case "audio": {
            const parsed = root._parseProtocol(out);
            const dur = parseFloat(parsed.meta.dur);
            // Always refused for sending -- Ollama drops audio silently on
            // both wires (measured) -- but the waveform still resolves so the
            // tooltip has something honest to draw.
            root._finish({ failed: true, failReason: "audio cannot reach the model yet", durationMs: (dur > 0) ? Math.round(dur * 1000) : 0, peaks: parsed.peaks });
            return;
        }
        default:
            root._finish({ failed: true, failReason: "unsupported file type" });
            return;
        }
    }

    // ---- The picture stage --------------------------------------------------

    // The four settings a file may own are read HERE, when the pass starts:
    // this attachment's own value first, the loader's property second. That
    // is what makes a coalesced burst end under the settings of the moment.
    function _startImages() {
        const att = root._job;
        root._again = false;        // this pass reads the settings of the moment
        const mode = root._opt(att, "imageMode", root.imageMode);
        att.imageMode = mode;
        if (mode === "pages") {
            const m = Math.min(att.pageCount, root._opt(att, "pageCap", root.pdfPageCap));
            root._stage = "pages";
            _proc.command = ["sh", "-c", root._pdfPagesScript, "_", att.path, String(m), String(root.pdfDpi)];
        } else {
            root._stage = "embedded";
            _proc.command = ["sh", "-c", root._pdfEmbedScript, "_", att.path,
                             String(root._opt(att, "imageMinArea", root.pdfImageMinArea)),
                             String(root.pdfImageMinBytesPerPixel),
                             String(root._opt(att, "imageCap", root.pdfImageCap)),
                             String(root.pdfImageScanCap)];
        }
        _proc.running = true;
    }

    // What one extracted picture costs the model. Gemma's vision tower is a
    // 16 px patch pooled 3x3, so a token covers 48x48 px of the picture and a
    // picture below the 768x768 encoder input costs less than a full one: the
    // area over 48^2, floored at the smallest picture's measured 50 and capped
    // at the encoder's own 256 plus its frame markers. Fitted and validated on
    // gemma4:e4b -- see the header for the numbers.
    function _picTokens(w, h) {
        return Math.max(50, Math.min(258, Math.round((w * h) / 2304)));
    }
    // A whole page always fills the encoder: 268 on the wire, whatever the dpi.
    readonly property int _pageTokens: 268

    // What was cut, in one sentence the service can put on the wire. Empty
    // when everything rode and there is nothing to explain -- a note then
    // would be noise, and a MISSING note when pictures were dropped would
    // hide the cut from the model.
    function _pagesNote(shown, total) {
        if (shown <= 0 || shown >= total)
            return "";
        return "pages 1-" + shown + " of " + total + " shown as images";
    }

    // "pages 41, 44, 51 and 54", and never a paragraph of them.
    function _joinPages(csv) {
        const all = String(csv || "").split(",").filter(t => t.length > 0 && t !== "-");
        if (all.length === 0)
            return "";
        const head = all.slice(0, 6);
        const tail = all.length - head.length;
        let s = head.length === 1 ? head[0]
              : head.slice(0, -1).join(", ") + " and " + head[head.length - 1];
        if (tail > 0)
            s = head.join(", ") + " and " + tail + " more";
        return s;
    }

    // The mask-drawn images this pdf holds that could not be extracted, named
    // by page so the omission is visible. See MASK-DRAWN IMAGES in the header
    // for why they are not composited.
    function _maskedClause(meta) {
        const n = parseInt(meta.picmasked, 10) || 0;
        if (n <= 0)
            return "";
        const list = root._joinPages(meta.picmaskedpages);
        const many = (n !== 1);
        return n + (many ? " images" : " image")
             + (list.length > 0
                ? ", on page" + (list.indexOf(" ") >= 0 || list.indexOf(",") >= 0 ? "s " : " ") + list + ","
                : "")
             + (many ? " are drawn as transparency masks" : " is drawn as a transparency mask")
             + " and could not be extracted; page mode can send "
             + (list.length > 0 ? (many ? "those pages" : "that page") : "them");
    }

    function _embeddedNote(meta, count, pages) {
        const place = parseInt(meta.picplace, 10) || 0;
        const scanned = parseInt(meta.picscan, 10) || 0;
        const total = parseInt(meta.pictotal, 10) || 0;
        const dupes = parseInt(meta.picdupes, 10) || 0;
        const masked = root._maskedClause(meta);
        if (place === 0)
            return "this pdf has no images embedded in it -- its figures are drawn as vector art, which only page mode can send";
        if (total === 0)
            return masked.length > 0
                ? masked
                : "none of the " + place + " images embedded in this pdf survived the size and detail floors";
        const parts = [];
        if (count < total)
            parts.push("the first " + count + " of " + total + " images rode, up to page "
                       + pages[pages.length - 1] + "; " + (total - count) + " later ones were left out");
        if (scanned < place)
            parts.push("only the first " + scanned + " of " + place + " image placements were examined");
        if (masked.length > 0)
            parts.push(masked);
        if (dupes > 0)
            parts.push("an image that appears on several pages rides once, at the page it first appears on");
        return parts.join("; ");
    }

    function _onPages(code, out) {
        const att = root._job;
        const parsed = (code === 0) ? root._parseProtocol(out) : { images: [] };
        // Tried, whatever came back: a toggle must never start this twice.
        att.imagesRendered = true;
        const n = parsed.images.length;
        const pages = [];
        for (let i = 1; i <= n; i++)
            pages.push(i);
        root._finish({ images: parsed.images,
                       imageCount: n,
                       imagePages: pages,
                       imageTokens: n * root._pageTokens,
                       imageDupes: 0,
                       imageNote: root._pagesNote(n, att.pageCount) });
    }

    function _onEmbedded(code, out) {
        const att = root._job;
        att.imagesRendered = true;
        if (code !== 0) {
            root._finish({ imageNote: "the images could not be read out of this pdf" });
            return;
        }
        const parsed = root._parseProtocol(out);
        const images = [];
        const pages = [];
        let tokens = 0;
        for (let i = 0; i < parsed.pics.length; i++) {
            const pic = parsed.pics[i];
            images.push(pic.b64);
            pages.push(pic.page);
            tokens += root._picTokens(pic.w, pic.h);
        }
        root._finish({ images: images,
                       imageCount: images.length,
                       imagePages: pages,
                       imageTokens: tokens,
                       imageDupes: parseInt(parsed.meta.picdupes, 10) || 0,
                       imageNote: root._embeddedNote(parsed.meta, images.length, pages) });
    }

    function _parseProtocol(out) {
        const res = { meta: {}, images: [], pics: [], peaks: [], text: "", b64: "" };
        let rest = out;
        const tb = rest.indexOf("@@ATT-TEXT-BEGIN\n");
        if (tb >= 0) {
            const te = rest.indexOf("\n@@ATT-TEXT-END", tb);
            if (te >= 0) {
                res.text = rest.substring(tb + 17, te);
                rest = rest.substring(0, tb) + rest.substring(te + 16);
            }
        }
        const lines = rest.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const ln = lines[i];
            if (ln.indexOf("@@ATT-META ") === 0) {
                const body = ln.substring(11);
                const sp = body.indexOf(" ");
                if (sp > 0)
                    res.meta[body.substring(0, sp)] = body.substring(sp + 1).trim();
            } else if (ln.indexOf("@@ATT-IMGP ") === 0) {
                // page, width, height and the base64 on ONE line, so the page
                // list and the image list are built from the same source and
                // cannot drift apart.
                const f = ln.substring(11).split(" ");
                if (f.length >= 4 && f[3].length > 0)
                    res.pics.push({ page: parseInt(f[0], 10) || 0,
                                    w: parseInt(f[1], 10) || 0,
                                    h: parseInt(f[2], 10) || 0,
                                    b64: f[3].trim() });
            } else if (ln.indexOf("@@ATT-IMG ") === 0) {
                res.images.push(ln.substring(10).trim());
            } else if (ln.indexOf("@@ATT-B64 ") === 0) {
                res.b64 = ln.substring(10).trim();
            } else if (ln.indexOf("@@ATT-PEAKS") === 0) {
                const parts = ln.substring(11).trim().split(/\s+/);
                for (let j = 0; j < parts.length; j++) {
                    const v = parseFloat(parts[j]);
                    if (!isNaN(v))
                        res.peaks.push(v);
                }
            }
        }
        return res;
    }

    // ---- The one child ------------------------------------------------------

    Process {
        id: _proc
        running: false
        stdout: StdioCollector {
            id: _out
        }
    }
    Connections {
        target: _proc
        function onExited(code) {
            if (root._job === null)
                return;
            if (root._stage === "probe")
                root._onProbed(code, _out.text);
            else if (root._stage === "pages")
                root._onPages(code, _out.text);
            else if (root._stage === "embedded")
                root._onEmbedded(code, _out.text);
            else
                root._onExtracted(code, _out.text);
        }
    }
}
