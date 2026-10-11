-- First-person body: low-poly jacket arms, leather-gloved hands with posable fingers, and a
-- seated torso and legs, placed by two-bone IK every frame. It lives under the camera, so only
-- the local player sees it; everyone else sees the real avatar.
local FPBody = {}
FPBody.__index = FPBody

local JACKET = Color3.fromRGB(36, 32, 29)
local CUFF = Color3.fromRGB(44, 40, 35)
local GLOVE = Color3.fromRGB(98, 69, 47)
local DENIM = Color3.fromRGB(35, 39, 48)
local BOOT = Color3.fromRGB(27, 22, 19)
local STEEL = Color3.fromRGB(82, 80, 74)

FPBody.UPPER_ARM = 1.1
FPBody.FOREARM = 1.05
FPBody.THIGH = 1.2
FPBody.SHIN = 1.15

local function material(name)
	local ok, m = pcall(function()
		return Enum.Material[name]
	end)
	return ok and m or Enum.Material.SmoothPlastic
end
local LEATHER, FABRIC, METAL = material("Leather"), material("Fabric"), material("Metal")

-- finger curls per pose (radians): { proximal, distal } for index..pinky, then thumb curl
local POSES = {
	grip = { f = { { -1.45, -1.5 }, { -1.5, -1.5 }, { -1.5, -1.5 }, { -1.45, -1.45 } }, thumb = 1.0 },
	handle = { f = { { -1.05, -1.15 }, { -1.1, -1.2 }, { -1.15, -1.2 }, { -1.15, -1.2 } }, thumb = 0.55 },
	point = { f = { { -0.05, -0.08 }, { -1.5, -1.55 }, { -1.5, -1.55 }, { -1.45, -1.5 } }, thumb = 0.9 },
	open = { f = { { -0.18, -0.15 }, { -0.22, -0.15 }, { -0.25, -0.18 }, { -0.3, -0.2 } }, thumb = 0.15 },
	rest = { f = { { -0.55, -0.5 }, { -0.6, -0.55 }, { -0.65, -0.6 }, { -0.7, -0.6 } }, thumb = 0.35 },
}
FPBody.POSES = POSES

-- hand-local layout: wrist at the origin, fingers toward -Z, back of the hand toward +Y
local FINGER_X = { 0.105, 0.035, -0.035, -0.105 } -- times the thumb side
local FINGER_LEN = { { 0.16, 0.15 }, { 0.17, 0.16 }, { 0.16, 0.15 }, { 0.13, 0.12 } }
local FINGER_D = { 0.078, 0.08, 0.076, 0.066 }
local KNUCKLE_Z = -0.33
FPBody.INDEX_TIP = function(thumbX)
	return Vector3.new(FINGER_X[1] * thumbX, 0, KNUCKLE_Z - FINGER_LEN[1][1] - FINGER_LEN[1][2])
end
-- where a gripped bar sits inside the curled hand
FPBody.GRIP_POINT = Vector3.new(0, -0.11, -0.3)

local CYL = CFrame.Angles(0, math.pi / 2, 0) -- turns a cylinder's X axis onto -Z

local function newPart(parent, name, size, color, mat, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = mat or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function cyl(parent, name, length, d, color, mat)
	return newPart(parent, name, Vector3.new(length, d, d), color, mat, Enum.PartType.Cylinder)
end

local function ball(parent, name, d, color, mat)
	return newPart(parent, name, Vector3.new(d, d, d), color, mat, Enum.PartType.Ball)
end

-- turns a part into an ellipsoid filling its box (times scale), so gloves read soft, not blocky
local function rounded(part, scale)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = scale
	mesh.Parent = part
	return part
end
local SEGMENT = Vector3.new(1.4, 1, 1) -- finger bones overlap end to end, like knuckles under leather

-- look along from->to without degenerating when the segment is vertical
local function segment(from, to)
	local dir = to - from
	local up = math.abs(dir.Unit.Y) > 0.98 and Vector3.zAxis or Vector3.yAxis
	return CFrame.lookAt((from + to) / 2, to, up)
end

-- Two-bone IK: returns the middle joint and the reachable end position.
function FPBody.solve(a, b, root, target, pole)
	local toT = target - root
	local d = toT.Magnitude
	local dir = d > 1e-4 and toT / d or -Vector3.zAxis
	d = math.clamp(d, math.abs(a - b) + 1e-3, a + b - 1e-3)
	local cosA = math.clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
	local sinA = math.sqrt(1 - cosA * cosA)
	local toPole = pole - root
	local bend = toPole - dir * toPole:Dot(dir)
	if bend.Magnitude < 1e-4 then
		bend = -Vector3.yAxis - dir * -dir.Y
	end
	bend = bend.Unit
	return root + dir * (a * cosA) + bend * (a * sinA), root + dir * d
end

function FPBody.new(parent)
	local self = setmetatable({}, FPBody)
	local model = Instance.new("Model")
	model.Name = "FPBody"
	model.Parent = parent
	self.model = model
	self.parts, self.cfs = {}, {}
	self.groups = { L = {}, R = {}, legs = {} }
	self.visible = { L = true, R = true, legs = true }

	local function add(group, part)
		table.insert(self.groups[group], part)
		return part
	end

	self.arms = {}
	for _, side in { "L", "R" } do
		local thumbX = side == "R" and -1 or 1
		local arm = { side = side, thumbX = thumbX, curls = {}, thumb = 0.3 }
		arm.upper = add(side, cyl(model, side .. "UpperArm", FPBody.UPPER_ARM, 0.46, JACKET, LEATHER))
		arm.shoulder = add(side, ball(model, side .. "Shoulder", 0.5, JACKET, LEATHER))
		arm.elbow = add(side, ball(model, side .. "Elbow", 0.44, JACKET, LEATHER))
		arm.fore = add(side, cyl(model, side .. "Forearm", FPBody.FOREARM - 0.1, 0.4, JACKET, LEATHER))
		arm.cuff = add(side, cyl(model, side .. "Cuff", 0.16, 0.37, CUFF, FABRIC))
		arm.wrist = add(side, rounded(cyl(model, side .. "Wrist", 0.16, 0.27, GLOVE, LEATHER), Vector3.new(1.7, 1, 1)))
		arm.palm = add(side, rounded(newPart(model, side .. "Palm", Vector3.new(0.31, 0.13, 0.3), GLOVE, LEATHER), Vector3.new(1.08, 1.3, 1.25)))
		arm.knuckles = add(side, rounded(cyl(model, side .. "Knuckles", 0.32, 0.13, GLOVE, LEATHER), Vector3.new(1.08, 1.15, 1.35)))
		arm.fingers = {}
		for i = 1, 4 do
			arm.fingers[i] = {
				add(side, rounded(cyl(model, side .. "Finger" .. i .. "a", FINGER_LEN[i][1], FINGER_D[i], GLOVE, LEATHER), SEGMENT)),
				add(side, rounded(cyl(model, side .. "Finger" .. i .. "b", FINGER_LEN[i][2], FINGER_D[i] * 0.94, GLOVE, LEATHER), SEGMENT)),
			}
			arm.curls[i] = { -0.5, -0.5 }
		end
		arm.thumbParts = {
			add(side, rounded(cyl(model, side .. "ThumbA", 0.16, 0.09, GLOVE, LEATHER), SEGMENT)),
			add(side, rounded(cyl(model, side .. "ThumbB", 0.13, 0.085, GLOVE, LEATHER), SEGMENT)),
		}
		if side == "L" then
			arm.watch = add(side, cyl(model, "Watch", 0.04, 0.15, STEEL, METAL))
		end
		self.arms[side] = arm
	end

	self.chest = add("legs", newPart(model, "Chest", Vector3.new(1.5, 1.6, 0.85), JACKET, LEATHER))
	self.lap = add("legs", newPart(model, "Lap", Vector3.new(1.45, 0.55, 1.05), DENIM, FABRIC))
	self.legs = {}
	for _, side in { "L", "R" } do
		self.legs[side] = {
			thigh = add("legs", cyl(model, side .. "Thigh", FPBody.THIGH, 0.56, DENIM, FABRIC)),
			knee = add("legs", ball(model, side .. "Knee", 0.52, DENIM, FABRIC)),
			shin = add("legs", cyl(model, side .. "Shin", FPBody.SHIN - 0.15, 0.46, DENIM, FABRIC)),
			boot = add("legs", newPart(model, side .. "Boot", Vector3.new(0.44, 0.36, 0.82), BOOT, LEATHER)),
		}
	end

	for _, group in self.groups do
		for _, p in group do
			table.insert(self.parts, p)
		end
	end
	self.index = {}
	for i, p in self.parts do
		self.index[p] = i
		self.cfs[i] = CFrame.new()
	end
	return self
end

function FPBody:_set(part, cf)
	self.cfs[self.index[part]] = cf
end

function FPBody:setVisible(group, on)
	if self.visible[group] == on then
		return
	end
	self.visible[group] = on
	for _, p in self.groups[group] do
		p.LocalTransparencyModifier = on and 0 or 1
		p.Transparency = on and 0 or 1
	end
end

-- Pose one hand and arm. wristCF is the wrist target (hand orientation included); the arm
-- reaches as far as it can toward it. Finger curls ease toward the named pose.
function FPBody:poseArm(side, shoulder, wristCF, pole, pose, dt)
	local arm = self.arms[side]
	local target = POSES[pose] or POSES.rest
	local k = 1 - math.exp(-16 * dt)
	for i = 1, 4 do
		local c = arm.curls[i]
		c[1] += (target.f[i][1] - c[1]) * k
		c[2] += (target.f[i][2] - c[2]) * k
	end
	arm.thumb += (target.thumb - arm.thumb) * k

	local elbow, wrist = FPBody.solve(FPBody.UPPER_ARM, FPBody.FOREARM, shoulder, wristCF.Position, pole)
	local hand = wristCF.Rotation + wrist
	self:_set(arm.shoulder, CFrame.new(shoulder))
	self:_set(arm.upper, segment(shoulder, elbow) * CYL)
	self:_set(arm.elbow, CFrame.new(elbow))
	local foreCF = segment(elbow, wrist)
	local foreDir = (wrist - elbow).Unit
	self:_set(arm.fore, CFrame.new(elbow + foreDir * (FPBody.FOREARM - 0.1) / 2) * foreCF.Rotation * CYL)
	self:_set(arm.cuff, CFrame.new(wrist - foreDir * 0.12) * foreCF.Rotation * CYL)
	self:_set(arm.wrist, hand * CFrame.new(0, 0, 0.02) * CYL)
	if arm.watch then
		self:_set(arm.watch, hand * CFrame.new(0, 0.12, 0.06) * CFrame.Angles(0, 0, math.pi / 2))
	end
	self:_set(arm.palm, hand * CFrame.new(0, 0, -0.17))
	self:_set(arm.knuckles, hand * CFrame.new(0, 0.01, KNUCKLE_Z + 0.02))
	for i = 1, 4 do
		local c = arm.curls[i]
		local len = FINGER_LEN[i]
		local base = hand * CFrame.new(FINGER_X[i] * arm.thumbX, 0, KNUCKLE_Z) * CFrame.Angles(c[1], 0, 0)
		self:_set(arm.fingers[i][1], base * CFrame.new(0, 0, -len[1] / 2) * CYL)
		local mid = base * CFrame.new(0, 0, -len[1]) * CFrame.Angles(c[2], 0, 0)
		self:_set(arm.fingers[i][2], mid * CFrame.new(0, 0, -len[2] / 2) * CYL)
	end
	local t = arm.thumb
	local tb = hand
		* CFrame.new(arm.thumbX * 0.15, -0.04, -0.08)
		* CFrame.Angles(0, -arm.thumbX * 0.75, 0)
		* CFrame.Angles(-0.3, 0, 0)
		* CFrame.Angles(-t * 0.35, arm.thumbX * t * 0.7, 0)
	self:_set(arm.thumbParts[1], tb * CFrame.new(0, 0, -0.08) * CYL)
	local tm = tb * CFrame.new(0, 0, -0.16) * CFrame.Angles(-t * 0.3, arm.thumbX * t * 0.5, 0)
	self:_set(arm.thumbParts[2], tm * CFrame.new(0, 0, -0.065) * CYL)
end

-- Seated torso and legs. frame: seat-aligned CFrame; hips/ankles in world space.
function FPBody:poseLegs(frame, hipCenter, shoulderCenter, ankles, kneePole)
	local up = (shoulderCenter - hipCenter).Unit
	local fwd = frame.LookVector
	local right = fwd:Cross(up).Unit
	local spine = CFrame.fromMatrix((hipCenter + shoulderCenter) / 2 + -up:Cross(right) * 0.05, right, up)
	local len = (shoulderCenter - hipCenter).Magnitude
	self.chest.Size = Vector3.new(1.5, len - 0.2, 0.85)
	self:_set(self.chest, spine)
	self:_set(self.lap, frame.Rotation + hipCenter + fwd * 0.15)
	for _, side in { "L", "R" } do
		local leg = self.legs[side]
		local hip = hipCenter + frame.RightVector * (side == "L" and -0.4 or 0.4)
		local ankle = ankles[side]
		local knee, foot = FPBody.solve(FPBody.THIGH, FPBody.SHIN, hip, ankle.Position, kneePole + (hip - hipCenter))
		self:_set(leg.thigh, segment(hip, knee) * CYL)
		self:_set(leg.knee, CFrame.new(knee))
		local shinDir = (foot - knee).Unit
		self:_set(leg.shin, CFrame.new(knee + shinDir * (FPBody.SHIN - 0.15) / 2) * segment(knee, foot).Rotation * CYL)
		self:_set(leg.boot, ankle.Rotation + foot + ankle.Rotation * Vector3.new(0, -0.08, -0.25))
	end
end

function FPBody:commit()
	workspace:BulkMoveTo(self.parts, self.cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

function FPBody:destroy()
	self.model:Destroy()
end

return FPBody
