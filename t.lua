--[[
	Console.lua — Studio Output clone (visual match) + expandable errors/tables

	Usage:
		local Dock = loadstring(game:HttpGet("...sspdo.luau"))()
		local Console = loadstring(game:HttpGet("...Console.lua"))()

		local Window = Dock.new("Output", 550, 400)
		Window:Show()

		local console = Console.new()
		Window:Add(console.Frame)

		print("hello")          -- Log
		warn("careful")         -- Warning
		error("boom")           -- Error (with stack trace, expandable)

		console:Info("...")     -- blue, like DataModel/asset-loading lines
		console:System("...")   -- bold magenta, like 'auto-recovery' lines
		console:Log("data", { Name = "Daddy", Coins = 500 })  -- expandable table tree
		console:LogTable("PlayerData", workspace)

	console:Destroy() disconnects all listeners.
]]

local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Console = {}
Console.__index = Console

--============================================================
-- THEME (matched to Studio's dark theme)
--============================================================

local THEME = {
	Toolbar     = Color3.fromRGB(45, 45, 48),
	ToolbarLine = Color3.fromRGB(15, 15, 15),
	Content     = Color3.fromRGB(25, 25, 26),
	Dropdown    = Color3.fromRGB(50, 50, 53),
	DropdownHov = Color3.fromRGB(64, 64, 68),
	Border      = Color3.fromRGB(63, 63, 70),
	SearchBg    = Color3.fromRGB(60, 60, 60),

	Log         = Color3.fromRGB(222, 222, 222),
	Information = Color3.fromRGB(96, 165, 224),
	Warning     = Color3.fromRGB(224, 181, 92),
	Error       = Color3.fromRGB(226, 92, 92),
	System      = Color3.fromRGB(199, 138, 196),

	Muted       = Color3.fromRGB(140, 140, 140),
	Text        = Color3.fromRGB(215, 215, 215),
	Accent      = Color3.fromRGB(0, 122, 204),

	Key         = Color3.fromRGB(150, 200, 255),
	StrVal      = Color3.fromRGB(180, 230, 150),
	NumVal      = Color3.fromRGB(255, 180, 120),
	OtherVal    = Color3.fromRGB(200, 200, 200),
}

local TYPE_ORDER = { "Error", "Warning", "Information", "System", "Log" }
local TYPE_COLOR = {
	Error = THEME.Error, Warning = THEME.Warning, Information = THEME.Information,
	System = THEME.System, Log = THEME.Log,
}
local CONTEXT_ORDER = { "Edit", "Client", "Server", "Standalone", "CoreScript", "Studio" }

local MSGTYPE_MAP = {
	[Enum.MessageType.MessageOutput]  = "Log",
	[Enum.MessageType.MessageInfo]    = "Information",
	[Enum.MessageType.MessageWarning] = "Warning",
	[Enum.MessageType.MessageError]   = "Error",
}

--============================================================
-- UTIL
--============================================================

local function currentContext(scriptInst)
	if scriptInst then
		local ok, isLocal = pcall(function() return scriptInst:IsA("LocalScript") end)
		if ok and isLocal then return "Client" end
		local ok2, isServerScript = pcall(function() return scriptInst:IsA("Script") end)
		if ok2 and isServerScript then return "Server" end
	end
	if RunService:IsStudio() and RunService:IsServer() and RunService:IsClient() then
		return "Studio"
	end
	if RunService:IsServer() then return "Server" end
	if RunService:IsClient() then return "Client" end
	return "Standalone"
end

local function formatTimestamp(unixSeconds)
	unixSeconds = unixSeconds or (DateTime.now().UnixTimestampMillis / 1000)
	local whole = math.floor(unixSeconds)
	local ms = math.floor((unixSeconds - whole) * 1000 + 0.5)
	local ok, str = pcall(os.date, "%H:%M:%S", whole)
	if not ok then str = "00:00:00" end
	return string.format("%s.%03d", str, ms)
end

local function countKeys(t)
	local n = 0
	for _ in pairs(t) do n += 1 end
	return n
end

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 0)
	c.Parent = inst
	return c
end

local function strokeBorder(inst)
	local s = Instance.new("UIStroke")
	s.Color = THEME.Border
	s.Thickness = 1
	s.Parent = inst
end

local function escapeRich(s)
	s = tostring(s)
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;")
	return s
end

local function makeLabel(props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = props.Font or Enum.Font.Code
	l.TextSize = props.TextSize or 13
	l.TextColor3 = props.TextColor3 or THEME.Text
	l.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	l.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Top
	l.TextWrapped = props.TextWrapped ~= false
	l.Text = props.Text or ""
	l.Size = props.Size or UDim2.new(1, 0, 0, 18)
	l.AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None
	l.Position = props.Position or UDim2.new(0, 0, 0, 0)
	l.LayoutOrder = props.LayoutOrder or 0
	l.RichText = props.RichText or false
	l.ZIndex = props.ZIndex or 1
	l.Parent = props.Parent
	return l
end

--============================================================
-- VALUE / TABLE TREE
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

local function buildTableTree(parent, tbl, depth, seen, ref)
	seen = seen or {}
	depth = depth or 0
	ref = ref or { n = 0 }

	if seen[tbl] then
		ref.n += 1
		makeLabel({ Parent = parent, Text = "[cyclic reference]", TextColor3 = THEME.Muted, TextSize = 12, LayoutOrder = ref.n, AutomaticSize = Enum.AutomaticSize.Y })
		return
	end
	seen[tbl] = true

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
		ref.n += 1
		local order = ref.n

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
		header.Size = UDim2.new(1, 0, 0, 17)
		header.Text = ""
		header.Parent = row

		local arrow = makeLabel({
			Parent = header, Text = isTable and "▸" or " ", TextColor3 = THEME.Muted,
			Size = UDim2.new(0, 14, 0, 17), TextSize = 11, Font = Enum.Font.Code,
		})

		makeLabel({
			Parent = header, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -14, 0, 17),
			TextSize = 13, Font = Enum.Font.Code, RichText = true,
			Text = string.format(
				'<font color="#%s">%s</font> = <font color="#%s">%s</font>',
				THEME.Key:ToHex(), escapeRich(k), valueColor(v):ToHex(), escapeRich(valueToText(v))
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

			local cl = Instance.new("UIListLayout")
			cl.SortOrder = Enum.SortOrder.LayoutOrder
			cl.Parent = child

			local built = false
			header.MouseButton1Click:Connect(function()
				child.Visible = not child.Visible
				arrow.Text = child.Visible and "▾" or "▸"
				if child.Visible and not built then
					built = true
					buildTableTree(child, v, depth + 1, seen, ref)
				end
			end)
		end
	end

	if #keys == 0 then
		ref.n += 1
		makeLabel({ Parent = parent, Text = "-- empty --", TextColor3 = THEME.Muted, TextSize = 12, LayoutOrder = ref.n, AutomaticSize = Enum.AutomaticSize.Y })
	end
end

--============================================================
-- CONSTRUCTOR
--============================================================

function Console.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Console)

	self._maxEntries = opts.MaxEntries or 1000
	self._entries = {}
	self._layoutOrder = 0
	self._autoScroll = true
	self._typeFilters = { Error = true, Warning = true, Information = true, System = true, Log = true }
	self._contextFilters = { Edit = true, Client = true, Server = true, Standalone = true, CoreScript = true, Studio = true }
	self._search = ""
	self._typeCounts = { Error = 0, Warning = 0, Information = 0, System = 0, Log = 0 }
	self._contextCounts = { Edit = 0, Client = 0, Server = 0, Standalone = 0, CoreScript = 0, Studio = 0 }
	self._conns = {}
	self._pendingErrors = {}

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
	Frame.BackgroundColor3 = THEME.Content
	Frame.Size = UDim2.new(1, 0, 1, 0)
	Frame.ClipsDescendants = true
	self.Frame = Frame

	-- ===== toolbar =====
	local TopBar = Instance.new("Frame")
	TopBar.Name = "TopBar"
	TopBar.BackgroundColor3 = THEME.Toolbar
	TopBar.Size = UDim2.new(1, 0, 0, 32)
	TopBar.ZIndex = 2
	TopBar.Parent = Frame

	local line = Instance.new("Frame")
	line.BackgroundColor3 = THEME.ToolbarLine
	line.BorderSizePixel = 0
	line.Size = UDim2.new(1, 0, 0, 1)
	line.Position = UDim2.new(0, 0, 1, -1)
	line.Parent = TopBar

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = TopBar

	local topLayout = Instance.new("UIListLayout")
	topLayout.FillDirection = Enum.FillDirection.Horizontal
	topLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	topLayout.Padding = UDim.new(0, 4)
	topLayout.Parent = TopBar

	-- dropdown button factory
	local function makeDropdownButton(text, layoutOrder)
		local btn = Instance.new("TextButton")
		btn.AutoButtonColor = false
		btn.BackgroundColor3 = THEME.Dropdown
		btn.Size = UDim2.new(0, text == "All Messages" and 110 or 106, 1, 0)
		btn.Font = Enum.Font.SourceSans
		btn.TextSize = 14
		btn.TextColor3 = THEME.Text
		btn.Text = "  " .. text .. "  ▾"
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.LayoutOrder = layoutOrder
		btn.Parent = TopBar

		btn.MouseEnter:Connect(function() btn.BackgroundColor3 = THEME.DropdownHov end)
		btn.MouseLeave:Connect(function() btn.BackgroundColor3 = THEME.Dropdown end)
		return btn
	end

	local MsgBtn = makeDropdownButton("All Messages", 1)
	local CtxBtn = makeDropdownButton("All Contexts", 2)

	-- spacer pushes search/clear/more to the right
	local spacer = Instance.new("Frame")
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, -360, 1, 0)
	spacer.LayoutOrder = 3
	spacer.Parent = TopBar

	-- search box
	local Search = Instance.new("TextBox")
	Search.PlaceholderText = "Filter..."
	Search.Text = ""
	Search.ClearTextOnFocus = false
	Search.BackgroundColor3 = THEME.SearchBg
	Search.TextColor3 = THEME.Text
	Search.PlaceholderColor3 = THEME.Muted
	Search.Font = Enum.Font.SourceSans
	Search.TextSize = 14
	Search.Size = UDim2.new(0, 170, 1, 0)
	Search.ClipsDescendants = true
	Search.LayoutOrder = 4
	local sp = Instance.new("UIPadding")
	sp.PaddingLeft = UDim.new(0, 6)
	sp.PaddingRight = UDim.new(0, 16)
	sp.Parent = Search
	Search.Parent = TopBar

	makeLabel({
		Parent = Search, Text = "▾", TextColor3 = THEME.Muted, TextSize = 11,
		Position = UDim2.new(1, -14, 0, 0), Size = UDim2.new(0, 12, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center,
	})

	table.insert(self._conns, Search:GetPropertyChangedSignal("Text"):Connect(function()
		self._search = Search.Text:lower()
		self:_refreshFilters()
	end))

	-- clear (broom) button
	local ClearBtn = Instance.new("TextButton")
	ClearBtn.AutoButtonColor = false
	ClearBtn.BackgroundTransparency = 1
	ClearBtn.Size = UDim2.new(0, 26, 1, 0)
	ClearBtn.Font = Enum.Font.SourceSansBold
	ClearBtn.TextSize = 16
	ClearBtn.TextColor3 = THEME.Text
	ClearBtn.Text = "🧹"
	ClearBtn.LayoutOrder = 5
	ClearBtn.Parent = TopBar
	ClearBtn.MouseEnter:Connect(function() ClearBtn.BackgroundTransparency = 0.6; ClearBtn.BackgroundColor3 = THEME.DropdownHov end)
	ClearBtn.MouseLeave:Connect(function() ClearBtn.BackgroundTransparency = 1 end)
	ClearBtn.MouseButton1Click:Connect(function() self:Clear() end)

	-- more (...) button + menu
	local MoreBtn = Instance.new("TextButton")
	MoreBtn.AutoButtonColor = false
	MoreBtn.BackgroundTransparency = 1
	MoreBtn.Size = UDim2.new(0, 26, 1, 0)
	MoreBtn.Font = Enum.Font.SourceSansBold
	MoreBtn.TextSize = 16
	MoreBtn.TextColor3 = THEME.Text
	MoreBtn.Text = "⋯"
	MoreBtn.LayoutOrder = 6
	MoreBtn.Parent = TopBar
	MoreBtn.MouseEnter:Connect(function() MoreBtn.BackgroundTransparency = 0.6; MoreBtn.BackgroundColor3 = THEME.DropdownHov end)
	MoreBtn.MouseLeave:Connect(function() MoreBtn.BackgroundTransparency = 1 end)

	-- ===== outside-click catcher (shared by all popovers) =====
	local Catcher = Instance.new("TextButton")
	Catcher.Name = "Catcher"
	Catcher.BackgroundTransparency = 1
	Catcher.AutoButtonColor = false
	Catcher.Text = ""
	Catcher.Size = UDim2.new(1, 0, 1, 0)
	Catcher.ZIndex = 9
	Catcher.Visible = false
	Catcher.Parent = Frame

	local openPopover = nil
	local function closePopover()
		if openPopover then openPopover.Visible = false end
		openPopover = nil
		Catcher.Visible = false
	end
	Catcher.MouseButton1Click:Connect(closePopover)
	self._closePopover = closePopover

	local function togglePopover(pop)
		if openPopover == pop then
			closePopover()
		else
			if openPopover then openPopover.Visible = false end
			pop.Visible = true
			openPopover = pop
			Catcher.Visible = true
		end
	end

	-- ===== message type popover =====
	local MsgPop = Instance.new("Frame")
	MsgPop.BackgroundColor3 = THEME.Dropdown
	MsgPop.BorderSizePixel = 0
	MsgPop.Size = UDim2.new(0, 170, 0, 0)
	MsgPop.AutomaticSize = Enum.AutomaticSize.Y
	MsgPop.Position = UDim2.new(0, 6, 0, 32)
	MsgPop.Visible = false
	MsgPop.ZIndex = 10
	MsgPop.Parent = Frame
	strokeBorder(MsgPop)

	local mLayout = Instance.new("UIListLayout")
	mLayout.SortOrder = Enum.SortOrder.LayoutOrder
	mLayout.Parent = MsgPop

	self._typeRows = {}
	self:_buildFilterRow(MsgPop, "All", nil, THEME.Text, 0, true)
	for i, t in ipairs(TYPE_ORDER) do
		self:_buildFilterRow(MsgPop, t, t, TYPE_COLOR[t], i, false)
	end

	MsgBtn.MouseButton1Click:Connect(function() togglePopover(MsgPop) end)

	-- ===== context popover =====
	local CtxPop = Instance.new("Frame")
	CtxPop.BackgroundColor3 = THEME.Dropdown
	CtxPop.BorderSizePixel = 0
	CtxPop.Size = UDim2.new(0, 170, 0, 0)
	CtxPop.AutomaticSize = Enum.AutomaticSize.Y
	CtxPop.Position = UDim2.new(0, 122, 0, 32)
	CtxPop.Visible = false
	CtxPop.ZIndex = 10
	CtxPop.Parent = Frame
	strokeBorder(CtxPop)

	local cLayout = Instance.new("UIListLayout")
	cLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cLayout.Parent = CtxPop

	self._contextRows = {}
	self:_buildContextRow(CtxPop, "All", nil, 0, true)
	for i, c in ipairs(CONTEXT_ORDER) do
		self:_buildContextRow(CtxPop, c, c, i, false)
	end

	CtxBtn.MouseButton1Click:Connect(function() togglePopover(CtxPop) end)

	-- ===== more menu popover =====
	local MorePop = Instance.new("Frame")
	MorePop.BackgroundColor3 = THEME.Dropdown
	MorePop.BorderSizePixel = 0
	MorePop.Size = UDim2.new(0, 130, 0, 0)
	MorePop.AutomaticSize = Enum.AutomaticSize.Y
	MorePop.Position = UDim2.new(1, -130, 0, 32)
	MorePop.Visible = false
	MorePop.ZIndex = 10
	MorePop.Parent = Frame
	strokeBorder(MorePop)

	local moreLayout = Instance.new("UIListLayout")
	moreLayout.SortOrder = Enum.SortOrder.LayoutOrder
	moreLayout.Parent = MorePop

	local function makeMenuItem(text, order, callback)
		local b = Instance.new("TextButton")
		b.AutoButtonColor = false
		b.BackgroundTransparency = 1
		b.Size = UDim2.new(1, 0, 0, 26)
		b.Font = Enum.Font.SourceSans
		b.TextSize = 14
		b.TextColor3 = THEME.Text
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.Text = "   " .. text
		b.LayoutOrder = order
		b.Parent = MorePop
		b.MouseEnter:Connect(function() b.BackgroundTransparency = 0; b.BackgroundColor3 = THEME.DropdownHov end)
		b.MouseLeave:Connect(function() b.BackgroundTransparency = 1 end)
		b.MouseButton1Click:Connect(function()
			closePopover()
			callback()
		end)
	end
	makeMenuItem("Copy All", 1, function() self:_copyAll() end)
	makeMenuItem("Clear Output", 2, function() self:Clear() end)
	makeMenuItem(self._autoScroll and "✓ Autoscroll" or "Autoscroll", 3, function()
		self._autoScroll = not self._autoScroll
	end)

	MoreBtn.MouseButton1Click:Connect(function() togglePopover(MorePop) end)

	-- ===== body =====
	local Scroller = Instance.new("ScrollingFrame")
	Scroller.Name = "Body"
	Scroller.BackgroundColor3 = THEME.Content
	Scroller.BorderSizePixel = 0
	Scroller.Position = UDim2.new(0, 0, 0, 32)
	Scroller.Size = UDim2.new(1, 0, 1, -32)
	Scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
	Scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Scroller.ScrollBarThickness = 8
	Scroller.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 90)
	Scroller.ZIndex = 1
	Scroller.Parent = Frame
	self._scroller = Scroller

	local bodyPad = Instance.new("UIPadding")
	bodyPad.PaddingTop = UDim.new(0, 2)
	bodyPad.PaddingLeft = UDim.new(0, 6)
	bodyPad.PaddingRight = UDim.new(0, 6)
	bodyPad.Parent = Scroller

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = Scroller

	table.insert(self._conns, Scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxY = math.max(0, Scroller.CanvasSize.Y.Offset - Scroller.AbsoluteWindowSize.Y)
		self._autoScroll = (Scroller.CanvasPosition.Y >= maxY - 12)
	end))

	-- hidden copy textbox fallback
	local copyBox = Instance.new("TextBox")
	copyBox.Visible = false
	copyBox.MultiLine = true
	copyBox.Text = ""
	copyBox.Parent = Frame
	self._copyBox = copyBox
end

function Console:_buildFilterRow(parent, label, key, color, order, isAll)
	local row = Instance.new("TextButton")
	row.AutoButtonColor = false
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 24)
	row.Text = ""
	row.LayoutOrder = order
	row.Parent = parent

	row.MouseEnter:Connect(function() row.BackgroundTransparency = 0; row.BackgroundColor3 = THEME.DropdownHov end)
	row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)

	local box = Instance.new("Frame")
	box.BackgroundColor3 = THEME.Content
	box.BorderSizePixel = 0
	box.Size = UDim2.new(0, 12, 0, 12)
	box.Position = UDim2.new(0, 8, 0.5, -6)
	box.Parent = row
	strokeBorder(box)

	local check = makeLabel({
		Parent = box, Text = "✓", TextColor3 = THEME.Accent, TextSize = 12,
		Size = UDim2.new(1, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center, Font = Enum.Font.SourceSansBold,
	})
	check.Visible = true

	local text = makeLabel({
		Parent = row, Text = label, TextColor3 = color, TextSize = 13,
		Position = UDim2.new(0, 28, 0, 0), Size = UDim2.new(1, -60, 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center, Font = Enum.Font.SourceSans,
	})

	local countLbl = makeLabel({
		Parent = row, Text = "", TextColor3 = THEME.Muted, TextSize = 12,
		Position = UDim2.new(1, -40, 0, 0), Size = UDim2.new(0, 34, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center,
	})

	if isAll then
		self._typeAllCheck = check
		row.MouseButton1Click:Connect(function()
			local allOn = not self._typeAllCheck.Visible
			for _, t in ipairs(TYPE_ORDER) do
				self._typeFilters[t] = allOn
				self._typeRows[t].Visible = allOn
			end
			self._typeAllCheck.Visible = allOn
			self:_refreshFilters()
		end)
	else
		self._typeRows[key] = check
		row.MouseButton1Click:Connect(function()
			self._typeFilters[key] = not self._typeFilters[key]
			check.Visible = self._typeFilters[key]
			local allOn = true
			for _, t in ipairs(TYPE_ORDER) do
				if not self._typeFilters[t] then allOn = false break end
			end
			self._typeAllCheck.Visible = allOn
			self:_refreshFilters()
		end)
		self._typeCountLabels = self._typeCountLabels or {}
		self._typeCountLabels[key] = countLbl
	end
end

function Console:_buildContextRow(parent, label, key, order, isAll)
	local row = Instance.new("TextButton")
	row.AutoButtonColor = false
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 24)
	row.Text = ""
	row.LayoutOrder = order
	row.Parent = parent

	row.MouseEnter:Connect(function() row.BackgroundTransparency = 0; row.BackgroundColor3 = THEME.DropdownHov end)
	row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)

	local box = Instance.new("Frame")
	box.BackgroundColor3 = THEME.Content
	box.BorderSizePixel = 0
	box.Size = UDim2.new(0, 12, 0, 12)
	box.Position = UDim2.new(0, 8, 0.5, -6)
	box.Parent = row
	strokeBorder(box)

	local check = makeLabel({
		Parent = box, Text = "✓", TextColor3 = THEME.Accent, TextSize = 12,
		Size = UDim2.new(1, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center, Font = Enum.Font.SourceSansBold,
	})
	check.Visible = true

	makeLabel({
		Parent = row, Text = label, TextColor3 = THEME.Text, TextSize = 13,
		Position = UDim2.new(0, 28, 0, 0), Size = UDim2.new(1, -60, 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center, Font = Enum.Font.SourceSans,
	})

	local countLbl = makeLabel({
		Parent = row, Text = "", TextColor3 = THEME.Muted, TextSize = 12,
		Position = UDim2.new(1, -40, 0, 0), Size = UDim2.new(0, 34, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center,
	})

	if isAll then
		self._ctxAllCheck = check
		row.MouseButton1Click:Connect(function()
			local allOn = not self._ctxAllCheck.Visible
			for _, c in ipairs(CONTEXT_ORDER) do
				self._contextFilters[c] = allOn
				self._contextRows[c].Visible = allOn
			end
			self._ctxAllCheck.Visible = allOn
			self:_refreshFilters()
		end)
	else
		self._contextRows[key] = check
		row.MouseButton1Click:Connect(function()
			self._contextFilters[key] = not self._contextFilters[key]
			check.Visible = self._contextFilters[key]
			local allOn = true
			for _, c in ipairs(CONTEXT_ORDER) do
				if not self._contextFilters[c] then allOn = false break end
			end
			self._ctxAllCheck.Visible = allOn
			self:_refreshFilters()
		end)
		self._ctxCountLabels = self._ctxCountLabels or {}
		self._ctxCountLabels[key] = countLbl
	end
end

--============================================================
-- LOG HOOKS
--============================================================

function Console:_hookLogs()
	for _, hist in ipairs(LogService:GetLogHistory()) do
		local kind = MSGTYPE_MAP[hist.messageType] or "Log"
		self:_ingest(kind, hist.message, hist.timestamp, nil, nil)
	end

	table.insert(self._conns, LogService.MessageOut:Connect(function(message, messageType)
		local kind = MSGTYPE_MAP[messageType] or "Log"
		if kind == "Error" then
			local pending = self._pendingErrors[message]
			if pending and (os.clock() - pending.time) < 0.5 then
				self._pendingErrors[message] = nil
				self:_ingest("Error", message, nil, pending.trace, pending.script)
				return
			end
		end
		self:_ingest(kind, message, nil, nil, nil)
	end))

	table.insert(self._conns, ScriptContext.Error:Connect(function(message, trace, scriptInst)
		self._pendingErrors[message] = { trace = trace, script = scriptInst, time = os.clock() }
	end))
end

function Console:Log(...) self:_customIngest("Log", ...) end
function Console:Warn(...) self:_customIngest("Warning", ...) end
function Console:LogError(...) self:_customIngest("Error", ...) end
function Console:Info(...) self:_customIngest("Information", ...) end
function Console:System(...) self:_customIngest("System", ...) end
function Console:LogTable(name, tbl) self:_customIngest("Log", name, tbl) end

function Console:_customIngest(kind, ...)
	local args = { ... }
	local parts = {}
	local tables = {}
	for _, v in ipairs(args) do
		if typeof(v) == "table" then
			parts[#parts + 1] = string.format("[table: %d keys]", countKeys(v))
			tables[#tables + 1] = v
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	self:_ingest(kind, table.concat(parts, "  "), nil, nil, nil, tables)
end

--============================================================
-- INGEST / RENDER
--============================================================

function Console:_ingest(kind, text, timestamp, trace, scriptInst, tables)
	local context = currentContext(scriptInst)

	self._typeCounts[kind] = (self._typeCounts[kind] or 0) + 1
	if self._typeCountLabels and self._typeCountLabels[kind] then
		self._typeCountLabels[kind].Text = "(" .. self._typeCounts[kind] .. ")"
	end
	self._contextCounts[context] = (self._contextCounts[context] or 0) + 1
	if self._ctxCountLabels and self._ctxCountLabels[context] then
		self._ctxCountLabels[context].Text = "(" .. self._contextCounts[context] .. ")"
	end

	local last = self._entries[#self._entries]
	if last and last.kind == kind and last.text == text and last.context == context and not trace and not tables then
		last.count += 1
		last.repeatText.Text = "(x" .. last.count .. ")"
		last.repeatText.Visible = true
		self:_touchScroll()
		return
	end

	self._layoutOrder += 1
	local order = self._layoutOrder

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = order
	row.Parent = self._scroller

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
		Parent = header, Text = hasDetail and "▸" or "",
		Size = UDim2.new(0, 12, 0, 18), TextColor3 = THEME.Muted, TextSize = 11,
	})

	local repeatText = makeLabel({
		Parent = header, Text = "", TextColor3 = THEME.Muted, TextSize = 12,
		Position = UDim2.new(1, -40, 0, 0), Size = UDim2.new(0, 40, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	repeatText.Visible = false

	local color = TYPE_COLOR[kind] or THEME.Log
	local ts = formatTimestamp(timestamp)
	local body = escapeRich(text)
	local ctxSuffix = string.format('  <font color="#%s">- %s</font>', THEME.Muted:ToHex(), context)
	local msgSpan
	if kind == "System" then
		msgSpan = string.format('<b><font color="#%s">%s</font></b>', color:ToHex(), body)
	else
		msgSpan = string.format('<font color="#%s">%s</font>', color:ToHex(), body)
	end

	local textLabel = makeLabel({
		Parent = header,
		Position = UDim2.new(0, 12, 0, 0),
		Size = UDim2.new(1, -56, 0, 18),
		AutomaticSize = Enum.AutomaticSize.Y,
		RichText = true,
		TextSize = 13,
		Text = string.format('<font color="#%s">%s</font>  %s%s', THEME.Muted:ToHex(), ts, msgSpan, ctxSuffix),
	})

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
				local full = pcall(function() return scriptInst:GetFullName() end) and scriptInst:GetFullName() or tostring(scriptInst)
				makeLabel({ Parent = detail, TextColor3 = THEME.Muted, TextSize = 12, Text = "Source: " .. full, LayoutOrder = 1, AutomaticSize = Enum.AutomaticSize.Y })
			end

			if trace and trace ~= "" then
				makeLabel({ Parent = detail, TextColor3 = THEME.Muted, TextSize = 12, Text = trace, LayoutOrder = 2, Font = Enum.Font.Code, AutomaticSize = Enum.AutomaticSize.Y })
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
			arrow.Text = detail.Visible and "▾" or "▸"
			if detail.Visible then build() end
		end)
	end

	local record = {
		kind = kind, text = text, context = context, count = 1,
		row = row, repeatText = repeatText, order = order,
	}
	self._entries[#self._entries + 1] = record

	self:_applyFilterToRow(record)
	self:_enforceMax()
	self:_touchScroll()
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
	local visible = self._typeFilters[record.kind] and self._contextFilters[record.context]
	if visible and self._search ~= "" then
		visible = record.text:lower():find(self._search, 1, true) ~= nil
	end
	record.row.Visible = visible
end

function Console:_refreshFilters()
	for _, record in ipairs(self._entries) do
		self:_applyFilterToRow(record)
	end
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
		self._typeCounts[t] = 0
		if self._typeCountLabels[t] then self._typeCountLabels[t].Text = "" end
	end
	for _, c in ipairs(CONTEXT_ORDER) do
		self._contextCounts[c] = 0
		if self._ctxCountLabels[c] then self._ctxCountLabels[c].Text = "" end
	end
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
