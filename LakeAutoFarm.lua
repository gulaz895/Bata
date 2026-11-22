--!nocheck
-- LakeAutoFarm.lua  |  client executor script, WindUI front end
-- Built from the Dumper v2.0 dump of PlaceId 134148497865430 (2026-11-22, dump 3).
-- Not run in-game by the author. See the status notes delivered with this file.
--
-- Loop: scoop water from the lake -> walk to Grandpa's PourZone -> pour -> repeat.
-- Auto Upgrade is an independent toggle that buys the cheapest affordable skill-tree node.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------
-- Build-dependent values. Every entry names where it came from (all [Z3]).
--------------------------------------------------------------------------
local Build = {
	PlaceId = 134148497865430, -- summary.txt

	RemotesFolder = "Remotes", -- ReplicatedStorage.Remotes, hierarchy.txt
	ScoopHold = "ScoopHold", -- RemoteEvent. ScoopController: FireServer(true, waterPoint:Vector3) / FireServer(false)
	PourHold = "PourHold", -- RemoteEvent. PourController: FireServer(true) / FireServer(false)
	Upgrade = "Upgrade", -- RemoteFunction. SkillTreeController: InvokeServer(tab, track) -> ok, reason

	-- Module scripts the game itself requires
	ToolsConfigPath = { "Config", "Tools" },
	SkillTreePath = { "SkillTree" },
	LakeShapePath = { "Lake", "LakeShape" }, -- hasWater(x, z, level)

	-- Workspace objects. ScoopController / PourController
	MapName = "Map",
	WaterName = "Water", -- Map.Water, attribute SpoonsLeft
	BasinCollisionName = "BasinCollision",
	GrandpaAreaName = "GrandpaArea",
	PourZoneName = "PourZone", -- Part, attribute Radius (default 4.5 in PourController.inZone)
	GrandpaName = "Grandpa",
	PourZoneDefaultRadius = 4.5,
	PourZoneSlack = 0.5,

	-- LocalPlayer attributes
	ToolAttr = "Tool", -- missing means "Spoon" (ScoopController)
	DefaultTool = "Spoon",
	CarriedAttr = "Carried",
	CapacityAttr = "Capacity", -- falls back to Tools[tool].capacity
	StunAttr = "DedaStunUntil", -- compared against os.clock()
	MegaStrawAttr = "MegaStrawCarrying",
	IntroAttr = "InIntro", -- SkillTreeController
	CoinsAttr = "CoinsCents", -- SkillTreeController

	-- Water attribute: no spoons left means the lake is drained
	SpoonsLeftAttr = "SpoonsLeft",

	-- Grandpa attributes. PourController.startPour
	GrandpaStateAttr = "DedaState", -- "Doze" means asleep
	GrandpaWantsChocoAttr = "DedaWantsChoco",

	ScoopRefreshSeconds = 0.2, -- ScoopController re-sends the aim point every 0.2 s while holding
	AimRepickSeconds = 1.0,
	UpgradeIntervalSeconds = 1.0,
	UpgradeRefusalCooldown = 30,
	WaitTimeout = 15,

	WindUIUrl = "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua", -- from memory, not verified here
}

--------------------------------------------------------------------------
-- Single instance guard
--------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if env.LakeAutoFarm and env.LakeAutoFarm.Unload then
	pcall(env.LakeAutoFarm.Unload)
end

--------------------------------------------------------------------------
-- Resolve and validate game objects. Failure aborts before any UI is built.
--------------------------------------------------------------------------
local function fail(message)
	warn("[LakeAutoFarm] " .. message)
	return nil
end

local function need(parent, name, className)
	local child = parent and parent:WaitForChild(name, Build.WaitTimeout)
	if not child then
		return nil, name .. " not found"
	end
	if className and not child:IsA(className) then
		return nil, name .. " is a " .. child.ClassName .. ", expected " .. className
	end
	return child
end

local function requirePath(path)
	local node = ReplicatedStorage
	for _, name in ipairs(path) do
		node = node and node:WaitForChild(name, Build.WaitTimeout)
	end
	if not node or not node:IsA("ModuleScript") then
		return nil, table.concat(path, ".") .. " missing"
	end
	local ok, result = pcall(require, node)
	if not ok or type(result) ~= "table" then
		return nil, "require(" .. table.concat(path, ".") .. ") failed: " .. tostring(result)
	end
	return result
end

local function resolve()
	if game.PlaceId ~= Build.PlaceId then
		return fail(("PlaceId %d does not match the dumped place %d"):format(game.PlaceId, Build.PlaceId))
	end

	local G, err = {}, nil

	local remotes
	remotes, err = need(ReplicatedStorage, Build.RemotesFolder, "Folder")
	if not remotes then return fail(err) end
	G.scoopHold, err = need(remotes, Build.ScoopHold, "RemoteEvent")
	if not G.scoopHold then return fail(err) end
	G.pourHold, err = need(remotes, Build.PourHold, "RemoteEvent")
	if not G.pourHold then return fail(err) end
	G.upgrade, err = need(remotes, Build.Upgrade, "RemoteFunction")
	if not G.upgrade then return fail(err) end

	G.tools, err = requirePath(Build.ToolsConfigPath)
	if not G.tools then return fail(err) end
	G.skillTree, err = requirePath(Build.SkillTreePath)
	if not G.skillTree then return fail(err) end
	G.lakeShape, err = requirePath(Build.LakeShapePath)
	if not G.lakeShape then return fail(err) end

	local st = G.skillTree
	if type(st.order) ~= "table" or type(st.branches) ~= "table" or type(st.Upg) ~= "table" then
		return fail("SkillTree has an unexpected shape (order/branches/Upg)")
	end
	for _, fnName in ipairs({ "tabInChapter", "owns", "levelOf", "levels", "priceCents", "track" }) do
		if type(st[fnName]) ~= "function" then
			return fail("SkillTree." .. fnName .. " is not a function")
		end
	end
	if type(st.Upg.trackOpen) ~= "function" then
		return fail("SkillTree.Upg.trackOpen is not a function")
	end
	if type(G.lakeShape.hasWater) ~= "function" then
		return fail("LakeShape.hasWater is not a function")
	end

	local map
	map, err = need(workspace, Build.MapName)
	if not map then return fail(err) end
	G.water, err = need(map, Build.WaterName, "BasePart")
	if not G.water then return fail(err) end
	G.basin, err = need(map, Build.BasinCollisionName)
	if not G.basin then return fail(err) end
	local grandpaArea
	grandpaArea, err = need(map, Build.GrandpaAreaName)
	if not grandpaArea then return fail(err) end
	G.pourZone, err = need(grandpaArea, Build.PourZoneName, "BasePart")
	if not G.pourZone then return fail(err) end
	G.grandpa, err = need(grandpaArea, Build.GrandpaName)
	if not G.grandpa then return fail(err) end

	return G
end

local Game = resolve()
if not Game then
	return
end

--------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector(vector)
	return typeof(vector) == "Vector3" and isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

local function flatDistance(a, b)
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
local Farm = { Enabled = false }
local Upgrader = { Enabled = false }
local alive = true
local phase = "Scoop" -- "Scoop" or "Pour"
local scooping, pouring = false, false
local nextScoopSendAt = 0
local aimPoint, aimPickedAt = nil, 0
local standCache, standCachedAt = nil, 0
local lastReason, lastNotifyAt = nil, 0
local failedUntil = {}
local Notify = function() end -- replaced once the UI exists

local function report(reason)
	if reason == lastReason then
		return
	end
	local now = os.clock()
	if now - lastNotifyAt < 2 then
		return
	end
	lastReason = reason
	lastNotifyAt = now
	Notify(reason or "Running")
end

--------------------------------------------------------------------------
-- Remote helpers (every "true" send has a matching "false")
--------------------------------------------------------------------------
local function stopScoop()
	if scooping then
		scooping = false
		Game.scoopHold:FireServer(false)
	end
end

local function stopPour()
	if pouring then
		pouring = false
		Game.pourHold:FireServer(false)
	end
end

local function releaseAll()
	stopScoop()
	stopPour()
end

--------------------------------------------------------------------------
-- Aim and geometry
--------------------------------------------------------------------------
local function waterLevel()
	return Game.water.Position.Y + Game.water.Size.Y / 2
end

local includeParams = RaycastParams.new()
includeParams.FilterType = Enum.RaycastFilterType.Include
includeParams.FilterDescendantsInstances = { Game.basin }

local excludeParams = RaycastParams.new()
excludeParams.FilterType = Enum.RaycastFilterType.Exclude
excludeParams.RespectCanCollide = true

-- Mirrors the two obstruction tests in ScoopController.aimPoint.
local function clearPath(origin, target)
	local delta = target - origin
	local distance = delta.Magnitude
	local basinHit = workspace:Raycast(origin, delta, includeParams)
	if basinHit and (basinHit.Position - origin).Magnitude < distance - 0.6 then
		return false
	end

	local ignore = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	if workspace.CurrentCamera then
		table.insert(ignore, workspace.CurrentCamera)
	end
	excludeParams.FilterDescendantsInstances = ignore
	if distance > 0.7 and workspace:Raycast(origin, delta.Unit * (distance - 0.6), excludeParams) then
		return false
	end
	return true
end

local DIRECTIONS = 16

local function nearestWaterPoint(center, minRadius, maxRadius, step, accept)
	local level = waterLevel()
	for radius = minRadius, maxRadius, step do
		for i = 0, DIRECTIONS - 1 do
			local angle = i * (2 * math.pi / DIRECTIONS)
			local x = center.X + math.cos(angle) * radius
			local z = center.Z + math.sin(angle) * radius
			if Game.lakeShape.hasWater(x, z, level) then
				local point = Vector3.new(x, level, z)
				if not accept or accept(point) then
					return point
				end
			end
		end
	end
	return nil
end

-- A lake point the server should accept right now from where the player stands, or nil.
local function pickScoopPoint(reach)
	local camera = workspace.CurrentCamera
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not camera or not root then
		return nil
	end
	local origin = camera.CFrame.Position
	return nearestWaterPoint(root.Position, 2, math.floor(reach * 0.85), 2, function(point)
		return (point - origin).Magnitude <= reach and point.Y < origin.Y and clearPath(origin, point)
	end)
end

local function groundBelow(x, z, fallbackY)
	local ignore = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(Vector3.new(x, fallbackY + 60, z), Vector3.new(0, -200, 0), params)
	return hit and (hit.Position + Vector3.new(0, 3, 0)) or Vector3.new(x, fallbackY, z)
end

-- Where to walk so a scoop is possible: the lake point nearest the PourZone, stepped back toward it.
local function scoopStand(reach, rootY)
	local now = os.clock()
	if standCache and now - standCachedAt < 30 then
		return standCache
	end
	local pour = Game.pourZone.Position
	local lakePoint = nearestWaterPoint(pour, 2, 200, 4)
	if not lakePoint then
		return nil
	end
	local stand
	if flatDistance(pour, lakePoint) <= reach * 0.6 then
		stand = Vector3.new(pour.X, rootY, pour.Z)
	else
		local back = Vector3.new(pour.X - lakePoint.X, 0, pour.Z - lakePoint.Z).Unit * (reach * 0.6)
		stand = groundBelow(lakePoint.X + back.X, lakePoint.Z + back.Z, rootY)
	end
	standCache, standCachedAt = stand, now
	return stand
end

local function inPourZone(root)
	local radius = (Game.pourZone:GetAttribute("Radius") or Build.PourZoneDefaultRadius) + Build.PourZoneSlack
	return flatDistance(root.Position, Game.pourZone.Position) <= radius
end

--------------------------------------------------------------------------
-- Walking
--------------------------------------------------------------------------
local function wanted()
	return alive and Farm.Enabled
end

local function walkTo(target)
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not isFiniteVector(target) then
		return false
	end

	local waypoints = { { Position = target } }
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local okPath = pcall(function()
		path:ComputeAsync(root.Position, target)
	end)
	if okPath and path.Status == Enum.PathStatus.Success then
		waypoints = path:GetWaypoints()
	end

	for _, waypoint in ipairs(waypoints) do
		if not wanted() or humanoid.Health <= 0 then
			return false
		end
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(waypoint.Position)
		local startedAt = os.clock()
		repeat
			task.wait(0.1)
		until not wanted()
			or flatDistance(root.Position, waypoint.Position) < 3
			or os.clock() - startedAt > 4
	end
	return wanted() and flatDistance(root.Position, target) < 4
end

--------------------------------------------------------------------------
-- Farm tick
--------------------------------------------------------------------------
local function gate()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return "no living character"
	end
	if LocalPlayer:GetAttribute(Build.IntroAttr) == true then
		return "intro is playing"
	end
	if (LocalPlayer:GetAttribute(Build.StunAttr) or 0) > os.clock() then
		return "stunned"
	end
	if LocalPlayer:GetAttribute(Build.MegaStrawAttr) then
		return "carrying the mega straw"
	end

	local toolName = LocalPlayer:GetAttribute(Build.ToolAttr) or Build.DefaultTool
	local tool = Game.tools[toolName]
	if not tool then
		return "unknown tool: " .. tostring(toolName)
	end
	if tool.mode == "hold" then
		return "equip a scoop tool (Hose, Vacuum and Hydro Gatling are not supported)"
	end
	local capacity = LocalPlayer:GetAttribute(Build.CapacityAttr) or tool.capacity
	if not isFiniteNumber(capacity) or capacity <= 0 then
		return "capacity unreadable"
	end
	if not isFiniteNumber(tool.reach) then
		return "tool reach unreadable"
	end

	return nil, { character = character, root = root, tool = tool, capacity = capacity }
end

local function farmTick()
	local reason, ctx = gate()
	if reason then
		releaseAll()
		report("Paused: " .. reason)
		return
	end

	local carried = LocalPlayer:GetAttribute(Build.CarriedAttr) or 0
	local lakeEmpty = (Game.water:GetAttribute(Build.SpoonsLeftAttr) or 1) <= 0

	if phase == "Scoop" then
		stopPour()
		if carried >= ctx.capacity or (lakeEmpty and carried > 0) then
			stopScoop()
			phase = "Pour"
			return
		end
		if lakeEmpty then
			stopScoop()
			report("Paused: the lake is empty")
			return
		end

		local now = os.clock()
		if not aimPoint or now - aimPickedAt > Build.AimRepickSeconds then
			aimPoint = pickScoopPoint(ctx.tool.reach)
			aimPickedAt = now
		end

		if not aimPoint then
			stopScoop()
			local stand = scoopStand(ctx.tool.reach, ctx.root.Position.Y)
			if not stand then
				report("Paused: no lake point found near the PourZone")
				return
			end
			report("Walking to the lake")
			walkTo(stand)
			aimPickedAt = 0
			return
		end

		report(nil)
		if not scooping or now >= nextScoopSendAt then
			scooping = true
			nextScoopSendAt = now + Build.ScoopRefreshSeconds
			Game.scoopHold:FireServer(true, aimPoint)
		end
	else
		stopScoop()
		aimPoint = nil
		if carried <= 0 then
			stopPour()
			phase = "Scoop"
			return
		end
		if Game.grandpa:GetAttribute(Build.GrandpaStateAttr) == "Doze" then
			stopPour()
			report("Paused: Grandpa is asleep")
			return
		end
		if Game.grandpa:GetAttribute(Build.GrandpaWantsChocoAttr) == true then
			stopPour()
			report("Paused: Grandpa wants chocolate")
			return
		end
		if not inPourZone(ctx.root) then
			stopPour()
			report("Walking to Grandpa")
			walkTo(Vector3.new(Game.pourZone.Position.X, ctx.root.Position.Y, Game.pourZone.Position.Z))
			return
		end

		report(nil)
		if not pouring then
			pouring = true
			Game.pourHold:FireServer(true)
		end
	end
end

--------------------------------------------------------------------------
-- Upgrade tick: buy the cheapest affordable node in an owned, open tab
--------------------------------------------------------------------------
local function pickUpgrade()
	local st = Game.skillTree
	local coins = tonumber(LocalPlayer:GetAttribute(Build.CoinsAttr)) or 0
	local now = os.clock()
	local best = nil

	for _, id in ipairs(st.order) do
		local branch = st.branches[id]
		if branch and (failedUntil[id] or 0) <= now and st.tabInChapter(branch.tab) and st.owns(LocalPlayer, branch.tab) then
			local track = st.track(id)
			if track and st.Upg.trackOpen(branch.tab, track) then
				local level = st.levelOf(LocalPlayer, id)
				if isFiniteNumber(level) and level < st.levels(id) then
					local price = st.priceCents(id, level + 1)
					if isFiniteNumber(price) and price > 0 and price <= coins and (not best or price < best.price) then
						best = { id = id, tab = branch.tab, track = branch.track, price = price }
					end
				end
			end
		end
	end
	return best
end

local function upgradeTick()
	if (LocalPlayer:GetAttribute(Build.IntroAttr)) == true then
		return
	end
	local choice = pickUpgrade()
	if not choice then
		return
	end
	local ok, accepted, why = pcall(function()
		return Game.upgrade:InvokeServer(choice.tab, choice.track)
	end)
	if not ok or not accepted then
		failedUntil[choice.id] = os.clock() + Build.UpgradeRefusalCooldown
		warn("[LakeAutoFarm] upgrade " .. choice.id .. " refused: " .. tostring(ok and why or accepted))
	end
end

--------------------------------------------------------------------------
-- Loops
--------------------------------------------------------------------------
local function setFarm(value)
	value = value == true
	if Farm.Enabled == value then
		return
	end
	Farm.Enabled = value
	if not value then
		releaseAll()
		lastReason = nil
	end
	phase = "Scoop"
	aimPoint, aimPickedAt = nil, 0
end

task.spawn(function()
	while alive do
		if Farm.Enabled then
			local ok, err = pcall(farmTick)
			if not ok then
				setFarm(false)
				warn("[LakeAutoFarm] farm stopped after an error: " .. tostring(err))
				Notify("Farm stopped after an error, see the console")
			end
		end
		task.wait(0.1)
	end
end)

task.spawn(function()
	while alive do
		if Upgrader.Enabled then
			local ok, err = pcall(upgradeTick)
			if not ok then
				Upgrader.Enabled = false
				warn("[LakeAutoFarm] upgrader stopped after an error: " .. tostring(err))
				Notify("Auto Upgrade stopped after an error, see the console")
			end
		end
		task.wait(Build.UpgradeIntervalSeconds)
	end
end)

-- Release any held remote state if the character dies mid-hold.
local diedConnection = LocalPlayer.CharacterRemoving:Connect(function()
	releaseAll()
	phase = "Scoop"
	aimPoint = nil
end)

--------------------------------------------------------------------------
-- WindUI front end (API written from memory of Footagesus/WindUI, unverified here)
--------------------------------------------------------------------------
local okLoad, WindUI = pcall(function()
	return loadstring(game:HttpGet(Build.WindUIUrl))()
end)
if not okLoad or type(WindUI) ~= "table" then
	alive = false
	releaseAll()
	diedConnection:Disconnect()
	warn("[LakeAutoFarm] WindUI failed to load: " .. tostring(WindUI))
	return
end

local Window = WindUI:CreateWindow({
	Title = "Lake Auto Farm",
	Icon = "droplets",
	Author = "wrench",
	Folder = "LakeAutoFarm",
	Size = UDim2.fromOffset(480, 320),
	Theme = "Dark",
})

Notify = function(content)
	pcall(function()
		WindUI:Notify({ Title = "Lake Auto Farm", Content = content, Duration = 3 })
	end)
end

local Tab = Window:Tab({ Title = "Farm", Icon = "droplets" })

Tab:Toggle({
	Title = "Auto Farm",
	Desc = "Scoops the lake, walks to Grandpa and pours. Equip a scoop tool first.",
	Default = false,
	Callback = function(state)
		setFarm(state)
	end,
})

Tab:Toggle({
	Title = "Auto Upgrade",
	Desc = "Buys the cheapest affordable skill-tree node.",
	Default = false,
	Callback = function(state)
		Upgrader.Enabled = state == true
		if state then
			failedUntil = {}
		end
	end,
})

local function unload()
	alive = false
	Farm.Enabled = false
	Upgrader.Enabled = false
	releaseAll()
	diedConnection:Disconnect()
	pcall(function()
		Window:Destroy()
	end)
	env.LakeAutoFarm = nil
end

Tab:Button({
	Title = "Unload",
	Desc = "Stops everything and removes this window.",
	Callback = unload,
})

env.LakeAutoFarm = { Unload = unload }
