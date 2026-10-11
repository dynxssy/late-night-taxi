-- First-person body: low-poly jacket arms, leather-gloved hands with posable fingers, and a
-- seated torso and legs, placed by two-bone IK every frame. It lives under the camera, so only
-- the local player sees it; everyone else sees the real avatar.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
FPBody.THIGH = 1.45
FPBody.SHIN = 1.35

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
	local template = FPBody.armsTemplate()
	if template then
		self:_buildSkin(template)
	end
	for _, side in { "L", "R" } do
		local thumbX = side == "R" and -1 or 1
		local arm = { side = side, thumbX = thumbX, curls = {}, thumb = 0.3 }
		for i = 1, 4 do
			arm.curls[i] = { -0.5, -0.5 }
		end
		self.arms[side] = arm
		if self.skin then
			continue
		end
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
		end
		arm.thumbParts = {
			add(side, rounded(cyl(model, side .. "ThumbA", 0.16, 0.09, GLOVE, LEATHER), SEGMENT)),
			add(side, rounded(cyl(model, side .. "ThumbB", 0.13, 0.085, GLOVE, LEATHER), SEGMENT)),
		}
		if side == "L" then
			arm.watch = add(side, cyl(model, "Watch", 0.04, 0.15, STEEL, METAL))
		end
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
	if self.skin then
		self:_poseSkin(side, arm, shoulder, elbow, wrist, hand, pole)
		return
	end
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

-- Skinned arms ------------------------------------------------------------------------------
-- The user's PS1 arms model (ReplicatedStorage.Assets.FPArms): one skinned mesh with both arms.
-- Its bones follow the same IK as the part arms: the upper arm and forearm aim down the solved
-- segments and roll with the elbow hinge, the hand takes the wrist target, and the finger bones
-- curl about the hand's knuckle axis. Without the asset the part arms above are used.

local TWIST = 0.6 -- how much of the hand's roll the forearm carries (the rest twists at the wrist)
local HIDDEN = Vector3.new(0, -60, 0) -- a hidden arm is parked under the ground

function FPBody.armsTemplate()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local model = assets and assets:FindFirstChild("FPArms")
	return model and model:FindFirstChildWhichIsA("MeshPart", true)
end

local function signedAngle(a, b, axis)
	return math.atan2(a:Cross(b):Dot(axis), a:Dot(b))
end

-- rotation taking local (0,1,0) onto dir and the local hinge onto the world hinge, at pos
local function aim(pos, dir, hinge, hingeLocal)
	local h = hinge - dir * hinge:Dot(dir)
	if h.Magnitude < 1e-4 then
		h = dir:Cross(Vector3.xAxis)
	end
	h = h.Unit
	local y = Vector3.yAxis
	return CFrame.fromMatrix(pos, dir, h, dir:Cross(h)) * CFrame.fromMatrix(Vector3.zero, y, hingeLocal, y:Cross(hingeLocal)):Inverse()
end

-- turn a frame by the smallest rotation that points its Y along dir
local function swing(cf, dir)
	local y = cf.UpVector
	local axis = y:Cross(dir)
	if axis.Magnitude < 1e-5 then
		return cf
	end
	return CFrame.fromAxisAngle(axis.Unit, math.atan2(axis.Magnitude, y:Dot(dir))) * cf
end

function FPBody:_buildSkin(template)
	local mesh = template:Clone()
	mesh.Anchored = true
	mesh.CanCollide, mesh.CanQuery, mesh.CanTouch = false, false, false
	mesh.Parent = self.model
	self.mesh = mesh

	-- rest pose of every bone in mesh space
	local rest = {}
	local function walk(parent, parentCF)
		for _, b in parent:GetChildren() do
			if b:IsA("Bone") then
				rest[b] = parentCF * b.CFrame
				walk(b, rest[b])
			end
		end
	end
	walk(mesh, CFrame.identity)

	self.skin = {}
	local tips, grips = {}, {}
	for _, side in { "L", "R" } do
		local thumbX = side == "R" and -1 or 1
		local function bone(name)
			return mesh:FindFirstChild(name .. "." .. side, true)
		end
		local upper, fore, hand = bone("upper_arm"), bone("forearm"), bone("hand")
		local index = { bone("f_index.01"), bone("f_index.02"), bone("f_index.03") }
		local ring = { bone("f_ring.01"), bone("f_ring.02"), bone("f_ring.03") }
		local thumb = { bone("thumb.01"), bone("thumb.02"), bone("thumb.03") }

		-- the hand frame the IK works in: wrist at the origin, fingers toward -Z, back of the hand
		-- toward +Y, thumb side toward +X * thumbX
		local wrist = rest[hand].Position
		local k1, k2 = rest[index[1]].Position, rest[ring[1]].Position
		local F = ((k1 + k2) / 2 - wrist).Unit
		local T = k1 - k2
		T = (T - F * T:Dot(F)).Unit
		local X, Z = T * thumbX, -F
		local frame = CFrame.fromMatrix(wrist, X, Z:Cross(X), Z)

		-- the elbow bends about the model's side-to-side axis
		local function hingeLocal(b)
			local y = rest[b].UpVector
			local h = (Vector3.xAxis - y * y.X).Unit
			return rest[b]:VectorToObjectSpace(h)
		end

		-- finger joints: bone, curl axis in bone space, rest bend from the previous segment
		local function chain(bones, axis, from)
			local out = {}
			local prev = from
			for i, b in bones do
				local y = rest[b].UpVector
				out[i] = { bone = b, axis = rest[b]:VectorToObjectSpace(axis).Unit, rest = signedAngle(prev, y, axis) }
				prev = y
			end
			return out
		end

		self.skin[side] = {
			upper = upper,
			fore = fore,
			hand = hand,
			upperHinge = hingeLocal(upper),
			foreHinge = hingeLocal(fore),
			handOffset = frame:Inverse() * rest[hand],
			handToFore = rest[hand]:Inverse() * rest[fore],
			index = chain(index, X, F),
			ring = chain(ring, X, F),
			thumb = chain(thumb, F * thumbX, rest[thumb[1]].UpVector),
		}

		-- fingertip and grip points in the hand frame
		-- the point pose holds the index nearly straight; the last bone is about 0.8 of the middle one
		local reach = index[2].Position.Magnitude + index[3].Position.Magnitude * 1.8
		tips[side] = frame:PointToObjectSpace(k1) + Vector3.new(0, 0, -reach)
		grips[side] = frame:PointToObjectSpace((k1 + k2) / 2)
	end

	FPBody.UPPER_ARM = self.skin.L.fore.Position.Magnitude
	FPBody.FOREARM = self.skin.L.hand.Position.Magnitude
	FPBody.INDEX_TIP = function(thumbX)
		return tips[thumbX == -1 and "R" or "L"]
	end
	local g = (grips.L + grips.R) / 2
	FPBody.GRIP_POINT = Vector3.new(0, g.Y - 0.12, g.Z + 0.04)
end

function FPBody:_poseSkin(side, arm, shoulder, elbow, wrist, hand, pole)
	local skin = self.skin[side]
	local up = (elbow - shoulder).Unit
	local fd = (wrist - elbow).Unit
	-- the bend plane comes from the pole, like the IK, so a straight arm doesn't spin
	local d = wrist - shoulder
	d = d.Magnitude > 1e-4 and d.Unit or up
	local e = pole - shoulder
	e -= d * e:Dot(d)
	local n = e.Magnitude > 1e-4 and e.Unit:Cross(d) or up:Cross(fd)

	local handCF = hand * skin.handOffset
	local fromHinge = aim(elbow, fd, n, skin.foreHinge)
	local fromHand = swing((handCF * skin.handToFore).Rotation, fd) + elbow
	skin.world = {
		upper = aim(shoulder, up, n, skin.upperHinge),
		fore = fromHinge:Lerp(fromHand, TWIST),
		hand = handCF,
	}
	skin.curls, skin.thumbCurl = arm.curls, arm.thumb
end

local function curl(joints, angles)
	for i, j in joints do
		j.bone.Transform = CFrame.fromAxisAngle(j.axis, angles[i] - j.rest)
	end
end

function FPBody:_commitSkin()
	local skinL, skinR = self.skin.L, self.skin.R
	-- keep the mesh itself near the shoulders so it never culls away
	local anchor = (skinL.world and skinL.world.upper.Position) or (skinR.world and skinR.world.upper.Position)
	if anchor then
		self.mesh.CFrame = CFrame.new(anchor)
	end
	local base = self.mesh.CFrame
	local shown = false
	for _, side in { "L", "R" } do
		local skin = self.skin[side]
		local w = skin.world
		if not (self.visible[side] and w) then
			skin.upper.Transform = CFrame.new((base * skin.upper.CFrame):VectorToObjectSpace(HIDDEN))
			continue
		end
		shown = true
		skin.upper.Transform = (base * skin.upper.CFrame):Inverse() * w.upper
		skin.fore.Transform = (w.upper * skin.fore.CFrame):Inverse() * w.fore
		skin.hand.Transform = (w.fore * skin.hand.CFrame):Inverse() * w.hand
		local c = skin.curls
		-- the model has an index finger and the other three fingers as one
		local ringA = (c[2][1] + c[3][1] + c[4][1]) / 3
		local ringB = (c[2][2] + c[3][2] + c[4][2]) / 3
		curl(skin.index, { c[1][1], c[1][2] * 0.55, c[1][2] * 0.45 })
		curl(skin.ring, { ringA, ringB * 0.55, ringB * 0.45 })
		local t = skin.thumbCurl - 0.3
		curl(skin.thumb, { skin.thumb[1].rest + t * 0.5, skin.thumb[2].rest + t * 0.6, skin.thumb[3].rest + t * 0.6 })
	end
	self.mesh.LocalTransparencyModifier = shown and 0 or 1
end

function FPBody:commit()
	workspace:BulkMoveTo(self.parts, self.cfs, Enum.BulkMoveMode.FireCFrameChanged)
	if self.skin then
		self:_commitSkin()
	end
end

function FPBody:destroy()
	self.model:Destroy()
end

return FPBody
