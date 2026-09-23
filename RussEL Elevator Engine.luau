--------------------------------------------------------------------
-- RussEL Elevator Engine
-- Server-side controller for the "RussEL Elevator 1.0" model.
--
-- Drives the shared root values that every embedded script reads:
--   Floor (IntValue)         - current floor, updated as the car passes levels
--   Direction (StringValue) - "U"/"D" while travelling, "N" when stopped
--   UD (StringValue)        - next-travel hint shown on car/hall arrows
--
-- The car moves with PivotTo (all car parts are anchored). Riders are
-- carried by applying the car's per-frame movement to their characters,
-- so they can jump, land and walk freely inside the car while it travels.
--------------------------------------------------------------------

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Elevator = script.Parent

local function fetch(parent, name)
	local inst = parent and parent:FindFirstChild(name)
	if not inst and parent then
		inst = parent:WaitForChild(name, 5)
	end
	return inst
end

local Car = fetch(Elevator, "Car")
local Floors = fetch(Elevator, "Floors")
local FloorValue = fetch(Elevator, "Floor")
local DirectionValue = fetch(Elevator, "Direction")
local UDValue = fetch(Elevator, "UD")

if not (Car and Floors and FloorValue and DirectionValue and UDValue) then
	error("[RussEL Elevator Engine] Model structure incomplete - cannot start.")
end

--------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------
local TRAVEL_SPEED = 8        -- studs per second
local DOOR_OPEN_TIME = 1.6    -- seconds for doors to fully open
local DOOR_CLOSE_TIME = 2.4   -- seconds for doors to fully close (slower, realistic)
local DOOR_HOLD = 4           -- seconds doors stay open at a floor
local DOOR_REHOLD = 3         -- seconds after a door reopen
local MAX_CLOSE_RETRIES = 8

--------------------------------------------------------------------
-- References
--------------------------------------------------------------------
local Platform = fetch(Car, "Platform")
local DoorSensor = fetch(Car, "DoorSensor")

local function getSound(name)
	local s = Platform and Platform:FindFirstChild(name)
	return (s and s:IsA("Sound")) and s or nil
end

local motorSound = getSound("Motor")
local doorOpenSound = getSound("DO")
local doorCloseSound = getSound("DC")
local dingSound = getSound("Beep")
local nudgeSound = getSound("Nudge")
local alarmSound = getSound("Alarm")
local passChime = getSound("FloorPassChime")

if motorSound then motorSound.Looped = true end
if alarmSound then alarmSound.Looped = true end

--------------------------------------------------------------------
-- Door geometry
-- Each sliding door is a model: Car.DL / Car.DR on the car, and
-- DoorLeft / DoorRight on every floor. Besides the tall leaf, each model
-- also holds the edge trim strips and sensor lights that ride on the leaf,
-- so the ENTIRE assembly slides together along the Z axis.
--------------------------------------------------------------------
local pivot0 = Car:GetPivot()

-- A door assembly is one sliding door model. It contains the tall leaf
-- plus the edge trim and sensor lights attached to it; everything in the
-- model moves together so nothing is left floating in the doorway.
local function isDoorLeaf(p)
	return p:IsA("BasePart")
		and math.abs(p.Size.X - 0.2) < 0.05
		and math.abs(p.Size.Y - 8.2) < 0.05
		and math.abs(p.Size.Z - 2.2) < 0.05
end

local function buildDoorAssembly(holder)
	if not holder then return nil end
	local leaf
	for _, p in ipairs(holder:GetDescendants()) do
		if isDoorLeaf(p) then
			leaf = p
			break
		end
	end
	if not leaf then return nil end
	local parts = {}
	for _, p in ipairs(holder:GetDescendants()) do
		if p:IsA("BasePart") then
			table.insert(parts, {
				part = p,
				rel = pivot0:ToObjectSpace(p.CFrame), -- relative to the car pivot (car doors)
				closed = p.CFrame,                    -- fixed world CFrame (floor doors)
			})
		end
	end
	return {
		parts = parts,
		amount = leaf.Size.Z,
		leafZ = leaf.Position.Z,
		slideDir = 0, -- resolved below, once the pair is complete
	}
end

-- Given the two door assemblies of one doorway, work out which direction
-- each one slides (away from the doorway centre) in order to open.
local function pairAssemblies(a, b)
	if not (a and b) then return nil end
	local centerZ = (a.leafZ + b.leafZ) / 2
	a.slideDir = (a.leafZ > centerZ) and 1 or -1
	b.slideDir = (b.leafZ > centerZ) and 1 or -1
	return {a, b}
end

local carLeafData = pairAssemblies(
	buildDoorAssembly(Car:FindFirstChild("DL")),
	buildDoorAssembly(Car:FindFirstChild("DR"))
) or {}

local floorLevels = {}
for i = 1, 5 do
	local fm = Floors:FindFirstChild("Floor" .. i)
	if fm then
		local level = fm:FindFirstChild("Level")
		local record = {
			model = fm,
			level = level,
			y = level and level.Position.Y or nil,
			leaves = {},
			ud = fm:FindFirstChild("UD"),
			arrivalSound = level and level:FindFirstChild("Floor"),
			call = fm:FindFirstChild("CallButtonUp"),
		}
		record.leaves = pairAssemblies(
			buildDoorAssembly(fm:FindFirstChild("DoorLeft")),
			buildDoorAssembly(fm:FindFirstChild("DoorRight"))
		) or {}
		floorLevels[i] = record
	end
end

local NUM_FLOORS = 0
for i in ipairs(floorLevels) do
	NUM_FLOORS = i
end

if NUM_FLOORS == 0 or #carLeafData ~= 2 then
	error("[RussEL Elevator Engine] Could not locate door leaves or floors.")
end

--------------------------------------------------------------------
-- Button panels (car floor buttons + hall call buttons)
--------------------------------------------------------------------
local ACTIVE_COLOR = Color3.fromRGB(255, 191, 0)

local carButtons = {}
local callButtons = {}

local function buildPanel(container)
	if not container then return nil end
	local led = container:FindFirstChild("LED")
	return {
		value = container:FindFirstChild("Value"),
		led = led,
		ledColor = led and led.Color or nil,
		ledMaterial = led and led.Material or nil,
	}
end

for i = 1, NUM_FLOORS do
	carButtons[i] = buildPanel(Car:FindFirstChild("BTF" .. i))
	local rec = floorLevels[i]
	callButtons[i] = rec and buildPanel(rec.call) or nil
end

local function setPanelLight(panel, on)
	if not panel then return end
	if panel.value then
		panel.value.Value = on and "1" or "0"
	end
	if panel.led then
		if on then
			panel.led.Color = ACTIVE_COLOR
			panel.led.Material = Enum.Material.Neon
		else
			panel.led.Color = panel.ledColor
			panel.led.Material = panel.ledMaterial
		end
	end
end

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------
local requests = {}
local busy = false
local doorAlpha = 0            -- 0 = closed, 1 = open (car + current floor doors)
local currentFloor = math.clamp(FloorValue.Value, 1, NUM_FLOORS)
FloorValue.Value = currentFloor
local doorOpenRequested = false
local doorCloseRequested = false

--------------------------------------------------------------------
-- Door operation
--------------------------------------------------------------------
local function isObstructed()
	if not DoorSensor then return false end
	local ok, parts = pcall(function()
		return workspace:GetPartsInPart(DoorSensor)
	end)
	if not ok or not parts then return false end
	for _, p in ipairs(parts) do
		if not p:IsDescendantOf(Elevator) then
			local char = p:FindFirstAncestorOfClass("Model")
			if char and char:FindFirstChildOfClass("Humanoid") then
				return true
			end
		end
	end
	return false
end

local function applyDoorAlpha(alpha)
	local carPivot = Car:GetPivot()
	-- Slide in WORLD space: several door parts are rotated 180 degrees, so
	-- offsetting their local Z axis would move them the wrong way.
	for _, asm in ipairs(carLeafData) do
		local slide = Vector3.new(0, 0, asm.slideDir * asm.amount * alpha)
		for _, p in ipairs(asm.parts) do
			p.part.CFrame = (carPivot * p.rel) + slide
		end
	end
	local rec = floorLevels[currentFloor]
	if rec then
		for _, asm in ipairs(rec.leaves) do
			local slide = Vector3.new(0, 0, asm.slideDir * asm.amount * alpha)
			for _, p in ipairs(asm.parts) do
				p.part.CFrame = p.closed + slide
			end
		end
	end
end

local function animateDoors(targetAlpha, duration, abortIfObstructed)
	local startAlpha = doorAlpha
	if math.abs(targetAlpha - startAlpha) < 0.001 then
		doorAlpha = targetAlpha
		applyDoorAlpha(targetAlpha)
		return true
	end
	local elapsed = 0
	while elapsed < duration do
		local dt = RunService.Heartbeat:Wait()
		elapsed = math.min(elapsed + dt, duration)
		local a = elapsed / duration
		-- Opening doors move briskly then settle; closing doors start soft,
		-- run steady, and ease into the seal - like real door operators.
		local eased
		if targetAlpha > startAlpha then
			eased = 1 - (1 - a) ^ 3
		else
			eased = (a < 0.5) and (2 * a * a) or (1 - ((-2 * a + 2) ^ 2) / 2)
		end
		doorAlpha = startAlpha + (targetAlpha - startAlpha) * eased
		applyDoorAlpha(doorAlpha)
		if abortIfObstructed and isObstructed() then
			return false
		end
	end
	doorAlpha = targetAlpha
	return true
end

local function openDoors()
	if doorAlpha > 0.999 then return end
	if doorOpenSound then doorOpenSound:Play() end
	animateDoors(1, DOOR_OPEN_TIME, false)
end

-- Returns true if the doors ended up fully closed.
local function closeDoors()
	if doorAlpha < 0.001 then return true end
	if nudgeSound then nudgeSound:Play() end
	if doorCloseSound then doorCloseSound:Play() end
	local ok = animateDoors(0, DOOR_CLOSE_TIME, true)
	if not ok then
		openDoors()
		return false
	end
	return true
end

local function holdDoors(duration)
	local deadline = os.clock() + duration
	while os.clock() < deadline do
		if doorCloseRequested then
			doorCloseRequested = false
			return
		end
		if doorOpenRequested then
			doorOpenRequested = false
			deadline = os.clock() + DOOR_REHOLD
		end
		task.wait(0.1)
	end
end

-- Close with retries; returns true when fully closed.
local function closeDoorsWithRetries()
	local retries = 0
	while not closeDoors() do
		retries += 1
		if retries >= MAX_CLOSE_RETRIES then
			return false
		end
		holdDoors(1.5)
	end
	return true
end

--------------------------------------------------------------------
-- Travel
--------------------------------------------------------------------
local function pivotForFloor(i)
	local rec = floorLevels[i]
	local base = floorLevels[1]
	return pivot0 * CFrame.new(0, rec.y - base.y, 0)
end

-- Rider carrying: instead of welding players to the platform (which
-- freezes them mid-air, unable to jump or walk), the car's movement is
-- applied to every rider each frame. The carry test is purely positional
-- (is the HRP inside the car's volume?), NOT grounded-state, so airborne
-- players are carried too: their velocity is never touched, so jumps and
-- falls play out naturally relative to the car, and a player who lands
-- mid-travel is picked up by the next frame's check automatically.
-- The Y window (-3 to +14) covers a full jump apex above the floor so a
-- player at the top of their jump is never momentarily dropped.
local function carryRiders(deltaY)
	if deltaY == 0 or not Platform then return end
	local pp = Platform.Position
	local ps = Platform.Size
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local p = hrp.Position
			if p.X > pp.X - ps.X / 2 - 2 and p.X < pp.X + ps.X / 2 + 2
				and p.Z > pp.Z - ps.Z / 2 - 2 and p.Z < pp.Z + ps.Z / 2 + 2
				and p.Y > pp.Y - 3 and p.Y < pp.Y + 14 then
				hrp.CFrame = hrp.CFrame + Vector3.new(0, deltaY, 0)
			end
		end
	end
end

local function travelTo(target)
	local from = FloorValue.Value
	local rec = floorLevels[target]
	if not rec or not rec.y then return end

	local dir = (target > from) and "U" or "D"
	DirectionValue.Value = dir
	UDValue.Value = dir

	if motorSound then motorSound:Play() end

	local startPivot = Car:GetPivot()
	local endPivot = pivotForFloor(target)
	local startY = startPivot.Position.Y
	local endY = endPivot.Position.Y
	local duration = math.max(math.abs(endY - startY) / TRAVEL_SPEED, 0.5)

	-- Intermediate floors, for indicator counting + pass chime
	local passed = {}
	local step = (dir == "U") and 1 or -1
	for i = from + step, target - step, step do
		if floorLevels[i] and floorLevels[i].y then
			table.insert(passed, {floor = i, y = floorLevels[i].y})
		end
	end
	local nextPassed = 1

	local elapsed = 0
	while elapsed < duration do
		local dt = RunService.Heartbeat:Wait()
		elapsed = math.min(elapsed + dt, duration)
		local a = elapsed / duration
		local eased = a * a * (3 - 2 * a)
		local y = startY + (endY - startY) * eased
		local newPivot = startPivot * CFrame.new(0, y - startY, 0)
		local deltaY = newPivot.Position.Y - Car:GetPivot().Position.Y
		Car:PivotTo(newPivot)
		carryRiders(deltaY)
		while nextPassed <= #passed do
			local pf = passed[nextPassed]
			local reached = (dir == "U" and y >= pf.y - 0.05) or (dir == "D" and y <= pf.y + 0.05)
			if reached then
				FloorValue.Value = pf.floor
				if passChime then passChime:Play() end
				nextPassed += 1
			else
				break
			end
		end
	end

	carryRiders(endPivot.Position.Y - Car:GetPivot().Position.Y)
	Car:PivotTo(endPivot)
	FloorValue.Value = target
	currentFloor = target
	DirectionValue.Value = "N"

	if motorSound then motorSound:Stop() end

	if dingSound then dingSound:Play() end
	if rec.arrivalSound then rec.arrivalSound:Play() end
end

--------------------------------------------------------------------
-- Request handling
--------------------------------------------------------------------
local function requestFloor(n)
	if n < 1 or n > NUM_FLOORS or not floorLevels[n] then return end
	if requests[n] then return end
	requests[n] = true
	setPanelLight(carButtons[n], true)
	setPanelLight(callButtons[n], true)
	if dingSound then dingSound:Play() end
end

local function clearRequest(n)
	requests[n] = nil
	setPanelLight(carButtons[n], false)
	setPanelLight(callButtons[n], false)
end

local function pickTarget()
	local cur = FloorValue.Value
	local dir = DirectionValue.Value
	local best = nil
	if dir == "U" then
		for f in pairs(requests) do
			if f > cur and (not best or f < best) then best = f end
		end
		if not best then
			for f in pairs(requests) do
				if f < cur and (not best or f > best) then best = f end
			end
		end
	elseif dir == "D" then
		for f in pairs(requests) do
			if f < cur and (not best or f > best) then best = f end
		end
		if not best then
			for f in pairs(requests) do
				if f > cur and (not best or f < best) then best = f end
			end
		end
	else
		for f in pairs(requests) do
			if not best or math.abs(f - cur) < math.abs(best - cur) then best = f end
		end
	end
	return best
end

local function updateUDHint()
	local hint = "N"
	local nxt = pickTarget()
	if nxt then
		hint = (nxt > FloorValue.Value) and "U" or "D"
	end
	UDValue.Value = hint
	for i = 1, NUM_FLOORS do
		local rec = floorLevels[i]
		if rec and rec.ud then
			rec.ud.Value = (i == FloorValue.Value) and hint or "N"
		end
	end
end

--------------------------------------------------------------------
-- Input wiring
--------------------------------------------------------------------
for i = 1, NUM_FLOORS do
	local btf = Car:FindFirstChild("BTF" .. i)
	local button = btf and btf:FindFirstChild("Button")
	local cd = button and button:FindFirstChild("ClickDetector")
	if cd then
		cd.MouseClick:Connect(function()
			requestFloor(i)
		end)
	end

	local rec = floorLevels[i]
	local call = rec and rec.call
	local cbtn = call and call:FindFirstChild("Button")
	local ccd = cbtn and cbtn:FindFirstChild("ClickDetector")
	if ccd then
		ccd.MouseClick:Connect(function()
			requestFloor(i)
		end)
	end
end

local function wireButton(name, fn)
	local m = Car:FindFirstChild(name)
	local button = m and m:FindFirstChild("Button")
	local cd = button and button:FindFirstChild("ClickDetector")
	if cd then
		cd.MouseClick:Connect(fn)
	end
end

wireButton("BTDO", function()
	if not busy then
		doorOpenRequested = true
	end
end)

wireButton("BTDC", function()
	if not busy then
		doorCloseRequested = true
	end
end)

-- Alarm toggle
local btal = Car:FindFirstChild("BTAL")
local btalLED = btal and btal:FindFirstChild("LED")
local btalLEDColor = btalLED and btalLED.Color
local btalLEDMaterial = btalLED and btalLED.Material
local btalValue = btal and btal:FindFirstChild("Value")
local alarmOn = false

wireButton("BTAL", function()
	if not alarmSound then return end
	alarmOn = not alarmOn
	if alarmOn then
		alarmSound:Play()
	else
		alarmSound:Stop()
	end
	if btalLED then
		if alarmOn then
			btalLED.Color = ACTIVE_COLOR
			btalLED.Material = Enum.Material.Neon
		else
			btalLED.Color = btalLEDColor
			btalLED.Material = btalLEDMaterial
		end
	end
	if btalValue then
		btalValue.Value = alarmOn and "1" or "0"
	end
end)

-- Fan toggle (the fan button's own script plays its ding sound)
local btfan = Car:FindFirstChild("BTFan")
local fanLED = btfan and btfan:FindFirstChild("LED")
local fanLEDColor = fanLED and fanLED.Color
local fanLEDMaterial = fanLED and fanLED.Material
local fanValue = btfan and btfan:FindFirstChild("Value")
local fanOn = false

wireButton("BTFan", function()
	fanOn = not fanOn
	if fanLED then
		if fanOn then
			fanLED.Color = ACTIVE_COLOR
			fanLED.Material = Enum.Material.Neon
		else
			fanLED.Color = fanLEDColor
			fanLED.Material = fanLEDMaterial
		end
	end
	if fanValue then
		fanValue.Value = fanOn and "1" or "0"
	end
end)

--------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------
print(("[RussEL Elevator Engine] Online - %d floors, car at floor %d."):format(NUM_FLOORS, currentFloor))

while true do
	local target = pickTarget()
	if target then
		clearRequest(target)
		busy = true
		local ok = true
		if target ~= FloorValue.Value then
			if doorAlpha > 0.001 then
				ok = closeDoorsWithRetries()
			end
			if ok then
				local success, err = pcall(travelTo, target)
				if not success then
					warn("[RussEL Elevator Engine] Travel error: " .. tostring(err))
					DirectionValue.Value = "N"
					ok = false
				end
			end
		end
		if ok then
			task.wait(0.4) -- brief settle after arrival, like a real elevator
			openDoors()
			holdDoors(DOOR_HOLD)
			closeDoorsWithRetries()
			updateUDHint()
		else
			-- Persistent obstruction (or travel error): requeue the floor
			requests[target] = true
			setPanelLight(carButtons[target], true)
			setPanelLight(callButtons[target], true)
		end
		busy = false
	elseif doorOpenRequested then
		doorOpenRequested = false
		busy = true
		openDoors()
		holdDoors(DOOR_REHOLD)
		closeDoorsWithRetries()
		updateUDHint()
		busy = false
	else
		if DirectionValue.Value ~= "N" then
			DirectionValue.Value = "N"
		end
		task.wait(0.2)
	end
	task.wait(0.1)
end
