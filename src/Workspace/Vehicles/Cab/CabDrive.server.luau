-- Cab drive: a heavy early-90s rear-drive V8 sedan.
-- Each wheel hangs off a Strut (Suspension folder) that slides on a PrismaticConstraint and sits on a
-- soft SpringConstraint, so body roll, brake dive and launch squat come from real weight transfer.
-- A 4-speed automatic and progressive brakes drive the wheel hinge motors. Roblox physics solves it on
-- the network owner; this script only sets motor targets, so it stays smooth for a remote driver.
-- Input: DriverSeat.ThrottleFloat / SteerFloat, or the TestThrottle / TestSteer attributes when empty.
-- Publishes Speed (studs/s), RPM, Gear, Gas and Brake attributes on the cab for gauges and sound.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CabSteering = require(ReplicatedStorage:WaitForChild("CabSteering"))

local car = script.Parent
local seat = car:WaitForChild("DriverSeat")
local chassis = car:WaitForChild("Chassis")
local hinges = car:WaitForChild("Hinges")
local suspension = car:WaitForChild("Suspension")
local motors = { hinges:WaitForChild("MotorRL"), hinges:WaitForChild("MotorRR") }
local axles = { hinges:WaitForChild("AxleFL"), hinges:WaitForChild("AxleFR") }
local steerFL, steerFR = hinges:WaitForChild("SteerFL"), hinges:WaitForChild("SteerFR")
local wheels = {
	FL = car:WaitForChild("WheelFL"),
	FR = car:WaitForChild("WheelFR"),
	RL = car:WaitForChild("WheelRL"),
	RR = car:WaitForChild("WheelRR"),
}

local WHEEL_RADIUS = wheels.RL.Size.Y / 2 -- follows the cab's scale

-- any constant read through tune() can be overridden with a Tune_<NAME> attribute on the cab, for testing
local function tune(name, default)
	local v = car:GetAttribute("Tune_" .. name)
	return if v == nil then default else v
end

-- body and tyres
local GRAVITY = tune("GRAVITY", 46) -- studs/s^2 the cab is weighed with; Roblox's 196 is ~6 g at this scale and leaves no weight transfer
local RIDE_HZ = { F = tune("RIDE_HZ_F", 1.1), R = tune("RIDE_HZ_R", 1.3) } -- soft, wallowy springs
local DAMPING = { F = tune("DAMPING_F", 0.3), R = tune("DAMPING_R", 0.34) } -- fraction of critical: a lazy bounce that settles in about a second
local GRIP = { F = tune("GRIP_F", 0.8), R = tune("GRIP_R", 0.88) } -- tyre friction; the rear grips a touch more so it pushes before it spins

-- drivetrain: 4.6 V8 and a 4-speed automatic
local PEAK_TORQUE = tune("PEAK_TORQUE", 350) -- N*m
local TORQUE_CURVE = { { 0, 0.5 }, { 1500, 0.8 }, { 2500, 0.95 }, { 3200, 1 }, { 4000, 0.93 }, { 4600, 0.78 }, { 5200, 0.4 } }
local GEARS = { 2.40, 1.47, 1.00, 0.67 }
local REVERSE_GEAR = 2.2
local FINAL_DRIVE = 3.27
local IDLE_RPM, STALL_RPM, REDLINE = 650, 2000, 4800
local CONVERTER_BOOST = 1.35 -- torque multiplication while the converter slips
local TOP_SPEED, REVERSE_SPEED = 108, 20 -- studs/s
local REAL_MASS, METRES_PER_STUD = 1750, 0.292 -- turns real N*m into cab torque
local ENGINE_BRAKE = 32 -- N*m at the crank with the gas off
local ROLL_DRAG, AIR_DRAG = 0.35, 1.1e-4 -- studs/s^2, and per (studs/s)^2

-- brakes and pedals (keyboard is on/off, so the feet take a moment)
local BRAKE_DECEL = tune("BRAKE_DECEL", 30) -- studs/s^2 at full pedal, ~0.9 g
local BRAKE_FRONT = 0.64
local HOLD_SPEED = 0.8 -- below this with no pedals, the brakes hold the cab
local GAS_IN, GAS_OUT, BRAKE_IN, BRAKE_OUT = 2.2, 5, 3.5, 7

local corners = {}
for _, name in { "FL", "FR", "RL", "RR" } do
	local strut = suspension:WaitForChild("Strut" .. name)
	corners[name] = { strut = strut, spring = strut:WaitForChild("Spring"), pos = chassis.CFrame:PointToObjectSpace(strut.Position) }
end
local zFront = (corners.FL.pos.Z + corners.FR.pos.Z) / 2
local zRear = (corners.RL.pos.Z + corners.RR.pos.Z) / 2
local xLeft = (corners.FL.pos.X + corners.RL.pos.X) / 2
local xRight = (corners.FR.pos.X + corners.RR.pos.X) / 2
local wheelbase, track = zRear - zFront, xRight - xLeft

-- the cab's own mass, without riders
local carMass, sprungMass, sprungMoment = 0, 0, Vector3.zero
for _, d in car:GetDescendants() do
	if d:IsA("BasePart") and not d.Massless then
		carMass += d.Mass
		if d.AssemblyRootPart == chassis.AssemblyRootPart then
			sprungMass += d.Mass
			sprungMoment += d.Position * d.Mass
		end
	end
end
local sprungCom = chassis.CFrame:PointToObjectSpace(sprungMoment / sprungMass)
local torqueScale = carMass / (REAL_MASS * METRES_PER_STUD ^ 2)

-- springs carry the sprung mass at the chosen ride frequency, settling at the authored ride height
local frontShare = (zRear - sprungCom.Z) / wheelbase
local leftShare = (xRight - sprungCom.X) / track
for name, c in corners do
	local axle = name:sub(1, 1)
	local share = (axle == "F" and frontShare or 1 - frontShare) * (name:sub(2) == "L" and leftShare or 1 - leftShare)
	local m = sprungMass * share
	local w = 2 * math.pi * RIDE_HZ[axle]
	local k = m * w * w
	c.spring.Stiffness = k
	c.spring.Damping = 2 * DAMPING[axle] * math.sqrt(k * m)
	c.spring.FreeLength = c.spring:GetAttribute("RestLength") + GRAVITY / (w * w)
end

for name, wheel in wheels do
	local p = wheel.CurrentPhysicalProperties
	wheel.CustomPhysicalProperties = PhysicalProperties.new(p.Density, GRIP[name:sub(1, 1)], 0.05, 100, 1)
end
for _, a in axles do
	a.ActuatorType = Enum.ActuatorType.Motor
	a.MotorMaxTorque = 0
end
steerFL.AngularSpeed, steerFR.AngularSpeed = 4, 4

-- lighten every assembly of the cab (and whoever sits in it) from world gravity down to GRAVITY
local trims = {}
for _, d in car:GetDescendants() do
	if d:IsA("BasePart") and not d.Anchored and not trims[d.AssemblyRootPart] then
		local root = d.AssemblyRootPart
		local att = Instance.new("Attachment")
		att.Name = "GravityTrim"
		att.Parent = root
		local force = Instance.new("VectorForce")
		force.Name = "GravityTrim"
		force.Attachment0 = att
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.ApplyAtCenterOfMass = true
		force.Parent = root
		trims[root] = force
	end
end
local function retrim()
	local lift = workspace.Gravity - GRAVITY
	for root, force in trims do
		local goal = root.AssemblyMass * lift
		if math.abs(force.Force.Y - goal) > goal * 0.005 then
			force.Force = Vector3.new(0, goal, 0)
		end
	end
end
retrim()

local function torqueAt(rpm)
	for i = 2, #TORQUE_CURVE do
		local a, b = TORQUE_CURVE[i - 1], TORQUE_CURVE[i]
		if rpm <= b[1] then
			return a[2] + (b[2] - a[2]) * (rpm - a[1]) / (b[1] - a[1])
		end
	end
	return TORQUE_CURVE[#TORQUE_CURVE][2]
end

local wiperMotors = {}
for _, name in { "WiperL", "WiperR" } do
	local w = car:FindFirstChild(name)
	local m = w and w:FindFirstChild("WiperMotor")
	if m then
		table.insert(wiperMotors, { motor = m, base = m.C0 })
	end
end
local wiperPhase = 0

seat:GetPropertyChangedSignal("Occupant"):Connect(function()
	local hum = seat.Occupant
	local player = hum and Players:GetPlayerFromCharacter(hum.Parent)
	if chassis:CanSetNetworkOwnership() then
		chassis:SetNetworkOwner(player)
	end
end)

local steering = CabSteering.new()
local gas, brake = 0, 0
local gear, dir = 1, 1 -- dir 1 = drive, -1 = reverse
local shiftTimer, sinceShift, reverseTimer = 0, 0, 0
local rpm = IDLE_RPM
local publishTimer, trimTimer = 0, 0

RunService.Heartbeat:Connect(function(dt)
	local driver = seat.Occupant
	local throttleIn = driver and seat.ThrottleFloat or (car:GetAttribute("TestThrottle") or 0)
	local steerIn = driver and seat.SteerFloat or (car:GetAttribute("TestSteer") or 0)
	local driveSign = car:GetAttribute("DriveSign") or -1
	local speed = chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector) -- + forward

	-- rear tread speed, + forward; wheelspin shows up on the rev counter
	local spin = 0
	for _, m in motors do
		local wheel = m.Attachment1.Parent
		spin += (wheel.AssemblyAngularVelocity - chassis.AssemblyAngularVelocity):Dot(m.Attachment0.WorldAxis)
	end
	local treadSpeed = spin / #motors * driveSign * WHEEL_RADIUS

	-- W/S drive the cab, and press the brake when they oppose the way it is rolling
	local wantGas, wantBrake = 0, 0
	if throttleIn > 0.05 then
		if dir < 0 and speed < -1.5 then
			wantBrake = throttleIn
		else
			dir = 1
			wantGas = throttleIn
		end
	elseif throttleIn < -0.05 then
		if dir > 0 and speed > 1.5 then
			wantBrake = -throttleIn
		elseif dir > 0 then
			-- stopped: hold the brake a beat, then drop it into reverse
			wantBrake = 1
			reverseTimer += dt
			if reverseTimer > 0.35 then
				dir = -1
			end
		else
			wantGas = -throttleIn
		end
	end
	if throttleIn > -0.05 then
		reverseTimer = 0
	end
	gas += math.clamp(wantGas - gas, -GAS_OUT * dt, GAS_IN * dt)
	brake += math.clamp(wantBrake - brake, -BRAKE_OUT * dt, BRAKE_IN * dt)
	local hold = math.abs(throttleIn) <= 0.05 and math.abs(speed) < HOLD_SPEED

	-- automatic gearbox: shift points rise with the gas pedal, and it kicks down when floored
	if dir < 0 or math.abs(speed) < 2 then
		gear = 1
	end
	local ratio = (dir > 0 and GEARS[gear] or REVERSE_GEAR) * FINAL_DRIVE
	local wheelRpm = math.max(treadSpeed * dir, 0) / WHEEL_RADIUS * ratio * 60 / (2 * math.pi)
	sinceShift += dt
	if dir > 0 and shiftTimer <= 0 then
		local upAt = 1700 + 2700 * gas ^ 1.3
		local downAt = 1100 + 1500 * gas ^ 2
		if gear < #GEARS and wheelRpm > upAt and sinceShift > 0.8 then
			gear += 1
			shiftTimer, sinceShift = 0.3, 0
		elseif gear > 1 and wheelRpm < downAt and wheelRpm * GEARS[gear - 1] / GEARS[gear] < 4200 and sinceShift > 0.35 then
			gear -= 1
			shiftTimer, sinceShift = 0.22, 0
		end
	end

	-- engine through a slipping torque converter
	local converterRpm = IDLE_RPM + (STALL_RPM - IDLE_RPM) * gas
	local engineGoal = math.max(wheelRpm, converterRpm)
	rpm += (engineGoal - rpm) * (1 - math.exp(-8 * dt))
	local slip = 1 - math.clamp(wheelRpm / engineGoal, 0, 1)
	local crank = PEAK_TORQUE * torqueAt(rpm) * gas * (1 + (CONVERTER_BOOST - 1) * slip)
	if shiftTimer > 0 then
		shiftTimer -= dt
		crank *= 0.35
	end
	if wheelRpm > REDLINE then
		crank = 0
	end
	crank *= math.clamp(((dir > 0 and TOP_SPEED or REVERSE_SPEED) - math.abs(speed)) / 6, 0, 1)
	local coast = (1 - gas) * ENGINE_BRAKE * math.clamp(wheelRpm / 1500, 0, 1.5)
	local drag = carMass * (ROLL_DRAG + AIR_DRAG * speed * speed) * WHEEL_RADIUS
	local brakeTorque = carMass * BRAKE_DECEL * WHEEL_RADIUS * brake ^ 1.3
	local holdTorque = hold and carMass * GRAVITY * WHEEL_RADIUS or 0

	-- rear wheels: drive, or resist (engine braking + drag + rear brakes)
	local rearNet = (crank - coast) * ratio * torqueScale - drag - math.max(brakeTorque * (1 - BRAKE_FRONT), holdTorque)
	if rearNet > 0 then
		local limiter = REDLINE * 2 * math.pi / 60 / ratio -- wheel rad/s at the rev limiter
		for _, m in motors do
			m.AngularVelocity = driveSign * dir * limiter
			m.MotorMaxTorque = rearNet / 2
		end
	else
		for _, m in motors do
			m.AngularVelocity = 0
			m.MotorMaxTorque = -rearNet / 2
		end
	end
	-- front wheels roll free unless braking
	local frontBrake = math.max(brakeTorque * BRAKE_FRONT, holdTorque) / 2
	for _, a in axles do
		a.AngularVelocity = 0
		a.MotorMaxTorque = frontBrake
	end

	-- steering with Ackermann: the inside wheel turns tighter
	local delta = math.rad(steering:step(steerIn, speed, dt))
	local fl, fr = 0, 0
	if math.abs(delta) > 1e-4 then
		local radius = wheelbase / math.tan(delta) -- turn centre on the rear axle line, + = right
		fl = math.atan(wheelbase / (radius - corners.FL.pos.X))
		fr = math.atan(wheelbase / (radius - corners.FR.pos.X))
	end
	steerFL.TargetAngle = -math.deg(fl)
	steerFR.TargetAngle = -math.deg(fr)

	-- wipers sweep while on, then settle back to rest
	if car:GetAttribute("Wipers") or wiperPhase % (math.pi * 2) > 0.05 then
		wiperPhase += dt * 4
	else
		wiperPhase = 0
	end
	local sweep = (1 - math.cos(wiperPhase)) * 0.5 * math.rad(95)
	for _, w in wiperMotors do
		w.motor.C0 = w.base * CFrame.Angles(0, 0, sweep)
	end

	publishTimer += dt
	if publishTimer > 0.1 then
		publishTimer = 0
		car:SetAttribute("Speed", math.round(speed * 10) / 10)
		car:SetAttribute("RPM", math.round(rpm / 10) * 10)
		car:SetAttribute("Gear", dir < 0 and "R" or tostring(gear))
		car:SetAttribute("Gas", math.round(gas * 100) / 100)
		car:SetAttribute("Brake", math.round(brake * 100) / 100)
	end
	-- riders change the weight; keep their gravity trimmed too
	trimTimer += dt
	if trimTimer > 1 then
		trimTimer = 0
		retrim()
	end
end)
