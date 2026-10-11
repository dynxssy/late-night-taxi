-- One-off Studio setup (run in the Edit datamodel): gives a constraint cab sprung suspension.
-- Per corner: a Strut slides on the Chassis (PrismaticConstraint, vertical) and sits on a SpringConstraint;
-- the existing steer servo (front) or drive motor (rear) is re-attached from the Chassis to the Strut.
-- CabDrive tunes stiffness, damping and free length at runtime from the cab's mass.
local BUMP, DROOP, SPRING_TOP = 0.42, 0.6, 1.2

local function build(cab)
	local chassis = cab.Chassis
	local hinges = cab.Hinges
	local folder = cab:FindFirstChild("Suspension") or Instance.new("Folder")
	folder.Name = "Suspension"
	folder.Parent = cab
	local up = CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, Vector3.xAxis) -- attachment X axis = chassis up
	for name, hinge in { FL = hinges.SteerFL, FR = hinges.SteerFR, RL = hinges.MotorRL, RR = hinges.MotorRR } do
		assert(hinge.Attachment0.Parent == chassis, name .. " is already on a strut")
		local hub = chassis.CFrame:ToObjectSpace(hinge.Attachment0.WorldCFrame)
		local strut = Instance.new("Part")
		strut.Name = "Strut" .. name
		strut.Size = Vector3.new(0.4, 0.4, 0.4)
		strut.Transparency = 1
		strut.CanCollide, strut.CanQuery, strut.CanTouch = false, false, false
		strut.CustomPhysicalProperties = PhysicalProperties.new(40, 0.3, 0.5)
		strut.CFrame = chassis.CFrame * CFrame.new(hub.Position)
		strut.Parent = folder

		local hingeAtt = Instance.new("Attachment")
		hingeAtt.Name = "Hub"
		hingeAtt.CFrame = strut.CFrame:ToObjectSpace(hinge.Attachment0.WorldCFrame)
		hingeAtt.Parent = strut
		local old = hinge.Attachment0
		hinge.Attachment0 = hingeAtt
		old:Destroy()

		local slide0 = Instance.new("Attachment")
		slide0.Name = "Slide" .. name
		slide0.CFrame = CFrame.new(hub.Position) * up
		slide0.Parent = chassis
		local slide1 = Instance.new("Attachment")
		slide1.Name = "Slide"
		slide1.CFrame = up
		slide1.Parent = strut
		local slide = Instance.new("PrismaticConstraint")
		slide.Name = "Slide"
		slide.Attachment0, slide.Attachment1 = slide0, slide1
		slide.LimitsEnabled = true
		slide.LowerLimit, slide.UpperLimit = -DROOP, BUMP
		slide.Parent = strut

		local top = Instance.new("Attachment")
		top.Name = "SpringTop" .. name
		top.Position = hub.Position + Vector3.new(0, SPRING_TOP, 0)
		top.Parent = chassis
		local seat = Instance.new("Attachment")
		seat.Name = "SpringSeat"
		seat.Parent = strut
		local spring = Instance.new("SpringConstraint")
		spring.Name = "Spring"
		spring.Attachment0, spring.Attachment1 = top, seat
		spring.Visible = false
		spring:SetAttribute("RestLength", SPRING_TOP)
		spring.Parent = strut
	end
end

return build
