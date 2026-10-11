-- First-person controller: camera, movement and interaction, plus the whole cab flow: walk up,
-- pull the door open, climb in and sit, pull the door shut, drive with both hands on the wheel,
-- reach over to press buttons, slide across seats, and get back out.
-- The arms and legs you see are FPBody (local only); CabVisuals animates doors, glass and pedals.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local FPBody = require(script.Parent:WaitForChild("FPBody"))
local CabVisuals = require(script.Parent:WaitForChild("CabVisuals"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local interactRemote = remotes:WaitForChild("Interact")
local seatRemote = remotes:WaitForChild("CabSeat")
local cab = workspace:WaitForChild("Vehicles"):WaitForChild("Cab")
local chassis = cab:WaitForChild("Chassis")
local wheel = cab:WaitForChild("SteeringWheel")
local SCALE = cab:GetScale() -- cab-sized distances below are written for a scale-1 cab

local SENSITIVITY = 0.0022
local LOOK_SMOOTH = 30
local ACCEL, DECEL = 7, 9 -- how quickly movement ramps up / settles
local WALK_SPEED, SPRINT_SPEED, CROUCH_SPEED = 11, 19, 6
local BASE_FOV, SPRINT_FOV, DRIVE_FOV_KICK = 72, 80, 6
local EYE_HEIGHT, CROUCH_DROP = 1.6, 1.4
local INTERACT_RANGE, SEATED_RANGE = 7, 4.5
local ARM_REACH = 3 -- shoulder to target; a seated hand (with a lean) can't press anything farther
local SEAT_YAW_LIMIT = math.rad(130)
local SEAT_PITCH = -0.12 -- resting look while seated: a touch down, so the wheel and your hands sit in view
local NECK_TO_EYE = Vector3.new(0, 0.38, -0.22) -- the head turns about the neck, not the eyes
local EYE_FROM_SHOULDER = Vector3.new(0, 0.8, -0.05)
local SEAT_LAYOUT = { -- seat space: shoulder centre and hip centre
	Front = { shoulder = Vector3.new(0, 1.9, -0.15), hip = Vector3.new(0, 0.85, 0.35) },
	Back = { shoulder = Vector3.new(0, 1.9, 0.15), hip = Vector3.new(0, 0.85, 0.45) },
}
local ROW_PARTNER = { DriverSeat = "ShotgunSeat", ShotgunSeat = "DriverSeat", BackSeatL = "BackSeatR", BackSeatR = "BackSeatL" }
local MOVE_KEYS = { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D }

local character, humanoid, root
local charParts = {}
local yaw, pitch, targetYaw, targetPitch = 0, 0, 0, 0 -- walking: world space; seated: seat space
local mode = "walk" -- walk | seated | seq
local seat = nil
local seq = nil
local pending = false
local bobTime, bobAmount, lean, swayRoll = 0, 0, 0, 0
local crouchAlpha, landDip, fallSpeed = 0, 0, 0
local crouching, sprintHeld = false, false
local focused, focusedHit = nil, nil
local moveVector = Vector3.zero
local idleTime = 0
local shake = 0
local reachLean = Vector3.zero
local footBlend = 0
local dyn = { off = Vector3.zero, vel = Vector3.zero, acc = Vector3.zero, lastV = nil }

local function damp(rate, dt)
	return 1 - math.exp(-rate * dt)
end

local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local debugKeys = {} -- keys held by the Studio test hook at the bottom of this script
local timeScale = 1 -- the test hook can slow or freeze the frame for screenshots
local debugCam -- the test hook can park the camera elsewhere to look at the body
local function isDown(key)
	return debugKeys[key] == true or UserInputService:IsKeyDown(key)
end

local function keyAxis(pos, neg)
	return (isDown(pos) and 1 or 0) - (isDown(neg) and 1 or 0)
end

local function yawPitchOf(v)
	v = v.Unit
	return math.atan2(-v.X, -v.Z), math.asin(math.clamp(v.Y, -1, 1))
end

local function cabCF()
	return chassis.CFrame
end

local function toCab(worldPos)
	return cabCF():PointToObjectSpace(worldPos)
end

local function unwrap(a, ref)
	while a - ref > math.pi do
		a -= 2 * math.pi
	end
	while a - ref < -math.pi do
		a += 2 * math.pi
	end
	return a
end

-- HUD --------------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "FirstPersonHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")
local dot = Instance.new("Frame")
dot.AnchorPoint = Vector2.new(0.5, 0.5)
dot.Position = UDim2.fromScale(0.5, 0.5)
dot.Size = UDim2.fromOffset(4, 4)
dot.BackgroundColor3 = Color3.new(1, 1, 1)
dot.BackgroundTransparency = 0.3
dot.BorderSizePixel = 0
dot.Parent = gui
Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
local prompt = Instance.new("TextLabel")
prompt.AnchorPoint = Vector2.new(0.5, 0)
prompt.Position = UDim2.new(0.5, 0, 0.5, 18)
prompt.Size = UDim2.fromOffset(300, 24)
prompt.BackgroundTransparency = 1
prompt.Font = Enum.Font.Code
prompt.TextSize = 18
prompt.TextColor3 = Color3.new(1, 1, 1)
prompt.TextStrokeTransparency = 0.4
prompt.Text = ""
prompt.Parent = gui
local hint = prompt:Clone()
hint.Position = UDim2.new(0.5, 0, 0.82, 0)
hint.Size = UDim2.fromOffset(420, 24)
hint.TextSize = 16
hint.TextTransparency = 1
hint.TextStrokeTransparency = 1
hint.Parent = gui
local highlight = Instance.new("Highlight")
highlight.FillTransparency = 1
highlight.OutlineColor = Color3.new(1, 1, 1)
highlight.OutlineTransparency = 0.3
highlight.DepthMode = Enum.HighlightDepthMode.Occluded
highlight.Parent = gui

local hintUntil = 0
local function showHint(text, seconds)
	hint.Text = text
	hintUntil = os.clock() + (seconds or 2.5)
end

-- Body ---------------------------------------------------------------------------------------
local body = FPBody.new(camera)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera = workspace.CurrentCamera
	body.model.Parent = camera
end)
local bodyCF = CFrame.new()

-- instrument glow: a dim light only you see, so your hands on the wheel read in the dark. It hangs
-- above the wheel toward your eyes, on the seat so steering can't move it.
local glow = Instance.new("Attachment")
glow.Name = "InstrumentGlow"
glow.Parent = cab:WaitForChild("DriverSeat")
glow.WorldPosition = wheel.Position + cab:GetPivot():VectorToWorldSpace(Vector3.new(0, 0.7, 0.72) * cab:GetScale())
local glowLight = Instance.new("PointLight")
glowLight.Color = Color3.fromRGB(255, 205, 160)
glowLight.Brightness = 0.7
glowLight.Range = 2.6
glowLight.Shadows = false
glowLight.Parent = glow

local hands = {}
for _, side in { "L", "R" } do
	hands[side] = { provider = nil, from = nil, t = 1, dur = 0.3, current = nil, pose = "rest", busy = false }
end

local function shoulderPos(side)
	return bodyCF * Vector3.new(side == "L" and -0.78 or 0.78, 0, 0)
end

local function hiddenWrist(side)
	return bodyCF * CFrame.new(side == "L" and -0.55 or 0.55, -1.9, -0.1) * CFrame.Angles(-1.2, 0, 0)
end

local function setHand(side, provider, dur)
	local h = hands[side]
	h.from = bodyCF:ToObjectSpace(h.current or hiddenWrist(side))
	h.provider = provider
	h.t = 0
	h.dur = dur or 0.3
end

local function updateHand(side, dt)
	local h = hands[side]
	local target, pose
	if h.provider then
		target, pose = h.provider()
	end
	if not target then
		target, pose = hiddenWrist(side), "rest"
	end
	h.t = math.min(1, h.t + dt / h.dur)
	local t = h.t
	local a = t * t * t * (t * (t * 6 - 15) + 10)
	local from = h.from and bodyCF * h.from or target
	h.current = from:Lerp(target, a)
	h.pose = pose
	h.visible = h.provider ~= nil or h.t < 1
end

-- hand target builders (all return a wrist CFrame and a finger pose)
local GRIP_FOLLOW = math.rad(80) -- past this much lock the hands slide along the rim instead of crossing
local function wheelGrip(side)
	local att = wheel:FindFirstChild("Grip" .. side)
	local motor = wheel:FindFirstChild("SteerMotor")
	if not (att and motor and motor.Part0) then
		return nil
	end
	-- built from the joint itself so the hands match this frame's wheel angle exactly
	local angle = math.clamp(CabVisuals.getWheelAngle(), -GRIP_FOLLOW, GRIP_FOLLOW)
	local wheelCF = motor.Part0.CFrame * motor.C0 * CFrame.Angles(angle, 0, 0) * motor.C1:Inverse()
	local p = (wheelCF * att.CFrame).Position
	local n = -wheelCF.RightVector -- wheel face toward the driver
	local d = p - wheelCF.Position
	d = (d - n * d:Dot(n)).Unit -- out from the hub
	local t = d:Cross(n)
	local y = (d * 0.6 + n * 0.8).Unit
	local z = t:Cross(y).Unit
	y = z:Cross(t)
	return CFrame.fromMatrix(p, t, y, z) * CFrame.new(-FPBody.GRIP_POINT), "grip"
end

local function thighRest(side, onSeat)
	onSeat = onSeat or seat
	if not onSeat then
		return nil
	end
	local s = side == "L" and -1 or 1
	local cf = onSeat.CFrame * CFrame.new(s * 0.42, 1.36, -0.72) * CFrame.Angles(-0.2, -s * 0.18, 0)
	return cf * CFrame.new(0, 0.08, 0.3), "rest"
end

local function grabCF(side, point, palmUp)
	local dir = (point - shoulderPos(side)).Unit
	local cf = CFrame.lookAt(point, point + dir, Vector3.yAxis)
	if palmUp then
		cf *= CFrame.Angles(0, 0, math.pi)
	end
	return cf * CFrame.new(-FPBody.GRIP_POINT)
end

local function pressCF(side, point, normal, depth)
	local f = (-normal * 0.7 + (point - shoulderPos(side)).Unit * 0.3).Unit
	local up = math.abs(f.Y) > 0.9 and bodyCF.LookVector or Vector3.yAxis
	local tipAt = point + f * depth
	local cf = CFrame.lookAt(tipAt, tipAt + f, up)
	return cf * CFrame.new(-FPBody.INDEX_TIP(side == "R" and -1 or 1))
end

local function pushCF(side, point, normal)
	local f = Vector3.yAxis * 0.75 + (point - shoulderPos(side)).Unit * 0.4
	f = (f - normal * f:Dot(normal)).Unit
	return CFrame.lookAt(point, point + f, normal) * CFrame.new(0, 0.08, 0.17)
end

-- palm flat on a seat cushion, shifted toward one side of it (toward = cab x sign)
local function seatPalm(side, onSeat, toward)
	local cf = onSeat.CFrame
	local p = cf * Vector3.new(toward * onSeat.Size.X * 0.25, onSeat.Size.Y / 2 + 0.04, -0.1)
	return pushCF(side, p, cf.UpVector)
end

local function restProvider(side)
	if mode == "seated" and seat then
		if seat.Name == "DriverSeat" then
			return function()
				return wheelGrip(side)
			end
		end
		return function()
			return thighRest(side)
		end
	end
	return nil
end

local function settleHands(dur)
	for _, side in { "L", "R" } do
		if not hands[side].busy then
			setHand(side, restProvider(side), dur)
		end
	end
end

-- Character ----------------------------------------------------------------------------------
local function setCharGroup(group)
	for _, p in charParts do
		p.CollisionGroup = group
	end
end

local function seatRow(s)
	return s and SEAT_LAYOUT[s:GetAttribute("Row") or "Front"] or SEAT_LAYOUT.Front
end

local function seatEyeLocal(s) -- cab space
	return toCab((s.CFrame * CFrame.new(seatRow(s).shoulder + EYE_FROM_SHOULDER)).Position)
end

local function isCabSeat(part)
	return part and part.Parent == cab and part:GetAttribute("Door") ~= nil
end

local function seatFree(s)
	return s and not s.Occupant and s:GetAttribute("ReservedBy") == nil
end

local jumpBlocked = false
local function blockJump(on)
	if on == jumpBlocked then
		return
	end
	jumpBlocked = on
	if on then
		ContextActionService:BindActionAtPriority("CabNoJump", function()
			return Enum.ContextActionResult.Sink
		end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
	else
		ContextActionService:UnbindAction("CabNoJump")
	end
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not on)
	end
end

local function enterSeated(s, y, p)
	mode = "seated"
	seat = s
	yaw, targetYaw = y or 0, y or 0
	pitch, targetPitch = p or 0, p or 0
	dyn.lastV = nil
	blockJump(true)
	settleHands(0.45)
	showHint(s.Name == "DriverSeat" and "W/S drive   A/D steer   F get out" or "F get out", 4)
end

local function enterWalk()
	-- convert the current view into a world-space yaw so nothing snaps
	local wy, wp = yawPitchOf(camera.CFrame.LookVector)
	mode = "walk"
	seat = nil
	yaw, targetYaw, pitch, targetPitch = wy, wy, wp, wp
	blockJump(false)
	settleHands(0.3)
end

local function onCharacter(c)
	character = c
	humanoid = c:WaitForChild("Humanoid")
	root = c:WaitForChild("HumanoidRootPart")
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = WALK_SPEED
	charParts = {}
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(charParts, d)
		end
	end
	c.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			table.insert(charParts, d)
		end
	end)
	seq, pending, seat, mode = nil, false, nil, "walk"
	jumpBlocked = true
	blockJump(false)
	local _, y = root.CFrame:ToOrientation()
	yaw, targetYaw, pitch, targetPitch = y, y, 0, 0
	humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
		local sp = humanoid.SeatPart
		if seq then
			return -- sequences manage their own seat changes
		end
		if sp and mode ~= "seated" then
			enterSeated(sp, 0, SEAT_PITCH) -- spawned straight into a seat
		elseif not sp and mode == "seated" then
			enterWalk()
		end
	end)
	humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Landed then
			landDip = math.clamp(fallSpeed / 60, 0.08, 0.6)
		end
	end)
	humanoid.Died:Connect(function()
		if seq and seq.abort then
			seq.abort()
		end
	end)
	if humanoid.SeatPart then
		enterSeated(humanoid.SeatPart, 0, SEAT_PITCH)
	end
end

-- Sequences ----------------------------------------------------------------------------------
-- A sequence is a camera path in cab space (eye position, yaw, pitch) plus timed events. Mouse
-- movement still adds a little free look on top, so it never feels like control was taken away.
local function samplePath(keys, t)
	local n = #keys
	if t <= keys[1].t then
		return keys[1].pos, keys[1].yaw, keys[1].pitch
	end
	if t >= keys[n].t then
		return keys[n].pos, keys[n].yaw, keys[n].pitch
	end
	local i = 1
	while keys[i + 1].t < t do
		i += 1
	end
	local k0, k1, k2, k3 = keys[math.max(i - 1, 1)], keys[i], keys[i + 1], keys[math.min(i + 2, n)]
	local u = (t - k1.t) / (k2.t - k1.t)
	if i == 1 and i == n - 1 then
		u = smooth(u)
	elseif i == 1 then
		u = u * u * (2 - u) -- ease in from rest
	elseif i == n - 1 then
		u = u * (1 + u - u * u) -- ease out to rest
	end
	local function cr(a, b, c, d)
		return 0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u + (-a + 3 * b - 3 * c + d) * u * u * u)
	end
	return cr(k0.pos, k1.pos, k2.pos, k3.pos), cr(k0.yaw, k1.yaw, k2.yaw, k3.yaw), cr(k0.pitch, k1.pitch, k2.pitch, k3.pitch)
end

local function currentCabLook()
	return yawPitchOf(cabCF():VectorToObjectSpace(camera.CFrame.LookVector))
end

local doorJobs = {} -- door -> { from, to, t, dur, ease, done }
local function animateDoor(door, to, dur, ease, done)
	doorJobs[door] = { from = CabVisuals.getDoorAngle(door), to = to, t = 0, dur = dur, ease = ease, done = done }
end

local function serverDoor(door, open)
	CabVisuals.predictDoor(door, open)
	task.spawn(function()
		seatRemote:InvokeServer("Door", door, open)
	end)
end

local function finishDoorClose(door)
	CabVisuals.predictDoor(door, false)
	CabVisuals.setDoorOverride(door, 0)
	task.spawn(function()
		seatRemote:InvokeServer("Door", door, false)
		task.wait(0.05)
		if not doorJobs[door] then
			CabVisuals.setDoorOverride(door, nil)
		end
	end)
end

local function rayParams()
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { cab, character, camera }
	params.FilterType = Enum.RaycastFilterType.Exclude
	return params
end

local function standEyeY(localPos)
	-- eye height (cab space) of someone standing on the ground at this spot
	local world = cabCF() * localPos
	local hit = workspace:Raycast(world + Vector3.new(0, 6, 0), Vector3.new(0, -24, 0), rayParams())
	if not hit then
		return nil
	end
	local rootY = hit.Position.Y + humanoid.HipHeight + root.Size.Y / 2
	return toCab(Vector3.new(world.X, rootY + EYE_HEIGHT, world.Z)).Y
end

local function exitClear(door, standLocal)
	local s = door:GetAttribute("Side")
	local hx = door.Skin.Hinge.C0.Position.X -- the door's outer face
	local from = cabCF() * Vector3.new(hx + s * 0.25, 3.2 * SCALE, standLocal.Z - 0.6)
	local to = cabCF() * Vector3.new(standLocal.X, 3.2 * SCALE, standLocal.Z)
	return workspace:Raycast(from, to - from, rayParams()) == nil
end

local function newSeq(keys, duration)
	for i = 2, #keys do
		keys[i].yaw = unwrap(keys[i].yaw, keys[i - 1].yaw)
	end
	local s = { keys = keys, t = 0, duration = duration, events = {}, lookYaw = 0, lookPitch = 0, yaw = 0, pitch = 0, rootActive = false, cancelUntil = -1 }
	function s.at(t, fn)
		table.insert(s.events, { t = t, fn = fn })
	end
	return s
end

local function driveRoot(on)
	if not humanoid then
		return
	end
	humanoid.PlatformStand = on
	if seq then
		seq.rootActive = on
	end
	setCharGroup(on and "CharTransit" or "Characters")
end

local function outerHand(s)
	return s < 0 and "R" or "L" -- the hand nearer the car when standing at the door
end

local function innerHand(s)
	return s < 0 and "L" or "R" -- the hand nearer the door when seated
end

local function startEnter(door)
	if seq or pending or mode ~= "walk" then
		return
	end
	pending = true
	local res = seatRemote:InvokeServer("Enter", door)
	pending = false
	if not (res and res.ok) then
		showHint(res and res.reason or "Can't get in")
		return
	end
	local target = cab:FindFirstChild(res.seat)
	local s = door:GetAttribute("Side")
	local L = door:GetAttribute("Length")
	local hinge = door.Skin.Hinge.C0.Position
	local rearZ = hinge.Z + L
	local eye0 = toCab(camera.CFrame.Position)
	local yaw0, pitch0 = currentCabLook()
	local nearEye = seatEyeLocal(target)
	local A = Vector3.new(hinge.X + s * 1.45, eye0.Y, rearZ + 0.7)
	local yawA, pitchA = yawPitchOf(toCab(door.HandleOut.Position) - A)
	-- duck under the door frame on the way in
	local B = Vector3.new(hinge.X + s * 0.55, math.min((eye0.Y + nearEye.Y) / 2 + 0.25, nearEye.Y + 0.15), nearEye.Z + 0.1)
	local C = Vector3.new(nearEye.X + s * 0.85, nearEye.Y + 0.3, nearEye.Z + 0.05)
	local lean = Vector3.new(s * 0.35, -0.05, 0.05)
	local T = 2.0 -- arrival in the seat
	local keys = {
		{ t = 0, pos = eye0, yaw = yaw0, pitch = pitch0 },
		{ t = 0.5, pos = A, yaw = yawA, pitch = pitchA },
		{ t = 0.95, pos = A + Vector3.new(s * 0.2, 0, 0.15), yaw = s * math.rad(72), pitch = -0.12 },
		{ t = 1.35, pos = B, yaw = s * math.rad(80), pitch = -0.2 },
		{ t = 1.7, pos = C, yaw = s * math.rad(40), pitch = -0.1 },
		{ t = T, pos = nearEye + Vector3.new(0, 0.16, 0), yaw = 0, pitch = -0.02 },
		{ t = T + 0.15, pos = nearEye - Vector3.new(0, 0.07, 0), yaw = 0, pitch = -0.05 },
		{ t = T + 0.55, pos = nearEye + lean, yaw = -s * math.rad(48), pitch = -0.3 },
		{ t = T + 1.05, pos = nearEye + lean * 0.6, yaw = -s * math.rad(36), pitch = -0.22 },
		{ t = T + 1.4, pos = nearEye, yaw = 0, pitch = SEAT_PITCH },
	}
	local sq = newSeq(keys, T + 1.4)
	sq.cancelUntil = 0.95
	seq = sq
	mode = "seq"
	driveRoot(true)
	blockJump(true)

	local oh, ih = outerHand(s), innerHand(s)
	sq.at(0.12, function()
		hands[oh].busy = true
		setHand(oh, function()
			return grabCF(oh, door.HandleOut.Position + Vector3.new(0, -0.04, 0), true), "handle"
		end, 0.38)
	end)
	sq.at(0.55, function()
		serverDoor(door, true)
	end)
	-- swinging in, that hand steadies on the wheel (driver) or on the far side of the cushion
	sq.at(0.9, function()
		hands[oh].busy = false
		setHand(oh, function()
			if target.Name == "DriverSeat" then
				return wheelGrip(oh)
			end
			return seatPalm(oh, target, -s), "open"
		end, 0.6)
	end)
	sq.at(T - 0.15, function()
		local r = seatRemote:InvokeServer("Sit", target.Name)
		if seq ~= sq then
			return
		end
		if not (r and r.ok) then
			sq.abort("Seat taken")
			return
		end
		driveRoot(false)
		seat = target
	end)
	sq.at(T + 0.05, function()
		setHand(oh, function()
			if target.Name == "DriverSeat" then
				return wheelGrip(oh)
			end
			return thighRest(oh, target)
		end, 0.45)
	end)
	-- lean out, catch the door as it swings in, and pull it shut
	sq.at(T + 0.15, function()
		hands[ih].busy = true
		setHand(ih, function()
			local arm = door.Armrest
			return grabCF(ih, (arm.CFrame * CFrame.new(0, 0.1, 0)).Position, false), "handle"
		end, 0.4)
		animateDoor(door, s * 22, 0.45, "inout")
	end)
	sq.at(T + 0.75, function()
		animateDoor(door, 0, 0.3, "in", function()
			finishDoorClose(door)
		end)
	end)
	sq.at(T + 1.1, function()
		hands[ih].busy = false
	end)

	function sq.cancel()
		-- back out before committing: let go, swing the door shut, give control back
		seq = nil
		driveRoot(false)
		hands[oh].busy, hands[ih].busy = false, false
		task.spawn(function()
			seatRemote:InvokeServer("Cancel")
		end)
		if CabVisuals.isDoorOpen(door) then
			animateDoor(door, 0, 0.35, "in", function()
				finishDoorClose(door)
			end)
		end
		enterWalk()
	end
	function sq.abort(reason)
		seq = nil
		driveRoot(false)
		hands[oh].busy, hands[ih].busy = false, false
		doorJobs[door] = nil
		finishDoorClose(door)
		if reason then
			showHint(reason)
		end
		if humanoid and humanoid.Health > 0 and not humanoid.SeatPart then
			root.CFrame = cabCF() * CFrame.new(A - Vector3.new(0, EYE_HEIGHT, 0))
		end
		enterWalk()
	end
	function sq.finish()
		seq = nil
		if humanoid.SeatPart and isCabSeat(humanoid.SeatPart) then
			enterSeated(humanoid.SeatPart, sq.yaw + sq.lookYaw, sq.pitch + sq.lookPitch)
		else
			driveRoot(false)
			enterWalk()
		end
	end
end

local function startExit()
	if seq or pending or mode ~= "seated" or not isCabSeat(seat) then
		return
	end
	if chassis.AssemblyLinearVelocity.Magnitude > 4 then
		showHint("Stop the cab first")
		return
	end
	-- leave through this seat's door; if something blocks it, slide across to the other one
	local door = cab.Doors:FindFirstChild(seat:GetAttribute("Door"))
	local function plan(d)
		local s = d:GetAttribute("Side")
		local hinge = d.Skin.Hinge.C0.Position
		local stand = Vector3.new(hinge.X + s * 1.45, 0, hinge.Z + d:GetAttribute("Length") + 0.7)
		local y = standEyeY(stand)
		if y and exitClear(d, stand) then
			return Vector3.new(stand.X, y, stand.Z)
		end
	end
	local standA = plan(door)
	local fromSeat = seat
	local slideFrom = nil
	if not standA then
		local partner = cab:FindFirstChild(ROW_PARTNER[seat.Name])
		local other = partner and cab.Doors:FindFirstChild(partner:GetAttribute("Door"))
		local otherStand = other and seatFree(partner) and plan(other)
		if not otherStand then
			showHint("No room to get out")
			return
		end
		slideFrom, door, standA = seatEyeLocal(seat), other, otherStand
		fromSeat = partner
	end

	local s = door:GetAttribute("Side")
	local eye0 = toCab(camera.CFrame.Position)
	local yaw0, pitch0 = currentCabLook()
	local nearEye = seatEyeLocal(fromSeat)
	local lean = Vector3.new(s * 0.28, -0.05, -0.12)
	local t0 = 0
	local keys = { { t = 0, pos = eye0, yaw = yaw0, pitch = pitch0 } }
	if slideFrom then
		table.insert(keys, { t = 0.45, pos = (slideFrom + nearEye) / 2 + Vector3.new(0, 0.18, 0), yaw = -s * math.rad(15), pitch = -0.08 })
		t0 = 0.8
		table.insert(keys, { t = t0, pos = nearEye, yaw = -s * math.rad(20), pitch = -0.15 })
	end
	local B = Vector3.new(door.Skin.Hinge.C0.Position.X + s * 0.6, math.min((nearEye.Y + standA.Y) / 2 + 0.2, nearEye.Y + 0.2), nearEye.Z + 0.1)
	local C = Vector3.new(nearEye.X + s * 0.85, nearEye.Y + 0.25, nearEye.Z + 0.1)
	local rear = door.Skin.CFrame * Vector3.new(0, 1.2, door:GetAttribute("Length") / 2)
	local yawPush = yawPitchOf(toCab(rear) - standA)
	for _, k in {
		{ t = t0 + 0.32, pos = nearEye + lean, yaw = -s * math.rad(35), pitch = -0.32 },
		{ t = t0 + 0.6, pos = nearEye + lean * 1.2, yaw = -s * math.rad(55), pitch = -0.15 },
		{ t = t0 + 0.95, pos = C, yaw = -s * math.rad(80), pitch = -0.1 },
		{ t = t0 + 1.3, pos = B, yaw = -s * math.rad(88), pitch = -0.05 },
		{ t = t0 + 1.65, pos = standA, yaw = -s * math.rad(70), pitch = 0 },
		{ t = t0 + 2.05, pos = standA + Vector3.new(0, 0, 0.1), yaw = yawPush, pitch = -0.12 },
	} do
		table.insert(keys, k)
	end
	local sq = newSeq(keys, t0 + 2.05)
	sq.cancelUntil = t0 + 0.3
	seq = sq
	mode = "seq"
	if seat:IsA("VehicleSeat") then
		seat.ThrottleFloat, seat.SteerFloat = 0, 0
	end

	local oh, ih = outerHand(s), innerHand(s)
	if slideFrom then
		sq.at(0.02, function()
			setHand("L", nil, 0.3)
			setHand("R", nil, 0.3)
		end)
	end
	sq.at(t0 + 0.02, function()
		hands[ih].busy = true
		setHand(ih, function()
			return grabCF(ih, door.HandleIn.Position, false), "handle"
		end, 0.3)
	end)
	sq.at(t0 + 0.32, function()
		animateDoor(door, s * 18, 0.22, "out")
		serverDoor(door, true)
	end)
	sq.at(t0 + 0.4, function()
		setHand(ih, function()
			local trim = door.Trim
			local p = trim.CFrame * Vector3.new(0, 0.35, -door:GetAttribute("Length") * 0.05)
			local n = trim.CFrame.RightVector * -s
			return pushCF(ih, p + n * 0.05, n), "open"
		end, 0.15)
	end)
	sq.at(t0 + 0.42, function()
		local r = seatRemote:InvokeServer("Exit", door)
		if seq ~= sq then
			return
		end
		if not (r and r.ok) then
			sq.abort(r and r.reason or "Can't get out")
			return
		end
		seat = nil
		driveRoot(true)
	end)
	-- the other hand stays on the wheel or pushes off the cushion until the body is moving out
	sq.at(t0 + 0.45, function()
		if not hands[oh].busy then
			setHand(oh, function()
				if fromSeat.Name == "DriverSeat" then
					return wheelGrip(oh)
				end
				return seatPalm(oh, fromSeat, -s), "open"
			end, 0.3)
		end
	end)
	sq.at(t0 + 0.55, function()
		animateDoor(door, s * 50, 0.4, "out")
	end)
	sq.at(t0 + 0.95, function()
		hands[ih].busy = false
		setHand(ih, nil, 0.4)
		if not hands[oh].busy then
			setHand(oh, nil, 0.4)
		end
	end)
	sq.at(t0 + 1.55, function()
		hands[oh].busy = true
		setHand(oh, function()
			local post = door.FrameRear
			return grabCF(oh, post.CFrame * Vector3.new(0, -0.15 * post.Size.Y, 0), false), "handle"
		end, 0.3)
	end)
	sq.at(t0 + 1.8, function()
		animateDoor(door, 0, 0.42, "in", function()
			finishDoorClose(door)
		end)
	end)

	function sq.cancel()
		seq = nil
		hands[ih].busy, hands[oh].busy = false, false
		doorJobs[door] = nil
		CabVisuals.setDoorOverride(door, nil)
		enterSeated(seat, sq.yaw + sq.lookYaw, sq.pitch + sq.lookPitch)
	end
	function sq.abort(reason)
		seq = nil
		hands[ih].busy, hands[oh].busy = false, false
		doorJobs[door] = nil
		finishDoorClose(door)
		if reason then
			showHint(reason)
		end
		if humanoid and humanoid.SeatPart then
			enterSeated(humanoid.SeatPart, 0, SEAT_PITCH)
		else
			driveRoot(false)
			enterWalk()
		end
	end
	function sq.finish()
		seq = nil
		driveRoot(false)
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
		end
		enterWalk()
		task.delay(0.3, function()
			hands[oh].busy = false
			if mode == "walk" then
				setHand(oh, nil, 0.35)
			end
		end)
	end
end

local function startSlide(target)
	if seq or pending or mode ~= "seated" then
		return
	end
	local from = seatEyeLocal(seat)
	local to = seatEyeLocal(target)
	local yaw0, pitch0 = currentCabLook()
	local side = math.sign(to.X - from.X)
	local sq = newSeq({
		{ t = 0, pos = toCab(camera.CFrame.Position), yaw = yaw0, pitch = pitch0 },
		{ t = 0.4, pos = (from + to) / 2 + Vector3.new(0, 0.2, 0), yaw = -side * math.rad(15), pitch = -0.1 },
		{ t = 0.8, pos = to, yaw = 0, pitch = SEAT_PITCH },
	}, 0.8)
	seq = sq
	mode = "seq"
	if seat:IsA("VehicleSeat") then
		seat.ThrottleFloat, seat.SteerFloat = 0, 0
	end
	-- the leading hand plants on the next cushion and pushes the body across
	local lead = side > 0 and "R" or "L"
	setHand(lead, function()
		return seatPalm(lead, target, side), "open"
	end, 0.3)
	setHand(lead == "R" and "L" or "R", nil, 0.3)
	sq.at(0.3, function()
		local r = seatRemote:InvokeServer("Move", target.Name)
		if seq ~= sq then
			return
		end
		if not (r and r.ok) then
			sq.abort("Seat taken")
		end
	end)
	function sq.abort(reason)
		seq = nil
		if reason then
			showHint(reason)
		end
		local sp = humanoid.SeatPart
		if sp then
			enterSeated(sp, 0, SEAT_PITCH)
		else
			enterWalk()
		end
	end
	function sq.finish()
		seq = nil
		local sp = humanoid.SeatPart
		if sp and isCabSeat(sp) then
			enterSeated(sp, sq.yaw + sq.lookYaw, sq.pitch + sq.lookPitch)
		else
			enterWalk()
		end
	end
end

-- Reach out and press something: the hand leaves what it was doing, the fingertip lands on the
-- spot you looked at, the action fires at the moment of contact, and the hand goes back.
local function reachPress(side, target, part, hitPos, normal)
	local h = hands[side]
	if h.busy then
		return
	end
	h.busy = true
	local lp = part.CFrame:PointToObjectSpace(hitPos)
	local ln = part.CFrame:VectorToObjectSpace(normal)
	local start = os.clock()
	setHand(side, function()
		local t = os.clock() - start
		local press = math.clamp(1 - math.abs(t - 0.24) / 0.07, 0, 1)
		return pressCF(side, part.CFrame * lp, part.CFrame:VectorToWorldSpace(ln), -0.12 + 0.15 * press), "point"
	end, 0.2)
	task.delay(0.23, function()
		interactRemote:FireServer(target)
	end)
	task.delay(0.38, function()
		h.busy = false
		setHand(side, restProvider(side), mode == "seated" and 0.32 or 0.4)
	end)
end

-- Interaction targeting ----------------------------------------------------------------------
local function findInteractable(inst)
	while inst and inst ~= workspace do
		if inst:HasTag("Interactable") then
			return inst
		end
		inst = inst.Parent
	end
	return nil
end

local function pickHand(point)
	if mode == "seated" and seat then
		local x = seat.CFrame:PointToObjectSpace(point).X
		if seat.Name == "DriverSeat" then
			return x > -0.15 and "R" or "L"
		end
		return x > 0 and "R" or "L"
	end
	return "R"
end

local function evaluate(hit)
	local inst = hit and findInteractable(hit.Instance)
	if not inst then
		return nil
	end
	local action = inst:GetAttribute("Action")
	if action == "Door" then
		if mode == "walk" then
			local near = cab:FindFirstChild(inst:GetAttribute("Seat"))
			if not near then
				return nil
			end
			-- a door only leads to the seat behind it: nobody climbs over another rider
			if seatFree(near) then
				return inst, near.Name == "DriverSeat" and "Drive" or "Get in"
			end
		elseif mode == "seated" and hit.Instance.Name == "HandleIn" and inst:GetAttribute("Seat") == seat.Name then
			return inst, "Get out"
		end
		return nil
	elseif action == "Seat" then
		if mode == "seated" and inst ~= seat and inst:GetAttribute("Row") == seat:GetAttribute("Row") and seatFree(inst) then
			return inst, "Slide over"
		end
		return nil
	end
	if mode == "seated" then
		local side = pickHand(hit.Position)
		if (hit.Position - shoulderPos(side)).Magnitude > ARM_REACH then
			return nil
		end
	end
	return inst, inst:GetAttribute("Prompt") or inst.Name
end

local function activate()
	if seq or pending or not focused then
		return
	end
	local inst, hit = focused, focusedHit
	local action = inst:GetAttribute("Action")
	if action == "Door" then
		if mode == "walk" then
			task.spawn(startEnter, inst)
		else
			startExit()
		end
	elseif action == "Seat" then
		startSlide(inst)
	elseif hit then
		reachPress(pickHand(hit.Position), inst, hit.Instance, hit.Position, hit.Normal)
	end
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

local function onPress(input)
	if seq then
		local cancelKey = input.KeyCode == Enum.KeyCode.F or table.find(MOVE_KEYS, input.KeyCode)
		if cancelKey and seq.cancel and seq.t < seq.cancelUntil then
			seq.cancel()
		end
		return
	end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintHeld = true
	elseif input.KeyCode == Enum.KeyCode.C or input.KeyCode == Enum.KeyCode.LeftControl then
		crouching = not crouching
	elseif input.KeyCode == Enum.KeyCode.E or input.UserInputType == Enum.UserInputType.MouseButton1 then
		activate()
	elseif input.KeyCode == Enum.KeyCode.F then
		if mode == "seated" then
			startExit()
		elseif focused and focused:GetAttribute("Action") == "Door" then
			activate()
		end
	end
end
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed then
		onPress(input)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintHeld = false
	end
end)

CabVisuals.Slammed.Event:Connect(function(_, strength)
	if mode ~= "walk" or (root and (root.Position - chassis.Position).Magnitude < 9) then
		shake = math.max(shake, strength * (mode == "walk" and 0.4 or 1))
		dyn.vel += Vector3.new(0, -0.6, 0) * strength
	end
end)

-- Frame --------------------------------------------------------------------------------------
local EASE = {
	inout = smooth,
	["in"] = function(t)
		return t * t
	end,
	out = function(t)
		return 1 - (1 - t) * (1 - t)
	end,
}

local function updateDoorJobs(dt)
	for door, j in doorJobs do
		j.t = math.min(1, j.t + dt / j.dur)
		CabVisuals.setDoorOverride(door, j.from + (j.to - j.from) * EASE[j.ease](j.t))
		if j.t >= 1 then
			doorJobs[door] = nil
			if j.done then
				j.done()
			end
		end
	end
end

local function updateDynamics(dt)
	local v = chassis.CFrame:VectorToObjectSpace(chassis.AssemblyLinearVelocity)
	dyn.lastV = dyn.lastV or v
	local a = (v - dyn.lastV) / math.max(dt, 1 / 240)
	dyn.lastV = v
	dyn.acc = dyn.acc:Lerp(a, damp(9, dt))
	local force = Vector3.new(-dyn.acc.X * 0.004, -dyn.acc.Y * 0.0025, -dyn.acc.Z * 0.0045)
	if force.Magnitude > 0.3 then
		force = force.Unit * 0.3
	end
	dyn.vel += ((force - dyn.off) * 110 - dyn.vel * 15) * dt
	dyn.off += dyn.vel * dt
	if dyn.off.Magnitude > 0.35 then
		dyn.off = dyn.off.Unit * 0.35
	end
	return v
end

local function frame(dt)
	if not (root and humanoid and humanoid.Health > 0 and root.Parent) then
		return
	end
	dt = math.min(dt, 1 / 15) * timeScale
	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
	updateDoorJobs(dt)

	local delta = UserInputService:GetMouseDelta()
	swayRoll += (math.clamp(-delta.X * 0.0005, -0.015, 0.015) - swayRoll) * damp(10, dt)
	idleTime += dt
	local eye, rot
	local fovGoal = BASE_FOV
	local cabRot = cabCF().Rotation

	if seq then
		local sq = seq
		sq.t += dt
		for _, e in sq.events do
			if not e.done and sq.t >= e.t then
				e.done = true
				task.spawn(e.fn)
			end
		end
		if seq ~= sq then
			return -- an event ended it this frame
		end
		local pos, y, p = samplePath(sq.keys, sq.t)
		if delta.Magnitude > 0 then
			sq.lookYaw = math.clamp(sq.lookYaw - delta.X * SENSITIVITY, -0.6, 0.6)
			sq.lookPitch = math.clamp(sq.lookPitch - delta.Y * SENSITIVITY, -0.4, 0.4)
		else
			sq.lookYaw *= math.exp(-1.2 * dt)
			sq.lookPitch *= math.exp(-1.2 * dt)
		end
		sq.yaw, sq.pitch = y, p
		eye = cabCF() * pos
		rot = cabRot * CFrame.Angles(0, y + sq.lookYaw, 0) * CFrame.Angles(math.clamp(p + sq.lookPitch, -1.4, 1.4), 0, 0)
		bodyCF = CFrame.new(eye) * cabRot * CFrame.Angles(0, y, 0) * CFrame.new(-EYE_FROM_SHOULDER)
		if sq.rootActive then
			root.CFrame = CFrame.new(eye - cabRot.UpVector * EYE_HEIGHT) * cabRot * CFrame.Angles(0, y, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
		if sq.t >= sq.duration then
			sq.finish()
		end
		body:setVisible("legs", false)
	elseif mode == "seated" and seat and seat.Parent then
		targetYaw = math.clamp(targetYaw - delta.X * SENSITIVITY, -SEAT_YAW_LIMIT, SEAT_YAW_LIMIT)
		targetPitch = math.clamp(targetPitch - delta.Y * SENSITIVITY, -1.3, 1.2)
		local a = damp(LOOK_SMOOTH, dt)
		yaw += (targetYaw - yaw) * a
		pitch += (targetPitch - pitch) * a

		local v = updateDynamics(dt)
		local speed = v.Magnitude
		local seatCF = seat.CFrame
		local layout = seatRow(seat)
		-- lean toward whatever a hand is reaching for
		local leanGoal = Vector3.zero
		for _, side in { "L", "R" } do
			local h = hands[side]
			if h.busy and h.current then
				local toT = h.current.Position - shoulderPos(side)
				leanGoal += toT.Unit * math.clamp(toT.Magnitude - 1.75, 0, 0.55)
			end
		end
		reachLean += (leanGoal - reachLean) * damp(7, dt)
		local sway = seatCF:VectorToWorldSpace(dyn.off) + reachLean
		local rumble = math.clamp(speed / 55, 0, 1)
		sway += seatCF.UpVector * math.noise(idleTime * 13, 0.5) * 0.012 * rumble
		bodyCF = seatCF * CFrame.new(layout.shoulder) + sway
		local neck = bodyCF * (EYE_FROM_SHOULDER - NECK_TO_EYE)
		-- looking far over a shoulder shifts the head that way, like leaning to check the back seat
		local turn = math.sin(yaw) * math.clamp((math.abs(yaw) - 0.9) / 1.2, 0, 1)
		neck += seatCF.RightVector * (-turn * 0.32)
		rot = seatCF.Rotation
			* CFrame.Angles(0, yaw, 0)
			* CFrame.Angles(pitch + dyn.off.Z * 0.06, 0, 0)
			* CFrame.Angles(0, 0, -dyn.off.X * 0.12 + swayRoll * 0.5)
		eye = neck + rot * NECK_TO_EYE
		fovGoal = BASE_FOV + DRIVE_FOV_KICK * rumble

		if seat:IsA("VehicleSeat") then
			local throttle = keyAxis(Enum.KeyCode.W, Enum.KeyCode.S) + keyAxis(Enum.KeyCode.Up, Enum.KeyCode.Down)
			local steer = keyAxis(Enum.KeyCode.D, Enum.KeyCode.A) + keyAxis(Enum.KeyCode.Right, Enum.KeyCode.Left)
			if UserInputService:GetFocusedTextBox() then
				throttle, steer = 0, 0
			end
			seat.ThrottleFloat = math.clamp(throttle, -1, 1)
			seat.SteerFloat = math.clamp(steer, -1, 1)
		end

		-- seated legs: feet on the floor, the driver's right foot works the pedals
		body:setVisible("legs", true)
		local ankles = {}
		local footRot = seatCF.Rotation * CFrame.Angles(-0.35, 0, 0)
		ankles.L = footRot + (seatCF * Vector3.new(-0.42, -0.12, -1.62))
		if seat.Name == "DriverSeat" then
			local braking = seat.ThrottleFloat < -0.05
			footBlend += ((braking and 1 or 0) - footBlend) * damp(14, dt)
			local gas = cab:FindFirstChild("GasPedal")
			local brake = cab:FindFirstChild("BrakePedal")
			local gp = gas and (gas.CFrame * Vector3.new(0, 0.12, 0.2)) or (seatCF * Vector3.new(0.35, -0.1, -1.75))
			local bp = brake and (brake.CFrame * Vector3.new(0, 0.12, 0.2)) or gp
			local lift = math.sin(footBlend * math.pi) * 0.18
			ankles.R = (seatCF.Rotation * CFrame.Angles(-0.55, 0, 0)) + gp:Lerp(bp, footBlend) + seatCF.UpVector * lift
		else
			ankles.R = footRot + (seatCF * Vector3.new(0.42, -0.12, -1.62))
		end
		body:poseLegs(seatCF, seatCF * layout.hip + sway * 0.4, bodyCF.Position, ankles, seatCF * Vector3.new(0, 2.6, -1.6))
	else
		-- walking
		if mode ~= "walk" then
			enterWalk()
		end
		targetYaw -= delta.X * SENSITIVITY
		targetPitch = math.clamp(targetPitch - delta.Y * SENSITIVITY, -1.45, 1.45)
		local a = damp(LOOK_SMOOTH, dt)
		yaw += (targetYaw - yaw) * a
		pitch += (targetPitch - pitch) * a

		local input = Vector3.new(keyAxis(Enum.KeyCode.D, Enum.KeyCode.A), 0, keyAxis(Enum.KeyCode.S, Enum.KeyCode.W))
		if UserInputService:GetFocusedTextBox() then
			input = Vector3.zero
		end
		local wish = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(input)
		if wish.Magnitude > 1 then
			wish = wish.Unit
		end
		moveVector = moveVector:Lerp(wish, damp(wish.Magnitude > 0.05 and ACCEL or DECEL, dt))
		humanoid:Move(moveVector, false)

		local velocity = root.AssemblyLinearVelocity
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		if not grounded then
			fallSpeed = math.max(0, -velocity.Y)
		end
		local moving = grounded and speed > 0.5
		local sprinting = sprintHeld and not crouching and moving and humanoid.MoveDirection.Magnitude > 0
		local targetSpeed = crouching and CROUCH_SPEED or (sprinting and SPRINT_SPEED or WALK_SPEED)
		humanoid.WalkSpeed += (targetSpeed - humanoid.WalkSpeed) * damp(6, dt)
		bobAmount += ((moving and math.min(speed / WALK_SPEED, 1.6) or 0) - bobAmount) * damp(8, dt)
		bobTime += dt * (moving and (6 + speed * 0.35) or 0)
		local localVel = root.CFrame:VectorToObjectSpace(velocity)
		lean += (-localVel.X / SPRINT_SPEED * 0.035 - lean) * damp(6, dt)
		crouchAlpha += ((crouching and 1 or 0) - crouchAlpha) * damp(10, dt)
		landDip *= math.exp(-7 * dt)

		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
		local yawRot = CFrame.Angles(0, yaw, 0)
		-- vertical-only bob (no side-to-side wiggle) plus a slow idle breath
		local breath = math.sin(idleTime * 1.6) * 0.02 * (1 - math.min(bobAmount, 1))
		local bobY = (math.cos(bobTime * 2) - 1) * 0.045 * bobAmount + breath
		local headY = EYE_HEIGHT - crouchAlpha * CROUCH_DROP - landDip + bobY
		local neck = root.Position + Vector3.new(0, headY, 0) - yawRot * Vector3.new(0, NECK_TO_EYE.Y, NECK_TO_EYE.Z)
		rot = yawRot * CFrame.Angles(pitch, 0, 0) * CFrame.Angles(0, 0, lean + swayRoll)
		eye = neck + rot * NECK_TO_EYE
		bodyCF = CFrame.new(root.Position + Vector3.new(0, headY, 0)) * yawRot * CFrame.new(-EYE_FROM_SHOULDER)
		fovGoal = sprinting and SPRINT_FOV or BASE_FOV
		body:setVisible("legs", false)
	end

	-- door slams and bumps give a short shake
	shake *= math.exp(-9 * dt)
	local shakeRot = CFrame.identity
	if shake > 0.01 then
		shakeRot = CFrame.Angles(math.noise(idleTime * 31, 1) * 0.02 * shake, math.noise(idleTime * 29, 2) * 0.015 * shake, math.noise(idleTime * 27, 3) * 0.02 * shake)
	end
	camera.CFrame = debugCam or CFrame.new(eye) * rot * shakeRot
	camera.FieldOfView += (fovGoal - camera.FieldOfView) * damp(5, dt)

	-- hide the real avatar from its own player
	for _, p in charParts do
		p.LocalTransparencyModifier = 1
	end

	-- arms
	for _, side in { "L", "R" } do
		updateHand(side, dt)
		local h = hands[side]
		body:setVisible(side, h.visible)
		if h.visible then
			local s = side == "L" and -1 or 1
			body:poseArm(side, shoulderPos(side), h.current, bodyCF * Vector3.new(s * 1.4, -1.6, 0.7), h.pose, dt)
		end
	end
	body:commit()

	local hintAlpha = math.clamp((hintUntil - os.clock()) / 0.5, 0, 1)
	hint.TextTransparency = 1 - hintAlpha
	hint.TextStrokeTransparency = 1 - hintAlpha * 0.6

	-- interact raycast
	if seq then
		focused, focusedHit = nil, nil
		highlight.Adornee = nil
		prompt.Text = ""
		dot.Visible = false
		return
	end
	dot.Visible = true
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { character, camera }
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.CollisionGroup = "Characters" -- the cab shell only collides with characters, so rays must too
	local range = mode == "seated" and SEATED_RANGE or INTERACT_RANGE
	local hit = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * range, params)
	local target, text = evaluate(hit)
	focused, focusedHit = target, target and hit or nil
	highlight.Adornee = target
	prompt.Text = target and ("[E] " .. text) or ""
	dot.Size = target and UDim2.fromOffset(8, 8) or UDim2.fromOffset(4, 4)
end

local lastRender = 0
RunService:BindToRenderStep("FirstPersonController", Enum.RenderPriority.Camera.Value + 1, function(dt)
	lastRender = os.clock()
	frame(dt)
end)

-- Studio test hook ---------------------------------------------------------------------------
-- Lets automated playtests drive the controller. A Studio window that isn't on screen never
-- renders, so frames fall back to Heartbeat there; FPDebug aims the view, presses or holds keys
-- and reports state. None of this exists in a live game.
if RunService:IsStudio() then
	RunService.Heartbeat:Connect(function(dt)
		if os.clock() - lastRender > 0.25 then
			frame(dt)
		end
	end)
	local hook = Instance.new("BindableFunction")
	hook.Name = "FPDebug"
	hook.OnInvoke = function(cmd, a, b)
		if cmd == "aim" then
			for _ = 1, 3 do
				local d = a - camera.CFrame.Position
				if mode == "seated" and seat then
					d = seat.CFrame:VectorToObjectSpace(d)
				end
				local y, p = yawPitchOf(d)
				targetYaw, targetPitch, yaw, pitch = y, p, y, p
				frame(1 / 60)
			end
		elseif cmd == "press" then
			onPress({ KeyCode = Enum.KeyCode[a], UserInputType = Enum.UserInputType.Keyboard })
		elseif cmd == "hold" then
			debugKeys[Enum.KeyCode[a]] = b == true or nil
		elseif cmd == "teleport" then
			root.CFrame = a
		elseif cmd == "timescale" then
			timeScale = a
		elseif cmd == "camera" then
			debugCam = a
		end
		local s = {
			mode = mode,
			seat = seat and seat.Name,
			seatPart = humanoid and humanoid.SeatPart and humanoid.SeatPart.Name,
			seqT = seq and seq.t,
			seqDur = seq and seq.duration,
			eye = toCab(camera.CFrame.Position),
			look = cabCF():VectorToObjectSpace(camera.CFrame.LookVector),
			root = root and toCab(root.Position),
			focus = focused and focused.Name,
			prompt = prompt.Text,
			hint = hintUntil > os.clock() and hint.Text or nil,
		}
		for _, side in { "L", "R" } do
			local h = hands[side]
			s["hand" .. side] = h.current and toCab(h.current.Position)
			s["vis" .. side] = h.visible
			s["pose" .. side] = h.pose
		end
		for _, d in cab.Doors:GetChildren() do
			s[d.Name] = math.round(CabVisuals.getDoorAngle(d))
		end
		return s
	end
	hook.Parent = script
end
