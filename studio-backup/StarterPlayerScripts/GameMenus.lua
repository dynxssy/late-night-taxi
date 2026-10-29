-- GameMenus: the in-game menu (MENU button, P, or D-pad down): settings, tip jar, credits, quit the night.
-- ShiftHUD's main menu opens pages here through the Open event. Settings are saved by MetaServer.
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local remotes = RS:WaitForChild("Remotes")
local gameRemote = remotes:WaitForChild("Game")
local meta = remotes:WaitForChild("Meta", 20)
local Lang = require(RS:WaitForChild("Lang"))
local TIPS = require(RS:WaitForChild("DonationConfig"))

local FONT = Enum.Font.GothamBold
local INK = Color3.new(1, 1, 1)
local DIM = Color3.fromRGB(200, 200, 200)

local RU = {
	MENU = "МЕНЮ",
	RESUME = "ПРОДОЛЖИТЬ",
	SETTINGS = "НАСТРОЙКИ",
	["TIP JAR"] = "ЧАЕВЫЕ",
	CREDITS = "АВТОРЫ",
	["QUIT THE NIGHT"] = "ВЫЙТИ ИЗ НОЧИ",
	BACK = "НАЗАД",
	VOLUME = "ГРОМКОСТЬ",
	["LOOK SENSITIVITY"] = "ЧУВСТВИТЕЛЬНОСТЬ ОБЗОРА",
	["RETRO FILTER"] = "РЕТРО-ФИЛЬТР",
	OFF = "ВЫКЛ",
	LOW = "СЛАБЫЙ",
	FULL = "ПОЛНЫЙ",
	["LANGUAGE: ENGLISH"] = "ЯЗЫК: РУССКИЙ",
	["The night keeps going while this menu is open."] = "Ночь продолжается, пока открыто меню.",
	["Tips keep the cab running. They don't change the game."] = "Чаевые помогают игре. На игру они не влияют.",
	["The tip jar opens soon."] = "Банка для чаевых скоро откроется.",
}
local function T(s)
	return Lang.code() == "ru" and RU[s] or s
end

local gui = Instance.new("ScreenGui")
gui.Name = "GameMenus"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 60
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local uiScale = Instance.new("UIScale")
uiScale.Parent = gui
local function rescale()
	local vp = workspace.CurrentCamera.ViewportSize
	uiScale.Scale = math.clamp(math.min(vp.X / 1000, vp.Y / 620), 0.72, 1.2)
end
rescale()
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function label(parent, text, h, props)
	local l = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, h or 24),
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 18,
		TextColor3 = INK,
		TextWrapped = true,
		TextStrokeTransparency = 0.4,
		Text = text,
	}, parent)
	for k, v in props or {} do
		l[k] = v
	end
	return l
end

local function button(parent, text, onClick, size)
	local b = new("TextButton", {
		Size = size or UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = Color3.fromRGB(60, 58, 54),
		BorderSizePixel = 0,
		Font = FONT,
		TextSize = 18,
		TextColor3 = INK,
		TextStrokeTransparency = 0.5,
		Text = text,
	}, parent)
	b.Activated:Connect(onClick)
	return b
end

-- the MENU button, top right, on every device
local menuBtn = button(gui, "", function() end, UDim2.fromOffset(96, 34))
menuBtn.AnchorPoint = Vector2.new(1, 0)
menuBtn.Position = UDim2.new(1, -12, 0, 12)
menuBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
menuBtn.BackgroundTransparency = 0.3
menuBtn.TextSize = 16
local function menuLabel()
	local key = UIS.GamepadEnabled and "" or (UIS.KeyboardEnabled and not UIS.TouchEnabled and " [P]" or "")
	menuBtn.Text = "≡ " .. T("MENU") .. key
	menuBtn.Size = UDim2.fromOffset(key ~= "" and 116 or 96, 34)
end

local backdrop = new("TextButton", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.45,
	AutoButtonColor = false,
	Text = "",
	Selectable = false,
	Visible = false,
	ZIndex = 1,
}, gui)

local panel = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(420, 440),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.02,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 2,
}, gui)
new("UIPadding", {
	PaddingLeft = UDim.new(0, 16),
	PaddingRight = UDim.new(0, 16),
	PaddingTop = UDim.new(0, 14),
	PaddingBottom = UDim.new(0, 14),
}, panel)
new("UIListLayout", { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, panel)

---------------------------------------------------------------- settings

local settings = { volume = 1, sens = 1, retro = 1 }
local master = Instance.new("SoundGroup")
master.Name = "LNTMaster"
master.Parent = SoundService

local function route(d)
	if d:IsA("Sound") and d.SoundGroup == nil then
		d.SoundGroup = master
	end
end
for _, d in game:GetDescendants() do
	pcall(route, d)
end
game.DescendantAdded:Connect(function(d)
	pcall(route, d)
end)

local function apply()
	master.Volume = settings.volume
	player:SetAttribute("LookSens", settings.sens)
	Lighting:SetAttribute("PS1Strength", settings.retro)
end

local saveQueued = false
local function save()
	apply()
	if saveQueued or not meta then
		return
	end
	saveQueued = true
	task.delay(1, function()
		saveQueued = false
		pcall(meta.InvokeServer, meta, "set", settings)
	end)
end

task.spawn(function()
	if meta then
		local ok, got = pcall(meta.InvokeServer, meta, "get")
		if ok and type(got) == "table" then
			for k, v in got do
				settings[k] = v
			end
		end
	end
	apply()
end)

---------------------------------------------------------------- pages

local inShift = false
local page
local function clear()
	for _, c in panel:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function focusFirst()
	if UIS.GamepadEnabled then
		for _, c in panel:GetDescendants() do
			if c:IsA("TextButton") then
				GuiService.SelectedObject = c
				return
			end
		end
	end
end

local show
local function setOpen(on)
	panel.Visible = on
	backdrop.Visible = on
	player:SetAttribute("MenuOpen", on or nil)
	if not on then
		page = nil
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
	end
end

-- a row of  -  value  +  for a stepped setting
local function stepper(name, key, step, lo, hi, fmt)
	label(panel, T(name), 20, { TextColor3 = DIM, TextSize = 15 })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, panel)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center }, row)
	local value
	local function set(v)
		settings[key] = math.clamp(math.floor(v / step + 0.5) * step, lo, hi)
		value.Text = fmt(settings[key])
		save()
	end
	button(row, "-", function()
		set(settings[key] - step)
	end, UDim2.fromOffset(60, 34))
	value = label(row, fmt(settings[key]), 34, { Size = UDim2.fromOffset(140, 34) })
	button(row, "+", function()
		set(settings[key] + step)
	end, UDim2.fromOffset(60, 34))
end

local pages = {}

function pages.main()
	label(panel, T("MENU"), 40, { TextSize = 28 })
	button(panel, T("RESUME"), function()
		setOpen(false)
	end)
	button(panel, T("SETTINGS"), function()
		show("settings")
	end)
	button(panel, T("TIP JAR"), function()
		show("tips")
	end)
	button(panel, T("CREDITS"), function()
		show("credits")
	end)
	if inShift and not player:GetAttribute("CoopGuest") then
		local q = button(panel, T("QUIT THE NIGHT"), function()
			setOpen(false)
			gameRemote:FireServer("menu")
		end)
		q.TextColor3 = Color3.fromRGB(255, 110, 100)
	end
	if inShift then
		label(panel, T("The night keeps going while this menu is open."), 40, { TextColor3 = DIM, TextSize = 14 })
	end
end

function pages.settings()
	label(panel, T("SETTINGS"), 36, { TextSize = 24 })
	stepper("VOLUME", "volume", 0.1, 0, 1, function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end)
	stepper("LOOK SENSITIVITY", "sens", 0.1, 0.2, 3, function(v)
		return string.format("%.1fx", v)
	end)
	local names = { [0] = "OFF", [0.5] = "LOW", [1] = "FULL" }
	label(panel, T("RETRO FILTER"), 20, { TextColor3 = DIM, TextSize = 15 })
	local retro
	retro = button(panel, T(names[settings.retro] or "FULL"), function()
		settings.retro = settings.retro >= 1 and 0 or settings.retro >= 0.5 and 1 or 0.5
		retro.Text = T(names[settings.retro])
		save()
	end)
	local isRu = Lang.code() == "ru"
	button(panel, isRu and "ЯЗЫК: РУССКИЙ  /  LANGUAGE" or "LANGUAGE: ENGLISH  /  ЯЗЫК", function()
		gameRemote:FireServer("lang", isRu and "en" or "ru")
		task.delay(0.5, function()
			if page == "settings" then
				show("settings")
			end
			menuLabel()
		end)
	end)
	button(panel, T("BACK"), function()
		show("main")
	end)
end

function pages.tips()
	label(panel, T("TIP JAR"), 36, { TextSize = 24 })
	label(panel, T("Tips keep the cab running. They don't change the game."), 44, { TextColor3 = DIM, TextSize = 15 })
	local any = false
	for _, tip in TIPS do
		if tip.id and tip.id ~= 0 then
			any = true
			local b = button(panel, string.format("%s   R$ %d", string.upper(tip.name), tip.price), function()
				MarketplaceService:PromptProductPurchase(player, tip.id)
			end)
			-- show the live price if it was changed in Creator Hub
			task.spawn(function()
				local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, tip.id, Enum.InfoType.Product)
				if ok and info and info.PriceInRobux and b.Parent then
					b.Text = string.format("%s   R$ %d", string.upper(tip.name), info.PriceInRobux)
				end
			end)
		end
	end
	if not any then
		label(panel, T("The tip jar opens soon."), 40)
	end
	button(panel, T("BACK"), function()
		show("main")
	end)
end

function pages.credits()
	label(panel, T("CREDITS"), 36, { TextSize = 24 })
	label(panel, table.concat({
		"LATE NIGHT TAXI",
		"Lantern Cabs, Port Vesper, 1997",
		"",
		"Game by dynxssy",
		"Built with help from Claude (Anthropic)",
		"Models, sounds and textures: Roblox Creator Store creators",
		"",
		"Thank you for driving the night shift.",
	}, "\n"), 230, { TextSize = 16, TextYAlignment = Enum.TextYAlignment.Top })
	button(panel, T("BACK"), function()
		show("main")
	end)
end

function show(name)
	clear()
	page = name
	pages[name]()
	setOpen(true)
	page = name
	focusFirst()
end

local function toggle()
	if panel.Visible then
		setOpen(false)
	else
		show("main")
	end
end
menuBtn.Activated:Connect(toggle)
backdrop.Activated:Connect(function()
	setOpen(false)
end)

UIS.InputBegan:Connect(function(io, processed)
	if io.KeyCode == Enum.KeyCode.DPadDown and not panel.Visible then
		toggle()
	elseif io.KeyCode == Enum.KeyCode.ButtonB and panel.Visible then
		if page and page ~= "main" then
			show("main")
		else
			setOpen(false)
		end
	elseif not processed and io.KeyCode == Enum.KeyCode.P then
		toggle()
	end
end)

local open = Instance.new("BindableEvent")
open.Name = "Open"
open.Event:Connect(function(name)
	show(pages[name] and name or "main")
end)
open.Parent = script

-- know when a night is running (for QUIT THE NIGHT)
gameRemote.OnClientEvent:Connect(function(kind)
	if kind == "start" then
		inShift = true
	elseif kind == "menu" or kind == "summary" or kind == "fail" or kind == "ending" then
		inShift = false
	end
end)

menuLabel()
UIS.LastInputTypeChanged:Connect(menuLabel)
player:GetAttributeChangedSignal("Lang"):Connect(menuLabel)
