pragma ComponentBehavior: Bound

import QtQuick

import "../../notes/data"

// =============================================================================
// LauncherFileOps.qml -- the launcher's shell queue: NotesFileOps itself, with
// the launcher's own scripts beside the notes ones.
//
// The folder mechanics are the notes module's, so they run on the notes
// module's implementation, not a copy of it: the same queue (one `sh -c` at
// a time, jobs of steps, positional arguments only, setpriv --pdeathsig), the
// same prelude (`ex`, `abslinks`, `mvu` -- verified noclobber moves with the
// Obsidian suffix, a relative link re-made absolute before it moves -- and
// `rmup`, which removes a folder an op emptied), and four of its op scripts
// as they are:
//   moveScript        ROOT SRC DESTDIR BASE EXT SRCDIR   (moveInto / moveOut)
//   renameScript      ROOT SRC DIR BASE EXT               (renameFolder)
//   unlinkScript      ROOT PATH DIR                       (a linked app out)
//   foreignLinkScript ROOT TARGET DIR BASE EXT            (an app in, a drop)
// The ones below are the launcher's own. (The queue is general enough for
// modules/common, and is not moved there.)
//
// Record formats (NUL-separated; parsed positionally by LauncherService):
//   rootScanScript ROOT
//     "X" (no root) | "R<canonical root>", then
//     per entry at depth 1-2 (hidden names pruned): "E<y>\t<Y>\t<rel>", "<link>"
//     "/x", then the rel of every executable file (or link to one)
//     "/p", then per batch: rels of the links, "", their realpaths
//     "/h", then per .desktop or executable: "<rel>", "<first bytes>"
//       (a .desktop's first 64 KiB, a script's first 20 lines; NULs dropped)
//     "/z"
//   appsScanScript DIR...   (the applications dirs, highest precedence first)
//     per dir: "#<dir>", then per batch: paths, "", realpaths,
//     "<path>\t<OnlyShowIn>\t<NotShowIn>" per file awk could read, ""
//   folderScript ROOT AMODE ASRC ABASE AEXT BMODE BSRC BBASE BEXT
//     a new "Folder" (+ " N") in ROOT; A then B put into it: MODE "link"
//     is a noclobber `ln -s SRC`, "move" is mvu. "G<folder>", "T<name>",
//     "D<name>" | "E<why>"
//   foreignProbeScript PATH
//     "P<realpath>" then "F" (a regular file) and "X" (executable) | "E<why>"
//   dropProbeScript MAX PATH...      (a drop of several files and/or directories)
//     per PATH: "A", then "P<realpath>" and "F" (a regular file) / "X" (executable) | "E<why>"; a DIRECTORY
//     is "A", "P<realpath>", "D", then per hidden-name-free regular file in it that is executable or a
//     .desktop (symlinks followed, one level, sorted, at most MAX + 1 so the caller can tell "more than
//     MAX"): "C", "S<its path>", "P<realpath>", "F", "X"? -- then "/" ends the PATH
//   dropGroupScript ROOT NAME TARGET BASE EXT [TARGET BASE EXT]...
//     a new folder NAME (+ " N") in ROOT with an absolute link to every TARGET (a clash takes the next
//     suffix): "G<folder>", then "N<name>" per link in order | "E<why>" (the links made and the folder
//     go again: nothing is left half done)
//   removeFolderScript ROOT DIR [MODE NAME BASE EXT]...
//     every entry of DIR back into ROOT, then DIR removed: MODE "move" is
//     mvu (a clash takes a suffix, a link stays a link), "unlink" removes an
//     app's link (only ever a link). All or nothing: a directory in DIR's
//     tree that find cannot list or enter refuses it before anything moves
//     ("Eunreadable", stderr silent); DIR must hold exactly the NAMEs
//     (hidden names counted), else nothing moves ("Echanged"); a
//     step that fails and an rmdir that fails (something arrived meanwhile)
//     put every entry back where it was ("Emove" / "Eunlink" /
//     "Enotempty"; "Erollback" when putting one back failed too) -- a link
//     re-made from the text it had, and every relative link under a
//     directory given its own text back, since mvu re-makes a relative link
//     absolute to move it (and abslinks every one under a directory before
//     the directory moves); one that still reads as it did (abslinks could
//     not change it) is left alone. On success a relative link whose target
//     was in the tree gets its text back too (it reaches the same thing from
//     the root), or points at where its target went when a suffix at the top
//     means the text would not; an absolute link into the tree points at
//     where its target went; one pointing out stays absolute. Per entry, in
//     argument order: "M<name>", "<name it took in ROOT>" | "U<name>"; then
//     "R<DIR under ROOT>".
// =============================================================================
NotesFileOps {
    id: lops

    readonly property string rootScanScript: [
        'ROOT=$1',
        'if [ ! -d "$ROOT" ]; then printf "X\\0"; exit 0; fi',
        '_c=$(realpath -e -- "$ROOT" 2>/dev/null) || _c=$ROOT',
        'printf "R%s\\0" "$_c"',
        'find -H "$ROOT" -mindepth 1 -maxdepth 2 \\( -name ".*" -prune \\) -o -printf "E%y\\t%Y\\t%P\\0%l\\0"',
        'printf "/x\\0"',
        'find -H "$ROOT" -mindepth 1 -maxdepth 2 \\( -name ".*" -prune \\) -o \\( -xtype f -executable -printf "%P\\0" \\)',
        'printf "/p\\0"',
        'find -H "$ROOT" -mindepth 1 -maxdepth 2 \\( -name ".*" -prune \\) -o \\( -type l -print0 \\) | xargs -0 -r sh -c \'for f; do printf "%s\\0" "${f#"$0"/}"; done; printf "\\0"; realpath -m -z -- "$@"\' "$ROOT"',
        'printf "/h\\0"',
        'find -H "$ROOT" -mindepth 1 -maxdepth 2 \\( -name ".*" -prune \\) -o \\( -xtype f \\( -name "*.desktop" -o -executable \\) -print0 \\) | xargs -0 -r sh -c \'for f; do printf "%s\\0" "${f#"$0"/}"; case $f in *.desktop) head -c 65536 -- "$f" ;; *) head -c 4096 -- "$f" | head -n 20 ;; esac 2>/dev/null | tr -d "\\000"; printf "\\0"; done\' "$ROOT"',
        'printf "/z\\0"',
        'exit 0'
    ].join("\n")

    // gawk: BEGINFILE/ENDFILE give every readable file exactly one record,
    // an empty file included; one it cannot open is skipped (no record: no
    // restriction), never a reason for the batch to fail.
    readonly property string appsScanScript: [
        'AWKP=\'BEGINFILE { g = ""; o = ""; n = ""; if (ERRNO != "") nextfile }',
        '{ sub(/\\r$/, "") }',
        '/^[ \\t]*\\[/ { g = $0; gsub(/^[ \\t]+|[ \\t]+$/, "", g); next }',
        'g == "[Desktop Entry]" && /^OnlyShowIn[ \\t]*=/ { v = $0; sub(/^[^=]*=[ \\t]*/, "", v); o = v }',
        'g == "[Desktop Entry]" && /^NotShowIn[ \\t]*=/ { v = $0; sub(/^[^=]*=[ \\t]*/, "", v); n = v }',
        'ENDFILE { printf "%s\\t%s\\t%s%c", FILENAME, o, n, 0 }\'',
        'export AWKP',
        'for d in "$@"; do',
        '    [ -d "$d" ] || continue',
        '    printf "#%s\\0" "$d"',
        '    find -L "$d" -name "*.desktop" -type f -print0 2>/dev/null | xargs -0 -r sh -c \'for f; do printf "%s\\0" "$f"; done; printf "\\0"; realpath -m -z -- "$@"; awk "$AWKP" "$@" 2>/dev/null; printf "\\0"\' sh',
        'done',
        'exit 0'
    ].join("\n")

    readonly property string folderScript: [
        'ROOT=$1',
        'mkdir -p -- "$ROOT" || { printf "Emkdir\\0"; exit 1; }',
        '_g=0',
        'while :; do',
        '    if [ "$_g" -eq 0 ]; then G=Folder; else G="Folder $_g"; fi',
        '    mkdir -- "$ROOT/$G" 2>/dev/null && break',
        '    ex "$ROOT/$G" || { printf "Emkdir\\0"; exit 1; }',
        '    _g=$((_g + 1))',
        '    [ "$_g" -lt 10000 ] || { printf "Efull\\0"; exit 1; }',
        'done',
        'printf "G%s\\0" "$G"',
        'put() {',
        '    if [ "$1" = link ]; then',
        '        _n=0',
        '        while [ "$_n" -lt 10000 ]; do',
        '            if [ "$_n" -eq 0 ]; then NM=$3$4; else NM="$3 $_n$4"; fi',
        '            ln -s -- "$2" "$ROOT/$G/$NM" 2>/dev/null && return 0',
        '            ex "$ROOT/$G/$NM" || return 4',
        '            _n=$((_n + 1))',
        '        done',
        '        return 3',
        '    fi',
        '    mvu "$2" "$ROOT/$G" "$3" "$4"',
        '}',
        'put "$2" "$3" "$4" "$5" || { rmdir -- "$ROOT/$G"; printf "Emove\\0"; exit 1; }',
        'printf "T%s\\0" "$NM"',
        'put "$6" "$7" "$8" "$9" || { printf "Emove\\0"; exit 1; }',
        'printf "D%s\\0" "$NM"'
    ].join("\n")

    // Arrays are not POSIX: the entries stay in "$@" and `each` walks them
    // four at a time (a function's own "$@" is its arguments, so the list
    // survives every walk), keeping what each step did in M_<i> / L_<i> /
    // D_<i> through eval of a value that is only ever a variable NAME. L_<i>
    // is a link's text as readlink gave it, before anything moved: an app's
    // link is unlinked, and a moved link comes back as a new link with that
    // text -- mvu re-made a relative one absolute, and moving THAT back
    // would leave F/rel.sh -> /root/a.sh where it read -> ../a.sh. A
    // DIRECTORY has the same fault one level down: mvu abslinks it before it
    // moves, so every relative link under it (a -> ../b at any depth) is
    // listed first, path and text NUL-separated in a file of $_kd (K_<i>: the
    // list exists), and given its text back when the directory is back in DIR
    // -- or still there, because mvu failed after abslinks already ran (a
    // directory that cannot be renamed: EACCES on its `..`). The
    // same absolute text is wrong on SUCCESS for a link into the tree
    // (F/Nested/a -> ../b.sh, F/b.sh moving too): it names F, which the
    // rmdir takes away, so those are recorded up front and fixed at the end.
    readonly property string removeFolderScript: [
        'ROOT=$1; DIR=$2; shift 2',
        '{ [ -d "$DIR" ] && [ ! -L "$DIR" ]; } || { printf "Emissing\\0"; exit 1; }',
        'each() {',
        '    _f=$1; shift; _i=0',
        '    while [ $# -ge 4 ]; do',
        '        _i=$((_i + 1))',
        '        "$_f" "$_i" "$1" "$2" "$3" "$4" || return 1',
        '        shift 4',
        '    done',
        '}',
        'has() { ex "$DIR/$3"; }',
        // A command substitution strips trailing newlines: readlink's own
        // newline is kept behind a sentinel and taken off with it, so the
        // text is exact.
        'lt() { _l=$(readlink -- "$1" && printf x) && _l=${_l%?x}; }',
        // $_kd, made on first use: keep's lists, the links into the tree.
        '_kd=',
        'kd() {',
        '    [ -n "$_kd" ] && return 0',
        '    _kd=$(mktemp -d) || return 1',
        '    trap \'rm -rf -- "$_kd"\' EXIT',
        '}',
        // -lname "/*" is abslinks' own test (its `*` matches a slash): the
        // links it leaves alone are not listed.
        'keep() {',
        '    kd || return 1',
        '    find "$2" -type l ! -lname "/*" -printf "%P\\0%l\\0" > "$_kd/$1" || return 1',
        '    eval "K_$1=1"',
        '}',
        // Only onto what is still a link: anything else there now is not
        // ours to replace (-f), and the rollback says it failed. A link that
        // still reads as recorded is left alone: abslinks could not re-make
        // it (its directory has no write permission: EACCES), so
        // it never changed, and ln -sfn onto it fails the same way -- a
        // rollback reported failed, and ln's complaint on stderr, over a tree
        // that is as it was.
        'relink() {',
        '    eval "_k=\\${K_$1:-}"',
        '    { [ -n "$_k" ] && [ -d "$2" ] && [ ! -L "$2" ]; } || return 0',
        '    xargs -0 -r -n 2 sh -c \'[ -L "$0/$1" ] || exit 1; x=$(readlink -- "$0/$1" && printf x) && [ "${x%?x}" = "$2" ] && exit 0; ln -sfn -- "$2" "$0/$1" 2>/dev/null\' "$2" < "$_kd/$1" || _bad=1',
        '}',
        // A directory find cannot list or cannot enter, anywhere in the tree
        // (DIR's own included), would fail the count, keep and abslinks
        // half-way, with find's complaint on stderr: refused before anything
        // moves. -prune keeps find out of it, so the test itself is silent.
        '_u=$(find "$DIR" -type d \\( ! -readable -o ! -executable \\) -prune -printf x -quit 2>/dev/null) && [ -z "$_u" ] || { printf "Eunreadable\\0"; exit 1; }',
        '_have=$(find "$DIR" -mindepth 1 -maxdepth 1 -printf x | wc -c)',
        '{ [ "$_have" -eq $(($# / 4)) ] && each has "$@"; } || { printf "Echanged\\0"; exit 1; }',
        // Every link in the tree whose target is IN it (DIR itself, or
        // something under it that exists), read before anything moves: its
        // path, its text and its target, relative to DIR ("=" alone is DIR).
        // A relative one is made absolute by abslinks and mvu to where that
        // target WAS, and an absolute one (F/abs -> /root/F/b.sh) names that
        // place already: either way gone with DIR. On success _fix gives it
        // its text back where that reaches the target from the link's new
        // place (a relative text does, DIR being ROOT now), and otherwise
        // points it at where the target went: an absolute text, or one whose
        // target or directory on the way took a suffix at the top (the text
        // would reach the root's own entry of that name). A link out of the
        // tree keeps abslinks' absolute text, and so does a dangling one:
        // read from the root, its text could reach something unrelated.
        'if [ -n "$(find "$DIR" -mindepth 1 -type l -printf x -quit)" ]; then',
        '    _cd=$(realpath -e -- "$DIR" && printf x) && _cd=${_cd%?x} && kd || { printf "Emove\\0"; exit 1; }',
        '    find "$DIR" -mindepth 1 -type l -exec sh -c \'c=$0; d=$1; shift; for l; do t=$(realpath -e -- "$l" 2>/dev/null && printf x) || continue; t=${t%?x}; case $t in "$c"|"$c"/*) x=$(readlink -- "$l" && printf x) && printf "%s\\0%s\\0=%s\\0" "${l#"$d"/}" "${x%?x}" "${t#"$c"}" ;; esac; done\' "$_cd" "$DIR" {} + > "$_kd/in" || { printf "Emove\\0"; exit 1; }',
        'fi',
        'put() {',
        '    _l=',
        '    if [ "$2" = unlink ]; then',
        '        [ -L "$DIR/$3" ] || { _why=unlink; return 1; }',
        '        lt "$DIR/$3" && rm -- "$DIR/$3" || { _why=unlink; return 1; }',
        '    else',
        '        if [ -L "$DIR/$3" ]; then lt "$DIR/$3" || { _why=move; return 1; }; fi',
        '        if [ -d "$DIR/$3" ] && [ ! -L "$DIR/$3" ]; then keep "$1" "$DIR/$3" || { _why=move; return 1; }; fi',
        '        mvu "$DIR/$3" "$ROOT" "$4" "$5" || { _why=move; return 1; }',
        '        eval "M_$1=\\$NM"',
        '    fi',
        '    eval "L_$1=\\$_l; D_$1=1"',
        '}',
        'back() {',
        '    eval "_did=\\${D_$1:-}"',
        '    if [ -z "$_did" ]; then relink "$1" "$DIR/$3"; return 0; fi',
        '    eval "_l=\\$L_$1"',
        '    if [ "$2" = unlink ]; then',
        '        ln -s -- "$_l" "$DIR/$3" 2>/dev/null || _bad=1',
        '        return 0',
        '    fi',
        '    eval "_m=\\$M_$1"',
        // The link mvu left at the top goes only once the old one is back
        // (noclobber), and only if it is still a link.
        '    if [ -n "$_l" ]; then',
        '        { [ -L "$ROOT/$_m" ] && ln -s -- "$_l" "$DIR/$3" 2>/dev/null && rm -f -- "$ROOT/$_m"; } || _bad=1',
        '    else',
        '        mv -n -T -- "$ROOT/$_m" "$DIR/$3" 2>/dev/null',
        '        if ! ex "$ROOT/$_m" && ex "$DIR/$3"; then relink "$1" "$DIR/$3"; else _bad=1; fi',
        '    fi',
        '    return 0',
        '}',
        'undo() {',
        '    _bad=; each back "$@"',
        '    if [ -n "$_bad" ]; then printf "Erollback\\0"; else printf "E%s\\0" "$_why"; fi',
        '    exit 1',
        '}',
        '_why=move',
        'each put "$@" || undo "$@"',
        'rmdir -- "$DIR" 2>/dev/null || { _why=notempty; undo "$@"; }',
        // The name each moved entry took in ROOT, a file per entry (a name
        // is never a path), for _fix, which runs once per recorded link:
        // ROOT MAPS PATH TEXT =TARGET. Only onto what is still a link.
        'mapped() {',
        '    [ "$2" = unlink ] && return 0',
        '    eval "_m=\\$M_$1"',
        '    printf "%s" "$_m" > "$_kd/m/$3"',
        '}',
        '_fix=\'r=$0; m=$1; p=$2; tx=$3; t=${4#=}',
        'nm() { [ -f "$m/$1" ] && n=$(cat -- "$m/$1" && printf x) && n=${n%x}; }',
        'rp() { v=$(realpath -e -- "$1" 2>/dev/null && printf x) && v=${v%?x}; }',
        'h=${p%%/*}; nm "$h" || exit 0; L=$r/$n${p#"$h"}',
        '[ -L "$L" ] || exit 0',
        'if [ -z "$t" ]; then W=$r; else h=${t#/}; h=${h%%/*}; nm "$h" || exit 0; W=$r/$n${t#/"$h"}; fi',
        'rp "$W" || exit 0; w=$v',
        'ln -sfn -- "$tx" "$L" 2>/dev/null && rp "$L" && [ "$v" = "$w" ] && exit 0',
        'ln -sfn -- "$w" "$L" 2>/dev/null; exit 0\'',
        'if [ -n "$_kd" ] && [ -s "$_kd/in" ] && mkdir -- "$_kd/m" && each mapped "$@"; then',
        '    xargs -0 -r -n 3 sh -c "$_fix" "$ROOT" "$_kd/m" < "$_kd/in"',
        'fi',
        'say() {',
        '    if [ "$2" = unlink ]; then printf "U%s\\0" "$3"; return 0; fi',
        '    eval "_m=\\$M_$1"',
        '    printf "M%s\\0%s\\0" "$3" "$_m"',
        '}',
        'each say "$@"',
        'printf "R%s\\0" "${DIR#"$ROOT"/}"',
        'exit 0'
    ].join("\n")

    readonly property string dropProbeScript: [
        'MAX=$1; shift',
        'probe() {',
        '    _r=$(realpath -e -- "$1") || { printf "Emissing\\0"; return 1; }',
        '    printf "P%s\\0" "$_r"',
        '    [ -f "$_r" ] && printf "F\\0"',
        '    [ -x "$_r" ] && printf "X\\0"',
        '    return 0',
        '}',
        'for a; do',
        '    printf "A\\0"',
        '    if [ -d "$a" ]; then',
        '        _d=$(realpath -e -- "$a") || { printf "Emissing\\0/\\0"; continue; }',
        '        printf "P%s\\0D\\0" "$_d"',
        '        find -L "$_d" -mindepth 1 -maxdepth 1 ! -name ".*" -type f \\( -executable -o -name "*.desktop" \\) -print0 2>/dev/null | sort -z | head -z -n "$((MAX + 1))" | xargs -0 -r sh -c \'for f; do printf "C\\0S%s\\0" "$f"; _r=$(realpath -e -- "$f") || { printf "Emissing\\0"; continue; }; printf "P%s\\0" "$_r"; [ -f "$_r" ] && printf "F\\0"; [ -x "$_r" ] && printf "X\\0"; done\' sh',
        '    else',
        '        probe "$a"',
        '    fi',
        '    printf "/\\0"',
        'done',
        'exit 0'
    ].join("\n")

    readonly property string dropGroupScript: [
        'ROOT=$1; NAME=$2; shift 2',
        'mkdir -p -- "$ROOT" || { printf "Emkdir\\0"; exit 1; }',
        '_g=0',
        'while :; do',
        '    if [ "$_g" -eq 0 ]; then G=$NAME; else G="$NAME $_g"; fi',
        '    mkdir -- "$ROOT/$G" 2>/dev/null && break',
        '    ex "$ROOT/$G" || { printf "Emkdir\\0"; exit 1; }',
        '    _g=$((_g + 1))',
        '    [ "$_g" -lt 10000 ] || { printf "Efull\\0"; exit 1; }',
        'done',
        'printf "G%s\\0" "$G"',
        'while [ $# -ge 3 ]; do',
        '    _t=$1; _b=$2; _e=$3; shift 3; _n=0; _made=',
        '    while [ "$_n" -lt 10000 ]; do',
        '        if [ "$_n" -eq 0 ]; then NM=$_b$_e; else NM="$_b $_n$_e"; fi',
        '        if ln -s -- "$_t" "$ROOT/$G/$NM" 2>/dev/null; then printf "N%s\\0" "$NM"; _made=1; break; fi',
        '        ex "$ROOT/$G/$NM" || break',
        '        _n=$((_n + 1))',
        '    done',
        '    if [ -z "$_made" ]; then',
        '        find "$ROOT/$G" -mindepth 1 -maxdepth 1 -type l -delete 2>/dev/null',
        '        rmdir -- "$ROOT/$G" 2>/dev/null',
        '        printf "Eln\\0"; exit 1',
        '    fi',
        'done',
        'exit 0'
    ].join("\n")

    readonly property string foreignProbeScript: [
        '_r=$(realpath -e -- "$1") || { printf "Emissing\\0"; exit 1; }',
        'printf "P%s\\0" "$_r"',
        '[ -f "$_r" ] && printf "F\\0"',
        '[ -x "$_r" ] && printf "X\\0"',
        'exit 0'
    ].join("\n")
}
