-- ReplicatedStorage.CharacterKit (ModuleScript)
-- Builds PS1-style rigid R15 characters from the meshes in People.fbx / Monsters.fbx.
--
-- Expected children (set up after Import 3D):
--   Data      ModuleScript  = CharacterKitData.lua (generated next to the FBX files)
--   Parts     Folder        every MeshPart from People + Monsters (M_*, F_*, RF_*, RN_*, MU_*, Acc_*)
--   Textures  Folder        every Tex_* plane from Textures.fbx (only their TextureID is used)
--
-- CharacterKit.build({rig="F", face="Face_Mae", outfit="Out_F_Nurse"}) -> Model (R15 Humanoid)
-- rig: "M" | "F" | "RF" (road figure) | "RN" (Runner) | "MU" (Mutant, long arms)
-- options: skirt=bool, hat="FlatCap"|"WoolHat"|"RainHat", cast=bool, height=studs, name=string

local Kit = {}
local Data = require(script:WaitForChild("Data")) :: any
local Parts = script:WaitForChild("Parts")
local Textures = script:WaitForChild("Textures")

-- Standing heights in studs. A default Roblox R15 avatar is about 5.3, which is
-- what the cab seats and the driver camera were built around.
Kit.HEIGHT = { M = 5.3, F = 4.95, MU = 5.3, RF = 6.1, RN = 6.5 }

-- outfits that wear the coat skirt by default
local SKIRT = {
	Out_M_Raincoat = true, Out_M_Suit = false, Out_F_RedCoat = true, Out_F_GreyCoat = true,
	Out_F_Nurse = true, Out_F_Cardigan = true, Out_F_Parka = true, Out_F_Raincoat = true,
	Out_RF_Rags = true,
}

Kit.PRESETS = {
	Linda = { rig = "F", face = "Face_Linda", outfit = "Out_F_RedCoat" },
	LindaDouble = { rig = "F", face = "Face_F_Smile", outfit = "Out_F_GreyCoat" },
	Mae = { rig = "F", face = "Face_Mae", outfit = "Out_F_Nurse" },
	MaeNight6 = { rig = "F", face = "Face_F_BlackEyes", outfit = "Out_F_Nurse" },
	Doyle = { rig = "M", face = "Face_Doyle", outfit = "Out_M_Donkey", hat = "WoolHat" },
	DoyleDrowned = { rig = "M", face = "Face_M_Changed", outfit = "Out_M_Donkey", hat = "WoolHat" },
	Tom = { rig = "M", face = "Face_Tom", outfit = "Out_M_Baker", hat = "FlatCap" },
	Priya = { rig = "F", face = "Face_Priya", outfit = "Out_F_Denim", cast = true },
	PriyaDouble = { rig = "F", face = "Face_Priya", outfit = "Out_F_Denim", cast = false },
	Helen = { rig = "F", face = "Face_F3", outfit = "Out_F_Cardigan" },
	Gerald = { rig = "M", face = "Face_M_NoPupils", outfit = "Out_M_Suit" },
	Dennis = { rig = "M", face = "Face_M2", outfit = "Out_M_Overalls" },
	DennisMutant = { rig = "MU", face = "Face_M_Mutant", outfit = "Out_M_Overalls" },
	Walker = { rig = "M", face = "Face_Faceless", outfit = "Out_M_Raincoat", hat = "RainHat" },
	WalkerF = { rig = "F", face = "Face_Faceless", outfit = "Out_F_Raincoat" },
	RoadFigure = { rig = "RF", face = "Face_RF", outfit = "Out_RF_Rags" },
	Runner = { rig = "RN", face = "Face_RN", outfit = "Out_RN_Skin" },
}

local GENERIC = {
	M = { faces = { "Face_M1", "Face_M2", "Face_M3" },
		outfits = { "Out_M_Casual", "Out_M_Suit", "Out_M_Hoodie", "Out_M_Donkey", "Out_M_Overalls" },
		hats = { "FlatCap", "WoolHat" } },
	F = { faces = { "Face_F1", "Face_F2", "Face_F3" },
		outfits = { "Out_F_RedCoat", "Out_F_GreyCoat", "Out_F_Denim", "Out_F_Cardigan", "Out_F_Parka" } },
}

-- Random generic fare. female: true/false/nil (nil = coin flip). changed: the Changed face.
function Kit.random(rng: Random?, female: boolean?, changed: boolean?): { [string]: any }
	local r = rng or Random.new()
	local rig = if female == nil then (r:NextNumber() < 0.5 and "M" or "F") elseif female then "F" else "M"
	local g = GENERIC[rig]
	local o: { [string]: any } = {
		rig = rig,
		face = g.faces[r:NextInteger(1, #g.faces)],
		outfit = g.outfits[r:NextInteger(1, #g.outfits)],
	}
	if g.hats and r:NextNumber() < 0.3 then
		o.hat = g.hats[r:NextInteger(1, #g.hats)]
	end
	if changed then
		o.face = rig == "M" and "Face_M_Changed" or "Face_F_Changed"
	end
	return o
end

local function texId(name: string?): string
	local p = name and Textures:FindFirstChild("Tex_" .. name)
	return p and (p :: any).TextureID or ""
end

local function clonePart(name: string): BasePart?
	local t = Parts:FindFirstChild(name)
	if not t then
		warn("CharacterKit: missing part " .. name)
		return nil
	end
	local p = t:Clone() :: BasePart
	p.Anchored = false
	p.CanCollide = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = true
	return p
end

function Kit.build(opts: { [string]: any }): Model
	if typeof(opts) == "string" then
		opts = Kit.PRESETS[opts]
	end
	local rig = opts.rig or "M"
	local d = Data.rigs[rig]
	local pre = rig .. "_"

	-- Work out the import frame from the template arms (Y is always up after import).
	local la = Parts[pre .. "LeftUpperArm"] :: BasePart
	local ra = Parts[pre .. "RightUpperArm"] :: BasePart
	local across = ra.Position - la.Position
	local s = across.Magnitude / (d.parts.RightUpperArm - d.parts.LeftUpperArm).Magnitude
	local right = Vector3.new(across.X, 0, across.Z).Unit
	local up = Vector3.yAxis
	local front = up:Cross(right)
	local function loc(p: Vector3): Vector3
		return Vector3.new(p.X, p.Y, -p.Z) * s
	end
	local c = d.parts.LeftUpperArm
	local origin = la.Position - (right * c.X + up * c.Y + front * c.Z) * s
	local frame = CFrame.fromMatrix(origin, right, up, -front)

	local model = Instance.new("Model")
	model.Name = opts.name or rig
	local P: { [string]: BasePart } = {}
	local faceTex, outTex = texId(opts.face), texId(opts.outfit)
	for name in d.parts do
		if name ~= "CoatSkirt" then
			local p = clonePart(pre .. name)
			if p then
				p.Name = name
				local isSkin = name == "Head" or name:sub(-4) == "Hand"
				local tid = isSkin and faceTex or outTex
				if tid ~= "" then
					(p :: any).TextureID = tid
				end
				p.Parent = model
				P[name] = p
			end
		end
	end

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.CanQuery = false
	local k = d.height * s / 5.3
	hrp.Size = Vector3.new(2, 2, 1) * k
	hrp.CFrame = frame * CFrame.new(loc(d.root))
	hrp.Parent = model
	model.PrimaryPart = hrp

	local function motor(name: string, p0: BasePart, p1: BasePart, at: Vector3)
		local j = frame * CFrame.new(loc(at))
		local m = Instance.new("Motor6D")
		m.Name = name
		m.Part0 = p0
		m.Part1 = p1
		m.C0 = p0.CFrame:ToObjectSpace(j)
		m.C1 = p1.CFrame:ToObjectSpace(j)
		m.Parent = p1
	end
	motor("Root", hrp, P.LowerTorso, d.root)
	for _, jd in d.joints do
		if P[jd[2]] and P[jd[3]] then
			motor(jd[1], P[jd[2]], P[jd[3]], jd[4])
		end
	end

	local function weld(p: BasePart, to: BasePart)
		local w = Instance.new("WeldConstraint")
		w.Part0 = to
		w.Part1 = p
		w.Parent = p
		p.Parent = model
	end
	local skirt = opts.skirt
	if skirt == nil then
		skirt = SKIRT[opts.outfit] == true
	end
	if skirt and d.parts.CoatSkirt then
		local p = clonePart(pre .. "CoatSkirt")
		if p then
			p.Name = "CoatSkirt"
			if outTex ~= "" then (p :: any).TextureID = outTex end
			weld(p, P.LowerTorso)
		end
	end
	if opts.hat then
		local t = Parts:FindFirstChild("Acc_" .. opts.hat) :: BasePart?
		if t then
			local hs = d.height / 1.78
			local neck = d.joints[1][4]
			local off = (Data.acc.hat_from_M_head[opts.hat] - Data.acc.hat_head_ref) * hs
			local p = clonePart(t.Name) :: BasePart
			p.Name = "Hat"
			p.Size *= hs
			p.CFrame = CFrame.new((frame * CFrame.new(loc(neck + off))).Position) * t.CFrame.Rotation
			if outTex ~= "" then (p :: any).TextureID = outTex end
			weld(p, P.Head)
		end
	end
	if opts.cast and rig == "F" then
		local t = Parts:FindFirstChild("Acc_WristCast") :: BasePart?
		if t then
			local p = clonePart(t.Name) :: BasePart
			p.Name = "Cast"
			-- the template already sits on the female's right wrist
			p.CFrame = t.CFrame
			weld(p, P.RightLowerArm)
		end
	end
	if rig == "RF" then
		local p = clonePart("RF_Eyes")
		if p then
			p.Name = "Eyes"
			p.Material = Enum.Material.Neon
			p.Color = Color3.fromRGB(255, 20, 10);
			(p :: any).TextureID = ""
			weld(p, P.Head)
		end
	end

	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	hum.RequiresNeck = false
	Instance.new("Animator").Parent = hum
	hum.Parent = model

	-- Scale to the wanted height, then rest the hips at the right height.
	local want = opts.height or Kit.HEIGHT[rig] or 5.3
	model:ScaleTo(want / (d.height * s))
	local footY = math.min(
		P.LeftFoot.Position.Y - P.LeftFoot.Size.Y / 2,
		P.RightFoot.Position.Y - P.RightFoot.Size.Y / 2
	)
	hum.HipHeight = hrp.Position.Y - hrp.Size.Y / 2 - footY
	model:PivotTo(CFrame.new(0, hum.HipHeight + hrp.Size.Y / 2, 0))
	return model
end

return Kit
