-- Shared steering model for the cab. CabDrive steers the road wheels with it and the steering-wheel
-- visual can use the same numbers, so the wheel in your hands and the tyres on the road always agree.
-- step() takes the raw SteerFloat (-1..1) and the forward speed, and returns the road-wheel angle in
-- degrees (positive = right), the same quantity the old "steerSmoothed * limit" produced.
local CabSteering = {}
CabSteering.__index = CabSteering

CabSteering.MAX_STEER = 31 -- degrees of road-wheel lock at a crawl
CabSteering.MIN_STEER = 3 -- never less than this, even flat out
CabSteering.WHEELBASE = 10 -- studs
CabSteering.GRIP_ACCEL = 34 -- sideways studs/s^2 the speed-sensitive limit aims for (a bit past the tyres)
CabSteering.TURN_IN = 1.7 -- lock fraction per second while winding the wheel in
CabSteering.UNWIND = 2.6 -- lock fraction per second when letting go or reversing the turn
CabSteering.LAG = 0.08 -- seconds of linkage and tyre lag at a crawl
CabSteering.LAG_PER_SPEED = 0.0016 -- more lag the faster you go, so the nose turns in progressively

function CabSteering.new()
	return setmetatable({ input = 0, angle = 0 }, CabSteering)
end

-- the most lock that still holds the road at this speed
function CabSteering:limit(speed)
	local v = math.max(math.abs(speed), 1)
	local grip = math.deg(math.atan(self.WHEELBASE * self.GRIP_ACCEL / (v * v)))
	return math.clamp(grip, self.MIN_STEER, self.MAX_STEER)
end

function CabSteering:step(target, speed, dt)
	target = math.clamp(target, -1, 1)
	-- hands on a big wheel: winding in takes a moment, unwinding is quicker
	local unwinding = math.abs(target) < math.abs(self.input) or target * self.input < 0
	local rate = (unwinding and self.UNWIND or self.TURN_IN) * dt
	self.input += math.clamp(target - self.input, -rate, rate)
	local goal = self.input * self:limit(speed)
	local lag = self.LAG + math.abs(speed) * self.LAG_PER_SPEED
	self.angle += (goal - self.angle) * (1 - math.exp(-dt / lag))
	return self.angle
end

return CabSteering
