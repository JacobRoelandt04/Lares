--- @since 26.8.15
-- wallpapers.yazi -- a mark in the linemode column beside every picture of the CURRENT theme and mode's wallpaper list
-- (shell.jsonc theme.wallpapers.<theme>.<mode>), as themectl publishes it in ~/.local/state/theme/wallpapers-active.txt (one
-- absolute path a line; `#` lines are comments). Installed and switched on by `themectl install`. What it is, how to check it after
-- a yazi update and how to rebuild it by hand: tools/theme/yazi/CHEATSHEET.md in the quickshell repo.
--
-- It uses three things of yazi's plugin API (yazi 26.9.1) and nothing else:
--   Linemode:children_add(fn, order)         a column of the linemode, right-aligned (git.yazi's sign is one too)
--   self._file.url, self._file.is_hovered    the row's file
--   ui.Line, ui.Span, ui.Style               the mark's text
-- plus plain Lua (io.open, os.time, os.getenv). A yazi update that changes one of them takes the mark away and nothing else:
-- init.lua calls setup() inside pcall, and the column's function catches its own errors.

local function list_file()
	local base = os.getenv("XDG_STATE_HOME")
	if not base or base == "" then
		base = (os.getenv("HOME") or "") .. "/.local/state"
	end
	return base .. "/theme/wallpapers-active.txt"
end

local LIST = list_file()
local listed, read_at = {}, nil

-- The list, read again at most once a second: the column is drawn for every row on screen at every redraw, and a sync context
-- cannot stat a file, so the clock stands in for the file's mtime. A missing file is an empty list.
local function refresh()
	local now = os.time()
	if now == read_at then
		return
	end
	read_at = now
	local set = {}
	local f = io.open(LIST, "r")
	if f then
		for line in f:lines() do
			if line ~= "" and line:sub(1, 1) ~= "#" then
				set[line] = true
			end
		end
		f:close()
	end
	listed = set
end

-- require("wallpapers"):setup { sign = "...", color = "blue", order = 1600 }   (every key optional)
local function setup(_, opts)
	opts = opts or {}
	local sign = opts.sign or "\u{F0E09}"
	local style = ui.Style():fg(opts.color or "blue")
	Linemode:children_add(function(self)
		local ok, out = pcall(function()
			refresh()
			if not listed[tostring(self._file.url)] then
				return ""
			end
			if self._file.is_hovered then
				return ui.Line { " ", sign }
			end
			return ui.Line { " ", ui.Span(sign):style(style) }
		end)
		return ok and out or ""
	end, opts.order or 1600)
end

return { setup = setup }
