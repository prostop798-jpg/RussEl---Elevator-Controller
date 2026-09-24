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
-- API (BindableFunction + BindableEvent)
-- External scripts can invoke the API via:
--   ElevatorModel.API:Invoke("CallFloor", 3)
--   ElevatorModel.API:Invoke("OpenDoors")
--   ElevatorModel.API:Invoke("CloseDoors")
--   ElevatorModel.API:Invoke("GetFloor")
--   ElevatorModel.API:Invoke("GetDirection")
--   ElevatorModel.API:Invoke("IsBusy")
--   ElevatorModel.API:Invoke("GetDoorState")
--   ElevatorModel.API:Invoke("GetRequests")
--   ElevatorModel.API:Invoke("CancelRequest", 3)
--   ElevatorModel.API:Invoke("ToggleAlarm")
--   ElevatorModel.API:Invoke("ToggleFan")
--   ElevatorModel.API:Invoke("SetSpeed", 12)
--   ElevatorModel.API:Invoke("GetNumFloors")
--   ElevatorModel.API:Invoke("GetFloorName", 3)
--   ElevatorModel.API:Invoke("GetState")
--
-- External scripts can listen for events via:
--   ElevatorModel.Event.Event:Connect(function(action, data) ... end)
--   Actions: "FloorRequested", "FloorCleared", "Departed", "Arrived",
--           "DoorsOpening", "DoorsOpen", "DoorsClosing", "DoorsClosed",
--           "BusyChanged", "AlarmToggled", "FanToggled", "FloorPassed"
--------------------------------------------------------------------
local API = Elevator:FindFirstChild("API")
local Event = Elevator:FindFirstChild("Event")
local StateFolder = Elevator:FindFirstChild("State")
local BusyValue = StateFolder and StateFolder:FindFirstChild("Busy")
local DoorStateValue = StateFolder and StateFolder:FindFirstChild("DoorState")
local NumFloorsValue = StateFolder and StateFolder:FindFirstChild("NumFloors")
local TravelSpeedValue = StateFolder and StateFolder:FindFirstChild("TravelSpeed")
local DoorOpenTimeValue = StateFolder and StateFolder:FindFirstChild("DoorOpenTime")
local DoorCloseTimeValue = StateFolder and StateFolder:FindFirstChild("DoorCloseTime")
local DoorHoldTimeValue = StateFolder and StateFolder:FindFirstChild("DoorHoldTime")
local EmergencyStopValue = StateFolder and StateFolder:FindFirstChild("EmergencyStop")
local InServiceValue = StateFolder and StateFolder:FindFirstChild("InService")
local CurrentFloorNameValue = StateFolder and StateFolder:FindFirstChild("CurrentFloorName")

local emergencyStop = false
local inService = true

-- Sync state values
if TravelSpeedValue then TravelSpeedValue.Value = TRAVEL_SPEED end
if DoorOpenTimeValue then DoorOpenTimeValue.Value = DOOR_OPEN_TIME end
if DoorCloseTimeValue then DoorCloseTimeValue.Value = DOOR_CLOSE_TIME end
if DoorHoldTimeValue then DoorHoldTimeValue.Value = DOOR_HOLD end
if InServiceValue then InServiceValue.Value = true end
if NumFloorsValue then NumFloorsValue.Value = NUM_FLOORS end

-- Helper to update floor name
local function updateFloorName()
	if CurrentFloorNameValue then
		local customLabel = Elevator:FindFirstChild("CustomLabel")
		if customLabel and customLabel:IsA("ModuleScript") then
			local ok, labels = pcall(require, customLabel)
			if ok and labels.CUSTOMFLOORLABEL and labels.CUSTOMFLOORLABEL[currentFloor] then
				CurrentFloorNameValue.Value = labels.CUSTOMFLOORLABEL[currentFloor]
				return
			end
		end
		CurrentFloorNameValue.Value = tostring(currentFloor)
	end
end
updateFloorName()

local function fireEvent(action, data)
    if Event then
        Event:Fire(action, data)
    end
end

local function setBusy(val)
    busy = val
    if BusyValue then BusyValue.Value = val end
    fireEvent("BusyChanged", val)
end

local function setDoorState(state)
    if DoorStateValue then DoorStateValue.Value = state end
    if state == "Opening" then
        fireEvent("DoorsOpening")
    elseif state == "Open" then
        fireEvent("DoorsOpen")
    elseif state == "Closing" then
        fireEvent("DoorsClosing")
    elseif state == "Closed" then
        fireEvent("DoorsClosed")
    end
end

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
		if emergencyStop then
			DirectionValue.Value = "N"
			if motorSound then motorSound:Stop() end
			fireEvent("EmergencyStopped", {floor = FloorValue.Value, position = Car:GetPivot().Position.Y})
			return
		end
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
	setDoorState("Opening")
	if doorOpenSound then doorOpenSound:Play() end
	animateDoors(1, DOOR_OPEN_TIME, false)
	setDoorState("Open")
end

-- Returns true if the doors ended up fully closed.
local function closeDoors()
	if doorAlpha < 0.001 then return true end
	setDoorState("Closing")
	if nudgeSound then nudgeSound:Play() end
	if doorCloseSound then doorCloseSound:Play() end
	local ok = animateDoors(0, DOOR_CLOSE_TIME, true)
	if not ok then
		openDoors()
		return false
	end
	setDoorState("Closed")
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
	if emergencyStop then return end
	local from = FloorValue.Value
	local rec = floorLevels[target]
	if not rec or not rec.y then return end

	local dir = (target > from) and "U" or "D"
	DirectionValue.Value = dir
	UDValue.Value = dir

	if motorSound then motorSound:Play() end

	fireEvent("Departed", {from = from, to = target, direction = dir})

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
		if emergencyStop then
			DirectionValue.Value = "N"
			if motorSound then motorSound:Stop() end
			fireEvent("EmergencyStopped", {floor = FloorValue.Value, position = Car:GetPivot().Position.Y})
			return
		end
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
				fireEvent("FloorPassed", pf.floor)
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
	updateFloorName()
	DirectionValue.Value = "N"

	if motorSound then motorSound:Stop() end

	if dingSound then dingSound:Play() end
	if rec.arrivalSound then rec.arrivalSound:Play() end
	fireEvent("Arrived", target)
end

--------------------------------------------------------------------
-- Request handling
--------------------------------------------------------------------
local function requestFloor(n)
	if emergencyStop or not inService then return end
	if n < 1 or n > NUM_FLOORS or not floorLevels[n] then return end
	if requests[n] then return end
	requests[n] = true
	setPanelLight(carButtons[n], true)
	setPanelLight(callButtons[n], true)
	if dingSound then dingSound:Play() end
	fireEvent("FloorRequested", n)
end

local function clearRequest(n)
	requests[n] = nil
	setPanelLight(carButtons[n], false)
	setPanelLight(callButtons[n], false)
	fireEvent("FloorCleared", n)
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
	fireEvent("AlarmToggled", alarmOn)
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
	fireEvent("FanToggled", fanOn)
end)

--------------------------------------------------------------------
-- API handler
--------------------------------------------------------------------
if API then
	API.OnInvoke = function(command, ...)
		local args = {...}

		if command == "CallFloor" then
			local n = tonumber(args[1])
			if n then
				requestFloor(n)
				return true
			end
			return false

		elseif command == "OpenDoors" then
			if not busy and not emergencyStop and inService then
				doorOpenRequested = true
				return true
			end
			return false

		elseif command == "CloseDoors" then
			if not busy then
				doorCloseRequested = true
				return true
			end
			return false

		elseif command == "GetFloor" then
			return FloorValue.Value

		elseif command == "GetDirection" then
			return DirectionValue.Value

		elseif command == "GetUD" then
			return UDValue.Value

		elseif command == "IsBusy" then
			return busy

		elseif command == "GetDoorState" then
			if doorAlpha > 0.999 then return "Open"
			elseif doorAlpha < 0.001 then return "Closed"
			else return "Partial" end

		elseif command == "GetRequests" then
			local list = {}
			for f in pairs(requests) do
				table.insert(list, f)
			end
			return list

		elseif command == "CancelRequest" then
			local n = tonumber(args[1])
			if n and requests[n] then
				clearRequest(n)
				return true
			end
			return false

		elseif command == "ClearAllRequests" then
			local count = 0
			for f in pairs(requests) do
				clearRequest(f)
				count = count + 1
			end
			fireEvent("AllRequestsCleared")
			return count

		elseif command == "ToggleAlarm" then
			if not alarmSound then return false end
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
			fireEvent("AlarmToggled", alarmOn)
			return alarmOn

		elseif command == "SetAlarm" then
			local want = args[1]
			if not alarmSound then return false end
			if want == alarmOn then return alarmOn end
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
			fireEvent("AlarmToggled", alarmOn)
			return alarmOn

		elseif command == "ToggleFan" then
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
			fireEvent("FanToggled", fanOn)
			return fanOn

		elseif command == "SetFan" then
			local want = args[1]
			if want == fanOn then return fanOn end
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
			fireEvent("FanToggled", fanOn)
			return fanOn

		elseif command == "SetSpeed" then
			local s = tonumber(args[1])
			if s and s > 0 then
				TRAVEL_SPEED = s
				if TravelSpeedValue then TravelSpeedValue.Value = s end
				fireEvent("SpeedChanged", s)
				return true
			end
			return false

		elseif command == "GetSpeed" then
			return TRAVEL_SPEED

		elseif command == "SetDoorOpenTime" then
			local t = tonumber(args[1])
			if t and t > 0 then
				DOOR_OPEN_TIME = t
				if DoorOpenTimeValue then DoorOpenTimeValue.Value = t end
				fireEvent("ConfigChanged", {key = "DoorOpenTime", value = t})
				return true
			end
			return false

		elseif command == "SetDoorCloseTime" then
			local t = tonumber(args[1])
			if t and t > 0 then
				DOOR_CLOSE_TIME = t
				if DoorCloseTimeValue then DoorCloseTimeValue.Value = t end
				fireEvent("ConfigChanged", {key = "DoorCloseTime", value = t})
				return true
			end
			return false

		elseif command == "SetDoorHoldTime" then
			local t = tonumber(args[1])
			if t and t > 0 then
				DOOR_HOLD = t
				if DoorHoldTimeValue then DoorHoldTimeValue.Value = t end
				fireEvent("ConfigChanged", {key = "DoorHoldTime", value = t})
				return true
			end
			return false

		elseif command == "GetConfig" then
			return {
				travelSpeed = TRAVEL_SPEED,
				doorOpenTime = DOOR_OPEN_TIME,
				doorCloseTime = DOOR_CLOSE_TIME,
				doorHold = DOOR_HOLD,
				doorRehold = DOOR_REHOLD,
				maxCloseRetries = MAX_CLOSE_RETRIES,
			}

		elseif command == "GetNumFloors" then
			return NUM_FLOORS

		elseif command == "GetFloorName" then
			local n = tonumber(args[1])
			if n and floorLevels[n] then
				local customLabel = Elevator:FindFirstChild("CustomLabel")
				if customLabel and customLabel:IsA("ModuleScript") then
					local ok, labels = pcall(require, customLabel)
					if ok and labels.CUSTOMFLOORLABEL and labels.CUSTOMFLOORLABEL[n] then
						return labels.CUSTOMFLOORLABEL[n]
					end
				end
				return tostring(n)
			end
			return nil

		elseif command == "GetAllFloorNames" then
			local names = {}
			local customLabel = Elevator:FindFirstChild("CustomLabel")
			local labels = nil
			if customLabel and customLabel:IsA("ModuleScript") then
				local ok, result = pcall(require, customLabel)
				if ok then labels = result end
			end
			for i = 1, NUM_FLOORS do
				if labels and labels.CUSTOMFLOORLABEL and labels.CUSTOMFLOORLABEL[i] then
					names[i] = labels.CUSTOMFLOORLABEL[i]
				else
					names[i] = tostring(i)
				end
			end
			return names

		elseif command == "GetFloorY" then
			local n = tonumber(args[1])
			if n and floorLevels[n] and floorLevels[n].y then
				return floorLevels[n].y
			end
			return nil

		elseif command == "EmergencyStop" then
			if emergencyStop then return true end
			emergencyStop = true
			if EmergencyStopValue then EmergencyStopValue.Value = true end
			if motorSound then motorSound:Stop() end
			DirectionValue.Value = "N"
			-- Clear all requests
			for f in pairs(requests) do
				clearRequest(f)
			end
			fireEvent("EmergencyStopped", {floor = FloorValue.Value})
			return true

		elseif command == "ReleaseEmergencyStop" then
			if not emergencyStop then return false end
			emergencyStop = false
			if EmergencyStopValue then EmergencyStopValue.Value = false end
			fireEvent("EmergencyStopReleased")
			return true

		elseif command == "IsEmergencyStop" then
			return emergencyStop

		elseif command == "SetInService" then
			local want = args[1]
			inService = want and true or false
			if InServiceValue then InServiceValue.Value = inService end
			if not inService then
				-- Clear all requests when going out of service
				for f in pairs(requests) do
					clearRequest(f)
				end
				DirectionValue.Value = "N"
			end
			fireEvent("ServiceModeChanged", inService)
			return inService

		elseif command == "IsInService" then
			return inService

		elseif command == "GetState" then
			local reqList = {}
			for f in pairs(requests) do
				table.insert(reqList, f)
			end
			local names = {}
			local customLabel = Elevator:FindFirstChild("CustomLabel")
			local labels = nil
			if customLabel and customLabel:IsA("ModuleScript") then
				local ok, result = pcall(require, customLabel)
				if ok then labels = result end
			end
			for i = 1, NUM_FLOORS do
				if labels and labels.CUSTOMFLOORLABEL and labels.CUSTOMFLOORLABEL[i] then
					names[i] = labels.CUSTOMFLOORLABEL[i]
				else
					names[i] = tostring(i)
				end
			end
			return {
				floor = FloorValue.Value,
				floorName = CurrentFloorNameValue and CurrentFloorNameValue.Value or tostring(FloorValue.Value),
				direction = DirectionValue.Value,
				ud = UDValue.Value,
				busy = busy,
				doorState = (doorAlpha > 0.999 and "Open" or doorAlpha < 0.001 and "Closed" or "Partial"),
				numFloors = NUM_FLOORS,
				requests = reqList,
				alarmOn = alarmOn,
				fanOn = fanOn,
				emergencyStop = emergencyStop,
				inService = inService,
				travelSpeed = TRAVEL_SPEED,
				doorOpenTime = DOOR_OPEN_TIME,
				doorCloseTime = DOOR_CLOSE_TIME,
				doorHoldTime = DOOR_HOLD,
				floorNames = names,
			}
		end
		return nil
	end
end

--------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------
print(("[RussEL Elevator Engine] Online - %d floors, car at floor %d."):format(NUM_FLOORS, currentFloor))

while true do
	if emergencyStop then
		task.wait(0.5)
		continue
	end
	local target = pickTarget()
	if target then
		clearRequest(target)
		setBusy(true)
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
		setBusy(false)
	elseif doorOpenRequested and inService then
		doorOpenRequested = false
		setBusy(true)
		openDoors()
		holdDoors(DOOR_REHOLD)
		closeDoorsWithRetries()
		updateUDHint()
		setBusy(false)
	else
		if DirectionValue.Value ~= "N" then
			DirectionValue.Value = "N"
		end
		task.wait(0.2)
	end
	task.wait(0.1)
end
