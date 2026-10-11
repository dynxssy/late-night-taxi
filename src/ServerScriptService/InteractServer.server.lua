-- Handles first-person interactions on anything tagged "Interactable".
-- Attributes on the tagged instance: Action (Sit | ToggleLight | ToggleMeter | Radio | Wipers | Window), Prompt (text), LightGroup (part name to toggle).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage
local interact = remotes:FindFirstChild("Interact") or Instance.new("RemoteEvent")
interact.Name = "Interact"
interact.Parent = remotes

local MAX_RANGE = 14

local function setLights(part, on)
	for _, l in part:GetDescendants() do
		if l:IsA("Light") then
			l.Enabled = on
		end
	end
	part.Material = on and Enum.Material.Neon or Enum.Material.SmoothPlastic
end

local actions = {}

function actions.Sit(player, target)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and (target:IsA("Seat") or target:IsA("VehicleSeat")) and not target.Occupant then
		target:Sit(humanoid)
	end
end

function actions.ToggleLight(_, target)
	local on = not target:GetAttribute("On")
	target:SetAttribute("On", on)
	local model = target:FindFirstAncestorOfClass("Model") or target.Parent
	local group = target:GetAttribute("LightGroup")
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p.Name == group then
			setLights(p, on)
		end
	end
end

function actions.ToggleMeter(_, target)
	-- running meter: FareStart stores when the ride began; clients render the fare
	local on = not target:GetAttribute("On")
	target:SetAttribute("On", on)
	target:SetAttribute("FareStart", on and workspace:GetServerTimeNow() or nil)
end

function actions.Radio(_, target)
	local on = not target:GetAttribute("On")
	target:SetAttribute("On", on)
	local gui = target:FindFirstChild("RadioGui")
	if gui then
		gui.Enabled = on
	end
	local light = target:FindFirstChildOfClass("PointLight")
	if light then
		light.Enabled = on
	end
end

function actions.Wipers(_, target)
	local model = target:FindFirstAncestorOfClass("Model")
	if model then
		model:SetAttribute("Wipers", not model:GetAttribute("Wipers"))
	end
end

function actions.Window(_, target)
	-- window switch on a cab door armrest: the glass slides (animated on clients by CabVisuals)
	local door = target:FindFirstAncestorOfClass("Model")
	if door and door:HasTag("CabDoor") then
		door:SetAttribute("WindowOpen", not door:GetAttribute("WindowOpen"))
	end
end

-- more actions: a ModuleScript in ServerScriptService.InteractActions named after the Action,
-- returning function(player, target)
local extra = game:GetService("ServerScriptService"):FindFirstChild("InteractActions")
if extra then
	for _, m in extra:GetChildren() do
		if m:IsA("ModuleScript") and not actions[m.Name] then
			local ok, fn = pcall(require, m)
			if ok and type(fn) == "function" then
				actions[m.Name] = fn
			end
		end
	end
end

interact.OnServerEvent:Connect(function(player, target)
	if typeof(target) ~= "Instance" or not target:HasTag("Interactable") then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local pos = target:IsA("BasePart") and target.Position or (target:IsA("Model") and target:GetPivot().Position)
	if not (root and pos) or (root.Position - pos).Magnitude > MAX_RANGE then
		return
	end
	local action = actions[target:GetAttribute("Action")]
	if action then
		action(player, target)
	end
end)
