-- Lives at Workspace.Vehicles.Cab.CabDrive (Script). Backup copy; edit in Studio.
-- Simple cab drive: rear-wheel motors + front steering servos, driven by the VehicleSeat.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local car = script.Parent
local seat = car:WaitForChild("DriverSeat")
local chassis = car:WaitForChild("Chassis")
local hinges = car:WaitForChild("Hinges")
local motors = { hinges:WaitForChild("MotorRL"), hinges:WaitForChild("MotorRR") }
local steers = { hinges:WaitForChild("SteerFL"), hinges:WaitForChild("SteerFR") }

local WHEEL_RADIUS = 1.4
local MAX_SPEED = 55 -- studs/s forward
local REVERSE_SPEED = 18
local MAX_STEER = 32 -- degrees

seat:GetPropertyChangedSignal("Occupant"):Connect(function()
	local hum = seat.Occupant
	local player = hum and Players:GetPlayerFromCharacter(hum.Parent)
	if chassis:CanSetNetworkOwnership() then
		chassis:SetNetworkOwner(player)
	end
end)

RunService.Heartbeat:Connect(function()
	local throttle = seat.Occupant and seat.ThrottleFloat or (car:GetAttribute("TestThrottle") or 0)
	local steer = seat.Occupant and seat.SteerFloat or 0
	local speed = throttle >= 0 and throttle * MAX_SPEED or throttle * REVERSE_SPEED
	local w = speed / WHEEL_RADIUS * (car:GetAttribute("DriveSign") or -1)
	for _, m in motors do
		m.AngularVelocity = w
	end
	for _, s in steers do
		s.TargetAngle = -steer * MAX_STEER
	end
end)
