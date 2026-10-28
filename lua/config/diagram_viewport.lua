-- Reuse one uploaded PNG while the host prepares a sharp viewport.
-- Snacks owns image transfer, placeholder encoding and tmux passthrough.
local M = {}
local anchor_path = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "diagram_anchor.png")

function M.supported()
	local terminal = Snacks.image.terminal
	if not terminal.env or not terminal.env().placeholders then
		return false
	end
	local supported = false
	terminal.detect(function(info)
		local name = (info.terminal or ""):lower()
		local embedded_name, embedded_version = name:match("^(%a+)%(([^)]+)%)")
		local minimum = ({ ghostty = "1.4.0", kitty = "0.31.0" })[embedded_name or name]
		local version = vim.version.parse(embedded_version or info.version or "")
		supported = minimum ~= nil and version ~= nil and vim.version.ge(version, minimum)
	end)
	return supported
end

local function draw(presentation, force)
	local placement = presentation.preview
	local source = presentation.preview_source
	if
		not presentation.preview_active
		or presentation.closed
		or not placement
		or not source
		or not placement:ready()
		or not source:ready()
		or not vim.api.nvim_win_is_valid(presentation.win)
		or #placement:wins() == 0
	then
		return false
	end
	local crop = presentation.preview_crop
	local anchor = { crop.loc[1], crop.loc[2], width = 1, height = 1 }
	placement.img:place(placement)
	source:place(presentation.preview_owner)
	if not presentation.preview_grid then
		Snacks.image.terminal.request({ a = "p", U = 1, i = placement.img.id, p = placement.id, C = 1, c = 1, r = 1 })
	end
	if force or not vim.deep_equal(presentation.preview_grid, anchor) then
		placement:render_grid(anchor)
		presentation.preview_grid = anchor
	end
	-- Ghostty ignores source cropping on virtual placements. Use an ordinary
	-- cropped placement relative to one transparent Unicode anchor instead.
	Snacks.image.terminal.request({
		a = "p",
		i = source.id,
		p = presentation.preview_owner.id,
		P = placement.img.id,
		Q = placement.id,
		C = 1,
		x = crop.x,
		y = crop.y,
		w = crop.width,
		h = crop.height,
		c = crop.loc.width,
		r = crop.loc.height,
	})
	return true
end

function M.show(presentation, geometry, width, height)
	if not M.supported() then
		return false
	end
	local dimensions, viewport = presentation.dimensions, presentation.viewport
	local term = Snacks.image.terminal.size()
	local function axis(pixels, content, page, position, cell)
		local visible = math.min(content, page)
		local cells = math.max(1, math.ceil(visible / cell))
		local offset = math.floor(page / 2 - position * content + 0.5)
		local start = math.max(0, math.floor(-offset * pixels / content))
		local size = math.min(pixels - start, math.max(1, math.ceil(visible * pixels / content)))
		return start, size, cells, math.max(0, math.floor((page / cell - cells) / 2))
	end
	local x, w, cols, left = axis(dimensions.width, width, geometry.pixel_width, viewport.x, term.cell_width)
	local y, h, rows, top = axis(dimensions.height, height, geometry.pixel_height, viewport.y, term.cell_height)
	local loc = { top + 1, left, width = cols, height = rows }
	presentation.preview_crop = { x = x, y = y, width = w, height = h, loc = loc }
	presentation.preview_active = true
	local options = {
		inline = true,
		conceal = true,
		pos = { loc[1], loc[2] },
		range = { loc[1], loc[2], loc[1], loc[2] },
		max_width = 1,
		max_height = 1,
		auto_resize = true,
		on_update = function()
			draw(presentation, true)
		end,
	}
	if not presentation.preview then
		presentation.preview = Snacks.image.placement.new(presentation.buf, anchor_path, options)
		presentation.preview_owner = {
			update = function()
				draw(presentation)
			end,
			error = function()
				-- PNGs remain ready when Snacks cannot run its optional identify step.
				if not presentation.closed and not presentation.preview_source:ready() then
					vim.notify("Could not load diagram preview", vim.log.levels.ERROR, { title = "Diagram" })
				end
			end,
		}
		presentation.preview_source = Snacks.image.image.new(presentation.path)
		presentation.preview_source:place(presentation.preview_owner)
	else
		presentation.preview.opts = options
		presentation.preview:show()
	end
	if draw(presentation) and presentation.placement then
		presentation.placement:close()
		presentation.placement = nil
	end
	return true
end

function M.hide(presentation)
	presentation.preview_active = false
	if presentation.preview then
		Snacks.image.terminal.request({
			a = "d",
			d = "i",
			i = presentation.preview_source.id,
			p = presentation.preview_owner.id,
		})
		presentation.preview:hide()
		-- Clear the preview grid in this redraw, before Snacks' debounced update.
		presentation.preview:render_grid(presentation.preview_grid or { 1, 0, width = 1, height = 1 })
		presentation.preview_grid = nil
	end
end

function M.close(presentation)
	M.hide(presentation)
	if presentation.preview then
		presentation.preview_source:del(presentation.preview_owner.id)
		presentation.preview:close()
		presentation.preview = nil
		presentation.preview_source = nil
		presentation.preview_owner = nil
	end
end

return M
