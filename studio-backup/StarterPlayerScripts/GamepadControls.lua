-- GamepadControls: Xbox / PlayStation controller support, fed into FirstPersonController's MobileInput.
-- Left stick: walk / steer and gas.  Right stick: look.  RT gas, LT reverse, A brake (in the cab) or jump.
-- X use, B door / get out / put the handset away, LB flashlight, RB CHECK, Y swap seats, L3 run, R3 crouch.
-- D-pad: up CALL, left KICK OUT, right flip the cab, down MENU.  On the handset: A accept, X decline.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local fpc = script.Parent:WaitForChild("FirstPersonController")
local input = fpc:WaitForChild("MobileInput", 30)
if not input then
	return
end

local K = Enum.KeyCode
local PAD = Enum.UserInputType.Gamepad1
local DEAD = 0.3
local LOOK_SPEED = 900 -- mouse-delta pixels per second at full stick

local held = {}
local function hold(key, on)
	on = on == true
	if (held[key] == true) ~= on then
		held[key] = on or nil
		input:Fire("hold", key, on)
	end
end

local function menuOpen()
	return player:GetAttribute("MenuOpen") == true or player:GetAttribute("UIOpen") == true
end

RunService.RenderStepped:Connect(function(dt)
	if not UIS.GamepadEnabled then
		return
	end
	local sticks = { [K.Thumbstick1] = Vector3.zero, [K.Thumbstick2] = Vector3.zero }
	local triggers = {}
	for _, s in UIS:GetGamepadState(PAD) do
		if sticks[s.KeyCode] then
			sticks[s.KeyCode] = s.Position
		elseif s.KeyCode == K.ButtonR2 or s.KeyCode == K.ButtonL2 then
			triggers[s.KeyCode] = s.Position.Z
		end
	end
	local busy = menuOpen()
	local move = busy and Vector3.zero or sticks[K.Thumbstick1]
	hold(K.W, move.Y > DEAD or (not busy and (triggers[K.ButtonR2] or 0) > 0.2))
	hold(K.S, move.Y < -DEAD or (not busy and (triggers[K.ButtonL2] or 0) > 0.2))
	hold(K.D, move.X > DEAD)
	hold(K.A, move.X < -DEAD)
	local brake = not busy and UIS:IsGamepadButtonDown(PAD, K.ButtonA)
	hold(K.Space, brake)
	player:SetAttribute("PadBrake", brake or nil)
	local look = sticks[K.Thumbstick2]
	if not busy and look.Magnitude > 0.15 then
		-- curve the stick so small moves aim finely
		local m = (look.Magnitude - 0.15) / 0.85
		local dir = Vector2.new(look.X, -look.Y).Unit
		input:Fire("look", dir * (m * m) * LOOK_SPEED * dt)
	end
end)

local PRESS = {
	[K.ButtonX] = K.E,
	[K.ButtonR3] = K.C,
}
UIS.InputBegan:Connect(function(io, processed)
	if io.UserInputType ~= PAD or menuOpen() then
		return
	end
	if io.KeyCode == K.ButtonB then
		input:Fire("press", player:GetAttribute("PhoneOpen") and K.Q or K.F)
	elseif io.KeyCode == K.ButtonL3 then
		input:Fire("hold", K.LeftShift, true)
	elseif PRESS[io.KeyCode] and not processed then
		input:Fire("press", PRESS[io.KeyCode])
	end
end)
UIS.InputEnded:Connect(function(io)
	if io.KeyCode == K.ButtonL3 then
		input:Fire("hold", K.LeftShift, false)
	end
end)

-- a dropped controller must not leave a key held down
UIS.GamepadDisconnected:Connect(function()
	for key in held do
		input:Fire("hold", key, false)
	end
	table.clear(held)
	player:SetAttribute("PadBrake", nil)
end)
