-- Server side of getting in and out of the cab. Clients play the first-person sequences; this
-- script owns the truth: seat reservations, sitting/unseating, door state, collision groups,
-- spawning players seated, and arm IK on R15 drivers so other players see hands on the wheel.
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local cab = workspace:WaitForChild("Vehicles"):WaitForChild("Cab")
local chassis = cab:WaitForChild("Chassis")
local doorsFolder = cab:WaitForChild("Doors")
local wheel = cab:WaitForChild("SteeringWheel")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local seatRemote = remotes:FindFirstChild("CabSeat") or Instance.new("RemoteFunction")
seatRemote.Name = "CabSeat"
seatRemote.Parent = remotes

local SEAT_ORDER = { "DriverSeat", "ShotgunSeat", "BackSeatL", "BackSeatR" }
local ROW_PARTNER = { DriverSeat = "ShotgunSeat", ShotgunSeat = "DriverSeat", BackSeatL = "BackSeatR", BackSeatR = "BackSeatL" }
local MAX_ENTER_SPEED = 3
local MAX_EXIT_SPEED = 4
local MAX_DOOR_RANGE = 14
local RESERVE_TIMEOUT = 6

-- collision groups: the cab shell blocks walking players but not the world or riders in transit
for _, g in { "CabShell", "Characters", "CharTransit" } do
	if not PhysicsService:IsCollisionGroupRegistered(g) then
		PhysicsService:RegisterCollisionGroup(g)
	end
end
PhysicsService:CollisionGroupSetCollidable("CabShell", "Default", false)
PhysicsService:CollisionGroupSetCollidable("CabShell", "CabShell", false)
PhysicsService:CollisionGroupSetCollidable("CabShell", "Characters", true)
PhysicsService:CollisionGroupSetCollidable("CabShell", "CharTransit", false)
PhysicsService:CollisionGroupSetCollidable("CharTransit", "Characters", false)

local function seatOf(name)
	return cab:FindFirstChild(name)
end

local function isCabSeat(part)
	return part and part.Parent == cab and ROW_PARTNER[part.Name] ~= nil
end

local function cabSpeed()
	return chassis.AssemblyLinearVelocity.Magnitude
end

local function seatFree(seat, player)
	if seat.Occupant then
		return false
	end
	local by = seat:GetAttribute("ReservedBy")
	return by == nil or (player and by == player.UserId)
end

local reservations = {} -- seat -> { player, time, door }

local function release(seat)
	reservations[seat] = nil
	seat:SetAttribute("ReservedBy", nil)
end

local function releaseAll(player)
	for seat, r in reservations do
		if r.player == player then
			release(seat)
		end
	end
end

local function setDoor(door, open)
	door:SetAttribute("Open", open)
end

local function charOf(player)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return char, hum, root
	end
end

local function setGroup(char, group)
	for _, p in char:GetDescendants() do
		if p:IsA("BasePart") then
			p.CollisionGroup = group
		end
	end
end

local function inRange(root, door)
	return (root.Position - door:GetPivot().Position).Magnitude <= MAX_DOOR_RANGE
end

local function unseat(hum, root, player)
	local seat = hum.SeatPart
	if seat then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end
	hum.Sit = false
	if root:CanSetNetworkOwnership() then
		root:SetNetworkOwner(player)
	end
end

local handlers = {}

-- Reserve the seat behind this door. A door never leads to the far seat: nobody climbs over a rider.
function handlers.Enter(player, door)
	local _, hum, root = charOf(player)
	if not (hum and typeof(door) == "Instance" and door.Parent == doorsFolder) then
		return { ok = false }
	end
	if hum.SeatPart then
		return { ok = false, reason = "Already seated" }
	end
	if not inRange(root, door) then
		return { ok = false, reason = "Too far" }
	end
	if cabSpeed() > MAX_ENTER_SPEED then
		return { ok = false, reason = "Cab is moving" }
	end
	local busy = door:GetAttribute("BusyBy")
	if busy and busy ~= player.UserId then
		return { ok = false, reason = "Door in use" }
	end
	releaseAll(player)
	local pick = seatOf(door:GetAttribute("Seat"))
	if not (pick and seatFree(pick, player)) then
		return { ok = false, reason = "Seat taken" }
	end
	reservations[pick] = { player = player, time = os.clock(), door = door }
	pick:SetAttribute("ReservedBy", player.UserId)
	door:SetAttribute("BusyBy", player.UserId)
	return { ok = true, seat = pick.Name }
end

function handlers.Sit(player, seatName)
	local char, hum = charOf(player)
	local seat = typeof(seatName) == "string" and seatOf(seatName)
	if not (char and seat and reservations[seat] and reservations[seat].player == player) then
		return { ok = false }
	end
	if seat.Occupant then
		release(seat)
		return { ok = false, reason = "Seat taken" }
	end
	setGroup(char, "Characters")
	seat:Sit(hum)
	release(seat)
	return { ok = hum.SeatPart == seat }
end

-- Unseat for the exit sequence; the client walks the body out through the given door.
function handlers.Exit(player, door)
	local _, hum, root = charOf(player)
	local seat = hum and hum.SeatPart
	if not (isCabSeat(seat) and typeof(door) == "Instance" and door.Parent == doorsFolder) then
		return { ok = false }
	end
	if cabSpeed() > MAX_EXIT_SPEED then
		return { ok = false, reason = "Too fast to get out" }
	end
	if seatOf(door:GetAttribute("Seat")):GetAttribute("Row") ~= seat:GetAttribute("Row") then
		return { ok = false }
	end
	door:SetAttribute("BusyBy", player.UserId)
	unseat(hum, root, player)
	return { ok = true }
end

-- Slide to the other seat in the same row.
function handlers.Move(player, seatName)
	local char, hum, root = charOf(player)
	local from = hum and hum.SeatPart
	local to = typeof(seatName) == "string" and seatOf(seatName)
	if not (isCabSeat(from) and to and ROW_PARTNER[from.Name] == to.Name and seatFree(to, player)) then
		return { ok = false }
	end
	unseat(hum, root, player)
	setGroup(char, "Characters")
	to:Sit(hum)
	return { ok = hum.SeatPart == to }
end

function handlers.Door(player, door, open)
	local _, _, root = charOf(player)
	if root and typeof(door) == "Instance" and door.Parent == doorsFolder and type(open) == "boolean" and inRange(root, door) then
		setDoor(door, open)
		if not open and door:GetAttribute("BusyBy") == player.UserId then
			door:SetAttribute("BusyBy", nil)
		end
	end
	return { ok = true }
end

function handlers.Cancel(player)
	for seat, r in reservations do
		if r.player == player then
			if r.door and r.door:GetAttribute("BusyBy") == player.UserId then
				r.door:SetAttribute("BusyBy", nil)
			end
			release(seat)
		end
	end
	return { ok = true }
end

seatRemote.OnServerInvoke = function(player, action, ...)
	local h = handlers[action]
	if h then
		return h(player, ...)
	end
	return { ok = false }
end

-- Reservations expire if a client never follows through; doors left busy are freed.
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for seat, r in reservations do
		if now - r.time > RESERVE_TIMEOUT or not r.player.Parent then
			if r.door then
				r.door:SetAttribute("BusyBy", nil)
			end
			release(seat)
		end
	end
end)

local function clearPlayerDoors(player)
	for _, door in doorsFolder:GetChildren() do
		if door:GetAttribute("BusyBy") == player.UserId then
			door:SetAttribute("BusyBy", nil)
			task.delay(0.6, setDoor, door, false)
		end
	end
end

-- Arm IK on R15 drivers so other players see the hands on the wheel (the local player sees
-- their own first-person arms instead; their avatar is hidden for them).
local poles = {}
for _, side in { "L", "R" } do
	local a = chassis:FindFirstChild("ElbowPole" .. side) or Instance.new("Attachment")
	a.Name = "ElbowPole" .. side
	a.Position = (side == "L" and Vector3.new(-3.3, 1.4, -0.8) or Vector3.new(0.1, 1.4, -0.8)) * cab:GetScale()
	a.Parent = chassis
	poles[side] = a
end

local function setupIK(char, hum)
	if hum.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end
	for _, side in { "L", "R" } do
		local name = side == "L" and "Left" or "Right"
		local ik = Instance.new("IKControl")
		ik.Name = "WheelIK" .. side
		ik.Type = Enum.IKControlType.Position
		ik.ChainRoot = char:WaitForChild(name .. "UpperArm")
		ik.EndEffector = char:WaitForChild(name .. "Hand")
		ik.Target = wheel:WaitForChild("Grip" .. side)
		ik.Pole = poles[side]
		ik.Enabled = false
		ik.Parent = hum
	end
	local function refresh()
		local driving = hum.SeatPart == seatOf("DriverSeat")
		for _, ik in hum:GetChildren() do
			if ik:IsA("IKControl") and ik.Name:match("^WheelIK") then
				ik.Enabled = driving
			end
		end
	end
	hum:GetPropertyChangedSignal("SeatPart"):Connect(refresh)
	refresh()
end

-- Spawn seated (driver first) while the cab's SpawnSeated attribute isn't false.
local function spawnSeated(char, hum)
	if cab:GetAttribute("SpawnSeated") == false then
		return
	end
	char:WaitForChild("HumanoidRootPart")
	task.wait(0.4)
	if hum.Health <= 0 or hum.SeatPart then
		return
	end
	for _, name in SEAT_ORDER do
		local seat = seatOf(name)
		if seat and seatFree(seat) then
			seat:Sit(hum)
			return
		end
	end
end

local function onCharacter(player, char)
	local hum = char:WaitForChild("Humanoid")
	setGroup(char, "Characters")
	char.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = "Characters"
		end
	end)
	hum.Died:Connect(function()
		releaseAll(player)
		clearPlayerDoors(player)
	end)
	task.spawn(setupIK, char, hum)
	task.spawn(spawnSeated, char, hum)
end

local function onPlayer(player)
	player.CharacterAdded:Connect(function(char)
		onCharacter(player, char)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end
Players.PlayerAdded:Connect(onPlayer)
for _, p in Players:GetPlayers() do
	onPlayer(p)
end
Players.PlayerRemoving:Connect(function(player)
	releaseAll(player)
	clearPlayerDoors(player)
end)
