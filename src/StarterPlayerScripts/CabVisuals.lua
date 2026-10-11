-- Cab visuals every client runs: hinged door swings (with local prediction and scripted
-- overrides for the first-person sequences), sliding door glass, pedals, and the steering wheel.
-- Everything moves through Motor6D.Transform, so it is smooth at frame rate and never replicates.
local RunService = game:GetService("RunService")

local CabVisuals = {}
CabVisuals.Slammed = Instance.new("BindableEvent") -- (door, strength 0..1)

local cab = workspace:WaitForChild("Vehicles"):WaitForChild("Cab")
local chassis = cab:WaitForChild("Chassis")
local driverSeat = cab:WaitForChild("DriverSeat")
local wheelMotor = cab:WaitForChild("SteeringWheel"):WaitForChild("SteerMotor")

local SOUND_OPEN = "rbxassetid://119661318727626"
local SOUND_CLOSE = "rbxassetid://121381393291287"
local GLASS_DROP = 2.1 -- studs the window glass lowers
local GLASS_SPEED = 1.3 -- studs per second
local OPEN_K, OPEN_C = 70, 9 -- swing-open spring (slightly underdamped: bounces on the check strap)
local CLOSE_PULL = 950 -- deg/s^2 a closing door accelerates with

-- mirrored from CabDrive so the wheel turns exactly like the road wheels
local MAX_SPEED, MAX_STEER, HIGH_SPEED_STEER, STEER_RATE, WHEEL_TURNS = 55, 34, 11, 5, 3.2

local doors = {}

local function sound(parent, id, volume)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.RollOffMinDistance = 6
	s.RollOffMaxDistance = 60
	s.Parent = parent
	return s
end

local function addDoor(model)
	local skin = model:WaitForChild("Skin")
	local startOpen = model:GetAttribute("Open") == true
	doors[model] = {
		model = model,
		hinge = skin:WaitForChild("Hinge"),
		slide = skin:WaitForChild("GlassSlide"),
		angle = startOpen and (model:GetAttribute("OpenAngle") or 60) or 0,
		vel = 0,
		glass = 0,
		override = nil,
		predicted = nil,
		predictedUntil = 0,
		wasOpen = startOpen,
		openSound = sound(skin, SOUND_OPEN, 0.55),
		closeSound = sound(skin, SOUND_CLOSE, 0.8),
	}
end
for _, m in cab:WaitForChild("Doors"):GetChildren() do
	addDoor(m)
end

local function wantsOpen(st)
	if st.predicted ~= nil then
		if os.clock() < st.predictedUntil and st.predicted ~= st.model:GetAttribute("Open") then
			return st.predicted
		end
		st.predicted = nil
	end
	return st.model:GetAttribute("Open") == true
end

local function slam(st, speed)
	local strength = math.clamp(speed / 450, 0.2, 1)
	st.closeSound.Volume = 0.35 + 0.55 * strength
	st.closeSound.PlaybackSpeed = 0.95 + math.random() * 0.1
	st.closeSound:Play()
	CabVisuals.Slammed:Fire(st.model, strength)
end

local function unlatch(st)
	st.openSound.PlaybackSpeed = 0.97 + math.random() * 0.06
	st.openSound:Play()
end

-- Predict the door state locally until the server attribute catches up.
function CabVisuals.predictDoor(model, open)
	local st = doors[model]
	if st then
		st.predicted = open
		st.predictedUntil = os.clock() + 2
	end
end

-- Drive a door angle directly (degrees, signed like OpenAngle); nil hands it back to physics.
function CabVisuals.setDoorOverride(model, angle)
	local st = doors[model]
	if st then
		st.override = angle
	end
end

function CabVisuals.getDoorAngle(model)
	local st = doors[model]
	return st and st.angle or 0
end

function CabVisuals.isDoorOpen(model)
	local st = doors[model]
	return st ~= nil and (wantsOpen(st) or math.abs(st.angle) > 1)
end

local steerSmoothed = 0
local wheelAngle = 0 -- radians; positive turns the rim clockwise as the driver sees it

function CabVisuals.getWheelAngle()
	return wheelAngle
end
local pedals = {}
for _, name in { "GasPedal", "BrakePedal" } do
	local pad = cab:FindFirstChild(name)
	local motor = pad and pad:FindFirstChild("PedalPivot")
	if motor then
		pedals[name] = { motor = motor, angle = 0 }
	end
end

local function step(dt)
	dt = math.min(dt, 1 / 20)
	for _, st in doors do
		local openAngle = st.model:GetAttribute("OpenAngle") or 60
		local dir = math.sign(openAngle)
		local prev = st.angle
		if st.override then
			st.angle = st.override
			st.vel = (st.angle - prev) / dt
			if prev ~= 0 and st.angle == 0 then
				slam(st, math.abs(st.vel))
			elseif prev == 0 and st.angle ~= 0 then
				unlatch(st)
			end
		elseif wantsOpen(st) then
			if not st.wasOpen and math.abs(st.angle) < 0.5 then
				unlatch(st)
				st.vel = dir * 90
			end
			st.vel += (OPEN_K * (openAngle - st.angle) - OPEN_C * st.vel) * dt
			st.angle += st.vel * dt
		elseif st.angle ~= 0 then
			st.vel += (-dir * CLOSE_PULL - 2 * st.vel) * dt
			st.angle += st.vel * dt
			if st.angle * dir <= 0 then
				local speed = math.abs(st.vel)
				st.angle, st.vel = 0, 0
				slam(st, speed)
			end
		end
		st.wasOpen = wantsOpen(st) or st.override ~= nil and st.override ~= 0
		st.hinge.Transform = CFrame.Angles(0, math.rad(st.angle), 0)

		local glassGoal = st.model:GetAttribute("WindowOpen") and GLASS_DROP or 0
		if st.glass ~= glassGoal then
			local step = GLASS_SPEED * dt
			st.glass = st.glass < glassGoal and math.min(glassGoal, st.glass + step) or math.max(glassGoal, st.glass - step)
			st.slide.Transform = CFrame.new(0, -st.glass, 0)
		end
	end

	-- steering wheel follows the driver's input exactly like CabDrive steers the road wheels
	local steerInput = driverSeat.Occupant and driverSeat.SteerFloat or (cab:GetAttribute("TestSteer") or 0)
	steerSmoothed += (steerInput - steerSmoothed) * (1 - math.exp(-STEER_RATE * dt))
	local forwardSpeed = math.abs(chassis.CFrame:VectorToObjectSpace(chassis.AssemblyLinearVelocity).Z)
	local limit = MAX_STEER + (HIGH_SPEED_STEER - MAX_STEER) * math.clamp(forwardSpeed / MAX_SPEED, 0, 1)
	wheelAngle = math.rad(steerSmoothed * limit * WHEEL_TURNS)
	wheelMotor.Transform = CFrame.Angles(wheelAngle, 0, 0)

	local throttle = driverSeat.Occupant and driverSeat.ThrottleFloat or 0
	local goals = { GasPedal = math.max(throttle, 0) * 16, BrakePedal = math.max(-throttle, 0) * 13 }
	for name, p in pedals do
		p.angle += (goals[name] - p.angle) * (1 - math.exp(-18 * dt))
		p.motor.Transform = CFrame.Angles(math.rad(p.angle), 0, 0)
	end
end

-- runs just before the first-person camera, so hands on the wheel get this frame's angle
local lastRender = 0
RunService:BindToRenderStep("CabVisuals", Enum.RenderPriority.Camera.Value, function(dt)
	lastRender = os.clock()
	step(dt)
end)
-- a Studio window that isn't on screen never renders; keep animating for automated playtests
if RunService:IsStudio() then
	RunService.Heartbeat:Connect(function(dt)
		if os.clock() - lastRender > 0.25 then
			step(dt)
		end
	end)
end

return CabVisuals
