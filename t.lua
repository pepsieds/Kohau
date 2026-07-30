--[[
	Console.lua — 1:1 Studio Output clone + expandable tables/stack traces

	Usage:
		local Dock = loadstring(game:HttpGet("...sspdo.luau"))()
		local Console = loadstring(game:HttpGet("...Console.lua"))()

		local Window = Dock.new("Console", 600, 400)
		Window:Show()

		local console = Console.new()
		Window:Add(console.Frame)

		-- normal print/warn/error from ANY script are captured automatically
		print("hello")
		warn("careful")
		error("boom")

		-- rich table inspection (expandable tree) — use these instead of print(tbl)
		console:Log("player data", { Name = "Daddy", Coins = 500, Inventory = {"Sword","Shield"} })
		console:LogTable("PlayerData", workspace)

	Notes:
		- Global print/warn of a table still shows "table: 0x..." (Luau can't be
		  patched globally). Use console:Log(...) / console:LogTable(...) when you
		  want the tree view.
		- console:Destroy() disconnects all listeners.
]]

local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local RunService = game:GetService("RunService")

local Console = {}
Console.__index = Console

--============================================================
-- THEME
--============================================================

local THEME = {
	Background  = Color3.fromRGB(30, 30, 30),
	Bar         = Color3.fromRGB(40, 40, 40),
	BarAlt      = Color3.fromRGB(45, 45, 45),
	EntryA      = Color3.fromRGB(36, 36, 36),
	EntryB      = Color3.fromRGB(32, 32, 32),
	Border      = Color3.fromRGB(52, 52, 52),
	Text        = Color3.fromRGB(225, 225, 225),
	Output      = Color3.fromRGB(225, 225, 225),
	Info        = Color3.fromRGB(96, 170, 255),
	Warning     = Color3.fromRGB(255, 196, 60),
	Error       = Color3.fromRGB(255, 96, 96),
	Muted       = Color3.fromRGB(140, 140, 140),
	Accent      = Color3.fromRGB(74, 144, 255),
	Key         = Color3.fromRGB(150, 200, 255),
	StrVal      = Color3.fromRGB(180, 230, 150),
	NumVal      = Color3.fromRGB(255, 180, 120),
	OtherVal    = Color3.fromRGB(200, 200, 200),
}

local TYPE_ORDER = { "Output", "Info", "Warning", "Error" }
local TYPE_COLOR = { Output = THEME.Output, Info = THEME.Info, Warning = THEME.Warning, Error = THEME.Error }
local TYPE_ICON  = { Output = ">", Info = "i", Warning = "!", Error = "X" }

local MSGTYPE_MAP = {
	[Enum.MessageType.MessageOutput]  = "Output",
	[Enum.MessageType.MessageInfo]    = "Info",
	[Enum.MessageType.MessageWarning] = "Warning",
	[Enum.MessageType.MessageError]   = "Error",
}

--============================================================
-- UTIL
--============================================================

local function formatTime(unixTime)
	local ok, str = pcall(function()
		return os.date("%H:%M:%S", unixTime or os.time())
	end)
	return ok and str or "--:--:--"
end

local function truncate(s, n)
	if #s <= n then return s end
	return s:sub(1, n) .. "..."
end

local function countKeys(t)
	local n = 0
	for _ in pairs(t) do n += 1 end
	return n
end

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 4)
	c.Parent = inst
	return c
end

local function stroke(inst, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or THEME.Border
	s.Thickness = thickness or 1
	s.Parent = inst
	return s
end

local function makeLabel(props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = props.Font or Enum.Font.Code
	l.TextSize = props.TextSize or 14
	l.TextColor3 = props.TextColor3 or THEME.Text
	l.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	l.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Top
	l.TextWrapped = props.TextWrapped ~= false
	l.Text = props.Text or ""
	l.Size = props.Size or UDim2.new(1, 0, 0, 20)
	l.AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.Y
	l.Position = props.Position or UDim2.new(0, 0, 0, 0)
	l.LayoutOrder = props.LayoutOrder or 0
	l.RichText = props.RichText or false
	l.ZIndex = props.ZIndex or 1
	l.Parent = props.Parent
	return l
end

--============================================================
-- VALUE / TABLE TREE RENDERING
--============================================================

local function valueColor(v)
	local t = typeof(v)
	if t == "string" then return THEME.StrVal end
	if t == "number" or t == "boolean" then return THEME.NumVal end
	return THEME.OtherVal
end

local function valueToText(v)
	local t = typeof(v)
	if t == "string" then return string.format("%q", v) end
	if t == "table" then return string.format("table (%d)", countKeys(v)) end
	return tostring(v)
end

-- builds a recursive, expandable tree for a table value into `parent`
local function buildTableTree(parent, tbl, depth, seen, layoutOrderRef)
	seen = seen or {}
	depth = depth or 0
	layoutOrderRef = layoutOrderRef or { n = 0 }

	if seen[tbl] then
		layoutOrderRef.n += 1
		makeLabel({
			Parent = parent, Text = "[cyclic reference]", TextColor3 = THEME.Muted,
			TextSize = 13, LayoutOrder = layoutOrderRef.n,
		})
		return
	end
	seen[tbl] = true

	-- stable-ish ordering: array part first, then keys
	local keys = {}
	for k in pairs(tbl) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ta, tb = typeof(a), typeof(b)
		if ta ~= tb then return ta < tb end
		local ok, res = pcall(function() return a < b end)
		return ok and res or tostring(a) < tostring(b)
	end)

	for _, k in ipairs(keys) do
		local v = tbl[k]
		layoutOrderRef.n += 1
		local order = layoutOrderRef.n

		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -depth * 14, 0, 0)
		row.Position = UDim2.new(0, depth * 14, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.LayoutOrder = order
		row.Parent = parent

		local isTable = typeof(v) == "table"

		local header = Instance.new("TextButton")
		header.BackgroundTransparency = 1
		header.AutoButtonColor = false
		header.Size = UDim2.new(1, 0, 0, 18)
		header.Text = ""
		header.Parent = row

		local arrow = makeLabel({
			Parent = header, Text = isTable and "v" or " ", TextColor3 = THEME.Muted,
			Size = UDim2.new(0, 14, 0, 18), TextSize = 12, AutomaticSize = Enum.AutomaticSize.None,
			Font = Enum.Font.Code,
		})

		local line = makeLabel({
			Parent = header,
			Position = UDim2.new(0, 14, 0, 0),
			Size = UDim2.new(1, -14, 0, 18),
			AutomaticSize = Enum.AutomaticSize.None,
			TextSize = 13,
			Font = Enum.Font.Code,
			RichText = true,
			Text = string.format(
				'<font color="#%s">%s</font> = <font color="#%s">%s</font>',
				THEME.Key:ToHex(), tostring(k),
				valueColor(v):ToHex(), valueToText(v)
			),
		})

		if isTable then
			local child = Instance.new("Frame")
			child.BackgroundTransparency = 1
			child.Size = UDim2.new(1, 0, 0, 0)
			child.AutomaticSize = Enum.AutomaticSize.Y
			child.Visible = false
			child.LayoutOrder = 2
			child.Parent = row

			local childLayout = Instance.new("UIListLayout")
			childLayout.SortOrder = Enum.SortOrder.LayoutOrder
			childLayout.Parent = child

			local built = false
			header.MouseButton1Click:Connect(function()
				child.Visible = not child.Visible
				arrow.Text = child.Visible and "v" or ">"
				if child.Visible and not built then
					built = true
					buildTableTree(child, v, depth + 1, seen, layoutOrderRef)
				end
			end)
		end
	end

	if #keys == 0 then
		layoutOrderRef.n += 1
		makeLabel({
			Parent = parent, Text = "-- empty --", TextColor3 = THEME.Muted,
			TextSize = 13, LayoutOrder = layoutOrderRef.n,
		})
	end
end

--============================================================
-- CONSTRUCTOR
--============================================================

function Console.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Console)

	self._maxEntries = opts.MaxEntries or 1000
	self._entries = {}       -- ordered list of entry records
	self._layoutOrder = 0
	self._autoScroll = true
	self._filters = { Output = true, Info = true, Warning = true, Error = true }
	self._search = ""
	self._counts = { Output = 0, Info = 0, Warning = 0, Error = 0 }
	self._conns = {}
	self._pendingErrors = {} -- message -> {trace, script, time}

	self:_buildUI()
	self:_hookLogs()

	return self
end

--============================================================
-- UI BUILD
--============================================================

function Console:_buildUI()
	local Frame = Instance.new("Frame")
	Frame.Name = "ConsoleRoot"
	Frame.BackgroundColor3 = THEME.Background
	Frame.Size = UDim2.new(1, 0, 1, 0)
	Frame.ClipsDescendants = true
	self.Frame = Frame

	-- ===== Top bar =====
	local TopBar = Instance.new("Frame")
	TopBar.Name = "TopBar"
	TopBar.BackgroundColor3 = THEME.Bar
	TopBar.Size = UDim2.new(1, 0, 0, 34)
	TopBar.Parent = Frame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = TopBar

	local topLayout = Instance.new("UIListLayout")
	topLayout.FillDirection = Enum.FillDirection.Horizontal
	topLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	topLayout.Padding = UDim.new(0, 6)
	topLayout.Parent = TopBar

	-- search box
	local Search = Instance.new("TextBox")
	Search.Name = "Search"
	Search.PlaceholderText = "Search..."
	Search.Text = ""
	Search.ClearTextOnFocus = false
	Search.BackgroundColor3 = THEME.BarAlt
	Search.TextColor3 = THEME.Text
	Search.PlaceholderColor3 = THEME.Muted
	Search.Font = Enum.Font.Code
	Search.TextSize = 13
	Search.Size = UDim2.new(0, 160, 1, 0)
	Search.ClipsDescendants = true
	corner(Search, 4)
	local sp = Instance.new("UIPadding")
	sp.PaddingLeft = UDim.new(0, 6)
	sp.Parent = Search
	Search.Parent = TopBar

	table.insert(self._conns, Search:GetPropertyChangedSignal("Text"):Connect(function()
		self._search = Search.Text:lower()
		self:_refreshFilters()
	end))

	-- filter toggle buttons
	self._filterButtons = {}
	for _, t in ipairs(TYPE_ORDER) do
		local btn = Instance.new("TextButton")
		btn.Name = "Filter_" .. t
		btn.AutoButtonColor = false
		btn.BackgroundColor3 = THEME.BarAlt
		btn.Size = UDim2.new(0, 64, 1, 0)
		btn.Font = Enum.Font.Code
		btn.TextSize = 13
		btn.TextColor3 = TYPE_COLOR[t]
		btn.Text = TYPE_ICON[t] .. " 0"
		corner(btn, 4)
		btn.Parent = TopBar

		btn.MouseButton1Click:Connect(function()
			self._filters[t] = not self._filters[t]
			btn.BackgroundTransparency = self._filters[t] and 0 or 0.6
			btn.TextTransparency = self._filters[t] and 0 or 0.5
			self:_refreshFilters()
		end)

		self._filterButtons[t] = btn
	end

	-- spacer
	local spacer = Instance.new("Frame")
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, -400, 1, 0)
	spacer.LayoutOrder = 10
	spacer.Parent = TopBar

	-- copy button
	local CopyBtn = Instance.new("TextButton")
	CopyBtn.AutoButtonColor = false
	CopyBtn.BackgroundColor3 = THEME.BarAlt
	CopyBtn.Size = UDim2.new(0, 60, 1, 0)
	CopyBtn.Font = Enum.Font.Code
	CopyBtn.TextSize = 13
	CopyBtn.TextColor3 = THEME.Text
	CopyBtn.Text = "Copy"
	CopyBtn.LayoutOrder = 11
	corner(CopyBtn, 4)
	CopyBtn.Parent = TopBar
	CopyBtn.MouseButton1Click:Connect(function() self:_copyAll() end)

	-- clear button
	local ClearBtn = Instance.new("TextButton")
	ClearBtn.AutoButtonColor = false
	ClearBtn.BackgroundColor3 = THEME.BarAlt
	ClearBtn.Size = UDim2.new(0, 60, 1, 0)
	ClearBtn.Font = Enum.Font.Code
	ClearBtn.TextSize = 13
	ClearBtn.TextColor3 = THEME.Error
	ClearBtn.Text = "Clear"
	ClearBtn.LayoutOrder = 12
	corner(ClearBtn, 4)
	ClearBtn.Parent = TopBar
	ClearBtn.MouseButton1Click:Connect(function() self:Clear() end)

	-- ===== Body scroller =====
	local Scroller = Instance.new("ScrollingFrame")
	Scroller.Name = "Body"
	Scroller.BackgroundColor3 = THEME.Background
	Scroller.BorderSizePixel = 0
	Scroller.Position = UDim2.new(0, 0, 0, 34)
	Scroller.Size = UDim2.new(1, 0, 1, -34 - 22)
	Scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
	Scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Scroller.ScrollBarThickness = 6
	Scroller.ScrollBarImageColor3 = THEME.Accent
	Scroller.Parent = Frame
	self._scroller = Scroller

	local bodyPad = Instance.new("UIPadding")
	bodyPad.PaddingTop = UDim.new(0, 2)
	bodyPad.Parent = Scroller

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = Scroller
	self._bodyLayout = bodyLayout

	-- detect manual scroll (disable autoscroll if user scrolls up)
	table.insert(self._conns, Scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxY = math.max(0, Scroller.CanvasSize.Y.Offset - Scroller.AbsoluteWindowSize.Y)
		self._autoScroll = (Scroller.CanvasPosition.Y >= maxY - 12)
	end))

	-- ===== Status bar =====
	local Status = Instance.new("Frame")
	Status.Name = "StatusBar"
	Status.BackgroundColor3 = THEME.Bar
	Status.Position = UDim2.new(0, 0, 1, -22)
	Status.Size = UDim2.new(1, 0, 0, 22)
	Status.Parent = Frame

	local statusPad = Instance.new("UIPadding")
	statusPad.PaddingLeft = UDim.new(0, 6)
	statusPad.Parent = Status

	self._statusLabel = makeLabel({
		Parent = Status, Text = "0 entries", TextColor3 = THEME.Muted,
		TextSize = 12, Size = UDim2.new(1, -80, 1, 0), AutomaticSize = Enum.AutomaticSize.None,
		TextYAlignment = Enum.TextYAlignment.Center,
	})

	local jumpBtn = Instance.new("TextButton")
	jumpBtn.AutoButtonColor = false
	jumpBtn.BackgroundTransparency = 1
	jumpBtn.Size = UDim2.new(0, 90, 1, 0)
	jumpBtn.Position = UDim2.new(1, -90, 0, 0)
	jumpBtn.Font = Enum.Font.Code
	jumpBtn.TextSize = 12
	jumpBtn.TextColor3 = THEME.Accent
	jumpBtn.Text = "Jump to end"
	jumpBtn.Parent = Status
	jumpBtn.MouseButton1Click:Connect(function()
		self._autoScroll = true
		self:_scrollToBottom()
	end)

	-- hidden copy textbox (fallback when no setclipboard)
	local copyBox = Instance.new("TextBox")
	copyBox.Name = "CopyBuffer"
	copyBox.Visible = false
	copyBox.MultiLine = true
	copyBox.Text = ""
	copyBox.Parent = Frame
	self._copyBox = copyBox
end

--============================================================
-- LOG HOOKS
--============================================================

function Console:_hookLogs()
	for _, hist in ipairs(LogService:GetLogHistory()) do
		local kind = MSGTYPE_MAP[hist.messageType] or "Output"
		self:_ingest(kind, hist.message, hist.timestamp, nil, nil)
	end

	table.insert(self._conns, LogService.MessageOut:Connect(function(message, messageType)
		local kind = MSGTYPE_MAP[messageType] or "Output"
		if kind == "Error" then
			-- try to attach a recently-fired ScriptContext trace
			local pending = self._pendingErrors[message]
			if pending and (os.clock() - pending.time) < 0.5 then
				self._pendingErrors[message] = nil
				self:_ingest("Error", message, os.time(), pending.trace, pending.script)
				return
			end
		end
		self:_ingest(kind, message, os.time(), nil, nil)
	end))

	table.insert(self._conns, ScriptContext.Error:Connect(function(message, trace, scriptInst)
		self._pendingErrors[message] = { trace = trace, script = scriptInst, time = os.clock() }
	end))
end

-- public API: rich logging with real table values
function Console:Log(...)
	self:_customIngest("Output", ...)
end

function Console:Warn(...)
	self:_customIngest("Warning", ...)
end

function Console:LogError(...)
	self:_customIngest("Error", ...)
end

function Console:LogTable(name, tbl)
	self:_customIngest("Output", name, tbl)
end

function Console:_customIngest(kind, ...)
	local args = { ... }
	local parts = {}
	local tables = {}
	for i, v in ipairs(args) do
		if typeof(v) == "table" then
			parts[#parts + 1] = string.format("[table #%d: %d keys]", #tables + 1, countKeys(v))
			tables[#tables + 1] = v
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	self:_ingest(kind, table.concat(parts, "  "), os.time(), nil, nil, tables)
end

--============================================================
-- INGEST / RENDER
--============================================================

function Console:_ingest(kind, text, timestamp, trace, scriptInst, tables)
	self._counts[kind] = (self._counts[kind] or 0) + 1
	self._filterButtons[kind].Text = TYPE_ICON[kind] .. " " .. self._counts[kind]

	-- repeat-collapse
	local last = self._entries[#self._entries]
	if last and last.kind == kind and last.text == text and not trace and not tables then
		last.count += 1
		last.countLabel.Text = "(x" .. last.count .. ")"
		last.countLabel.Visible = true
		self:_touchScroll()
		self:_updateStatus()
		return
	end

	self._layoutOrder += 1
	local order = self._layoutOrder

	local row = Instance.new("Frame")
	row.BackgroundColor3 = (#self._entries % 2 == 0) and THEME.EntryA or THEME.EntryB
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = order
	row.Parent = self._scroller

	local rowPad = Instance.new("UIPadding")
	rowPad.PaddingLeft = UDim.new(0, 4)
	rowPad.PaddingRight = UDim.new(0, 4)
	rowPad.Parent = row

	local hasDetail = (trace ~= nil) or (tables ~= nil and #tables > 0)

	local header = Instance.new("TextButton")
	header.BackgroundTransparency = 1
	header.AutoButtonColor = false
	header.Size = UDim2.new(1, 0, 0, 0)
	header.AutomaticSize = Enum.AutomaticSize.Y
	header.Text = ""
	header.Active = hasDetail
	header.Parent = row

	local arrow = makeLabel({
		Parent = header, Text = hasDetail and ">" or " ",
		Size = UDim2.new(0, 14, 0, 20), AutomaticSize = Enum.AutomaticSize.None,
		TextColor3 = THEME.Muted, TextSize = 13,
	})

	local timeLabel = makeLabel({
		Parent = header, Text = formatTime(timestamp),
		Position = UDim2.new(0, 14, 0, 0),
		Size = UDim2.new(0, 64, 0, 20), AutomaticSize = Enum.AutomaticSize.None,
		TextColor3 = THEME.Muted, TextSize = 12,
	})

	local textLabel = makeLabel({
		Parent = header, Text = text,
		Position = UDim2.new(0, 82, 0, 0),
		Size = UDim2.new(1, -140, 0, 20),
		TextColor3 = TYPE_COLOR[kind], TextSize = 14,
	})

	local countLabel = makeLabel({
		Parent = header, Text = "",
		Position = UDim2.new(1, -50, 0, 0),
		Size = UDim2.new(0, 46, 0, 20), AutomaticSize = Enum.AutomaticSize.None,
		TextColor3 = THEME.Muted, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	countLabel.Visible = false

	local detail
	if hasDetail then
		detail = Instance.new("Frame")
		detail.BackgroundTransparency = 1
		detail.Size = UDim2.new(1, -18, 0, 0)
		detail.Position = UDim2.new(0, 18, 0, 0)
		detail.AutomaticSize = Enum.AutomaticSize.Y
		detail.Visible = false
		detail.LayoutOrder = 2
		detail.Parent = row

		local dLayout = Instance.new("UIListLayout")
		dLayout.SortOrder = Enum.SortOrder.LayoutOrder
		dLayout.Padding = UDim.new(0, 2)
		dLayout.Parent = detail

		local built = false
		local function build()
			if built then return end
			built = true

			if scriptInst then
				makeLabel({
					Parent = detail, TextColor3 = THEME.Muted, TextSize = 12,
					Text = "Source: " .. (pcall(function() return scriptInst:GetFullName() end) and scriptInst:GetFullName() or tostring(scriptInst)),
					LayoutOrder = 1,
				})
			end

			if trace and trace ~= "" then
				makeLabel({
					Parent = detail, TextColor3 = THEME.Muted, TextSize = 12,
					Text = trace, LayoutOrder = 2, Font = Enum.Font.Code,
				})
			end

			if tables then
				for i, t in ipairs(tables) do
					local tWrap = Instance.new("Frame")
					tWrap.BackgroundTransparency = 1
					tWrap.Size = UDim2.new(1, 0, 0, 0)
					tWrap.AutomaticSize = Enum.AutomaticSize.Y
					tWrap.LayoutOrder = 2 + i
					tWrap.Parent = detail

					local tLayout = Instance.new("UIListLayout")
					tLayout.SortOrder = Enum.SortOrder.LayoutOrder
					tLayout.Parent = tWrap

					buildTableTree(tWrap, t, 0)
				end
			end
		end

		header.MouseButton1Click:Connect(function()
			detail.Visible = not detail.Visible
			arrow.Text = detail.Visible and "v" or ">"
			if detail.Visible then build() end
		end)
	end

	local record = {
		kind = kind, text = text, count = 1,
		row = row, countLabel = countLabel, order = order,
	}
	self._entries[#self._entries + 1] = record

	self:_applyFilterToRow(record)
	self:_enforceMax()
	self:_touchScroll()
	self:_updateStatus()
end

function Console:_enforceMax()
	while #self._entries > self._maxEntries do
		local old = table.remove(self._entries, 1)
		old.row:Destroy()
	end
end

function Console:_touchScroll()
	if self._autoScroll then
		task.defer(function() self:_scrollToBottom() end)
	end
end

function Console:_scrollToBottom()
	local s = self._scroller
	s.CanvasPosition = Vector2.new(0, math.max(0, s.CanvasSize.Y.Offset))
end

--============================================================
-- FILTERING
--============================================================

function Console:_applyFilterToRow(record)
	local visible = self._filters[record.kind]
	if visible and self._search ~= "" then
		visible = record.text:lower():find(self._search, 1, true) ~= nil
	end
	record.row.Visible = visible
end

function Console:_refreshFilters()
	for _, record in ipairs(self._entries) do
		self:_applyFilterToRow(record)
	end
	self:_updateStatus()
end

function Console:_updateStatus()
	local visible = 0
	for _, r in ipairs(self._entries) do
		if r.row.Visible then visible += 1 end
	end
	self._statusLabel.Text = string.format(
		"%d shown / %d entries  |  O:%d  I:%d  W:%d  E:%d",
		visible, #self._entries,
		self._counts.Output, self._counts.Info, self._counts.Warning, self._counts.Error
	)
end

--============================================================
-- ACTIONS
--============================================================

function Console:_copyAll()
	local lines = {}
	for _, r in ipairs(self._entries) do
		lines[#lines + 1] = string.format("[%s] %s%s", r.kind, r.text, r.count > 1 and (" (x" .. r.count .. ")") or "")
	end
	local dump = table.concat(lines, "\n")

	local ok = false
	if typeof(setclipboard) == "function" then
		ok = pcall(setclipboard, dump)
	end
	if not ok then
		self._copyBox.Visible = true
		self._copyBox.Text = dump
		self._copyBox:CaptureFocus()
		task.delay(0.1, function()
			if self._copyBox then self._copyBox.Visible = false end
		end)
	end
end

function Console:Clear()
	for _, r in ipairs(self._entries) do
		r.row:Destroy()
	end
	table.clear(self._entries)
	self._layoutOrder = 0
	for _, t in ipairs(TYPE_ORDER) do
		self._counts[t] = 0
		self._filterButtons[t].Text = TYPE_ICON[t] .. " 0"
	end
	self:_updateStatus()
end

function Console:Destroy()
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self.Frame then
		self.Frame:Destroy()
	end
end

return Console
