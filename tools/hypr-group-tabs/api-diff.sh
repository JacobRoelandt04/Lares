#!/usr/bin/env bash
# What changed, between two Hyprland releases, in the code this plugin builds against, hooks, or mirrors. Read only: it fetches raw files
# from GitHub.
#   tools/hypr-group-tabs/api-diff.sh v0.57.1 v0.58.0
# Prints a diff per file ("same" when untouched; LINES_PER_FILE lines of each diff, 80 by default). A plain compile of the plugin says
# most of it; this says what changed UNDER code that still compiles (a member moved, a default changed, the hooked step drawn elsewhere).
set -u
OLD="${1:?old tag, e.g. v0.57.1}"; NEW="${2:?new tag, e.g. v0.58.0}"
# what the plugin calls, hooks or mirrors:
#   the plugin API and hooks; the decoration interface and its positioner (the tab band's box, the input routing);
#   the border pass element, its GL render step (the HOOK: CGLElementRenderer::draw) and renderBorder + the shaders whose arithmetic the
#   tab's colours mirror (clip box, gradient stops, rounding); the border decoration that fills the element; the vanilla groupbar (the
#   input it mirrors); groups; the mouse action that asks decorations for a drag; the drag controller; fullscreen; the event bus;
#   for the forced border (0.3.1): the window's rule properties and their override priorities (the set-prop slot it writes), setprop
#   (the path it copies), the group's decoration updates (when it hears a join or a leave), and the plugin unload order (PLUGIN_EXIT
#   first, then the decorations).
FILES="
src/plugins/PluginAPI.hpp
src/plugins/HookSystem.hpp
src/render/decorations/IHyprWindowDecoration.hpp
src/render/decorations/DecorationPositioner.hpp
src/render/decorations/DecorationPositioner.cpp
src/render/pass/BorderPassElement.hpp
src/render/gl/GLElementRenderer.hpp
src/render/gl/GLElementRenderer.cpp
src/render/OpenGL.hpp
src/render/Context.hpp
src/render/types.hpp
src/render/shaders/glsl/border.glsl
src/render/shaders/glsl/gradient.glsl
src/render/decorations/CHyprBorderDecoration.cpp
src/render/decorations/CHyprGroupBarDecoration.cpp
src/desktop/view/Group.hpp
src/desktop/view/Group.cpp
src/desktop/types/OverridableVar.hpp
src/desktop/rule/windowRule/WindowRuleApplicator.hpp
src/plugins/PluginSystem.cpp
src/desktop/view/window/WindowPresentation.cpp
src/config/shared/actions/ConfigActions.cpp
src/layout/supplementary/DragController.hpp
src/managers/fullscreen/FullscreenController.hpp
src/event/EventBus.hpp
"
tmp=$(mktemp -d); trap 'rm -rf "${tmp:?}"' EXIT
for f in $FILES; do
    for v in "$OLD" "$NEW"; do
        mkdir -p "$tmp/$v/$(dirname "$f")"
        curl -sfL "https://raw.githubusercontent.com/hyprwm/Hyprland/$v/$f" -o "$tmp/$v/$f" || echo "(missing at $v: $f)" > "$tmp/$v/$f"
    done
    if diff -q "$tmp/$OLD/$f" "$tmp/$NEW/$f" > /dev/null; then echo "same     $f"
    else echo "CHANGED  $f"; diff -u "$tmp/$OLD/$f" "$tmp/$NEW/$f" | sed 's/^/    /' | head -"${LINES_PER_FILE:-80}"; fi
done
# renderBorder lives in a 2700-line file: only its two definitions are compared
for v in "$OLD" "$NEW"; do
    curl -sfL "https://raw.githubusercontent.com/hyprwm/Hyprland/$v/src/render/OpenGL.cpp" 2> /dev/null \
        | awk '/^void CHyprOpenGLImpl::renderBorder\(/{p=1} p{print} p&&/^}/{p=0}' > "$tmp/renderBorder.$v"
done
if [ ! -s "$tmp/renderBorder.$OLD" ] || [ ! -s "$tmp/renderBorder.$NEW" ]; then echo "CHANGED  src/render/OpenGL.cpp renderBorder (not found at one of the tags)"
elif diff -q "$tmp/renderBorder.$OLD" "$tmp/renderBorder.$NEW" > /dev/null; then echo "same     src/render/OpenGL.cpp renderBorder"
else echo "CHANGED  src/render/OpenGL.cpp renderBorder"; diff -u "$tmp/renderBorder.$OLD" "$tmp/renderBorder.$NEW" | sed 's/^/    /' | head -"${LINES_PER_FILE:-80}"; fi
