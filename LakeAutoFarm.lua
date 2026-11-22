--!nocheck
-- LakeAutoFarm.lua  v2  |  client executor script, WindUI front end
-- Built from the Dumper v2.0 dump of PlaceId 134148497865430 (2026-11-22, dump 3).
-- Not run in-game by the author. See the status notes delivered with this file.
--
-- Loop: collect water -> walk to Grandpa -> deliver -> repeat, for every tool in Config.Tools.
--   Scoop tools (Spoon, Glass, Buckets, Tub, Aquarium, Canteen): ScoopHold / PourHold.
--   Hold tools  (Hose, Vacuum, SuperSoaker): HoseState "fill" / "spray" / "stop".
-- Auto Upgrade is an independent toggle that buys the cheapest affordable skill-tree node.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------
-- Build-dependent values. Every entry names where it came from (all [Z3]).
--------------------------------------------------------------------------
local Build = {
	PlaceId = 134148497865430, -- summary.txt

	RemotesFolder = "Remotes", -- ReplicatedStorage.Remotes, hierarchy.txt
	ScoopHold = "ScoopHold", -- RemoteEvent. ScoopController: FireServer(true, waterPoint) / FireServer(false)
	PourHold = "PourHold", -- RemoteEvent. PourController: FireServer(true) / FireServer(false)
	HoseState = "HoseState", -- RemoteEvent. HoseController: FireServer("fill", point) / ("spray") / ("stop")
	Upgrade = "Upgrade", -- RemoteFunction. SkillTreeController: InvokeServer(tab, track) -> ok, reason

	ToolsConfigPath = { "Config", "Tools" },
	SkillTreePath = { "SkillTree" }, -- SkillTree.Upg is the Upgrades module (stat, BOTTOMLESS_CAP, trackOpen)
	LakeShapePath = { "Lake", "LakeShape" }, -- hasWater(x, z, level)

	-- Workspace objects. ScoopController / PourController / HoseController
	MapName = "Map",
	WaterName = "Water", -- Map.Water, attribute SpoonsLeft; its top face is the water level
	BasinCollisionName = "BasinCollision",
	GrandpaAreaName = "GrandpaArea",
	PourZoneName = "PourZone", -- Part, attribute Radius
	GrandpaName = "Grandpa",
	PourZoneDefaultRadius = 4.5, -- PourController.inZone
	PourZoneSlack = 0.5, -- PourController.inZone
	HoseRingSlack = 1, -- HoseController.inRing
	MouthLocalOffset = Vector3.new(0, -0.68, -0.45), -- HoseController.mouthTarget, relative to Grandpa's Head

	-- LocalPlayer attributes
	ToolAttr = "Tool", -- missing means "Spoon" (ScoopController)
	DefaultTool = "Spoon",
	CarriedAttr = "Carried",
	CapacityAttr = "Capacity", -- falls back to Upgrades.stat(..., "capacity"), then Tools[tool].capacity
	StunAttr = "DedaStunUntil", -- compared against os.clock()
	MegaStrawAttr = "MegaStrawCarrying",
	IntroAttr = "InIntro", -- SkillTreeController
	CoinsAttr = "CoinsCents", -- SkillTreeController

	SpoonsLeftAttr = "SpoonsLeft", -- Map.Water attribute; <= 0 means drained (ScoopController.aimPoint)
	GrandpaStateAttr = "DedaState", -- "Doze" means asleep (PourController.startPour)
	GrandpaWantsChocoAttr = "DedaWantsChoco",

	ScoopRefreshSeconds = 0.2, -- ScoopController re-sends the aim point every 0.2 s
	HoseSendSeconds = 0.15, -- HoseController re-sends the state every 0.15 s
	HoseReachMargin = 0.4, -- HoseController.aimWater: reach - 0.4
	ScoopReachMargin = 0.4, -- ASSUMPTION: same safety margin as the hose; ScoopController itself uses reach with no margin

	-- Tuning (not from the game)
	BottomlessCapFallback = 1000000, -- Upgrades.BOTTOMLESS_CAP, used only if that field is missing
	BottomlessTripScoops = 12, -- UNCALIBRATED: scoops per delivery trip for infinite-capacity tools (Canteen)
	AimRepickSeconds = 1.0,
	StandCacheSeconds = 10,
	StandLevelTolerance = 0.25, -- re-plan the standing spot when the water level moves more than this
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
	G.hoseState, err = need(remotes, Build.HoseState, "RemoteEvent")
	if not G.hoseState then return fail(err) end
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
	if type(st.Upg.trackOpen) ~= "function" or type(st.Upg.stat) ~= "function" then
		return fail("SkillTree.Upg.trackOpen or .stat is not a function")
	end
	G.upg = st.Upg
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
local phase = "Collect" -- "Collect" or "Deliver"
local scooping, pouring, hoseActive = false, false, false
local hoseLastState, hoseLastSendAt = nil, 0
local nextScoopSendAt = 0
local aimPoint, aimPickedAt = nil, 0
local standCache = nil -- { pos = Vector3, level = number, reach = number, at = number }
local squeeze = 0 -- studs to move closer to the water after arriving without a valid aim
local justWalkedToLake = false
local lastReason, lastNotifyAt = nil, 0
local failedUntil = {}
local connections = {}
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
-- Remote helpers (every "active" send has a matching stop)
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

local function stopHose()
	if hoseActive then
		hoseActive = false
		hoseLastState = "stop"
		Game.hoseState:FireServer("stop")
	end
end

local function sendHose(state, point)
	local now = os.clock()
	if state ~= hoseLastState or now - hoseLastSendAt >= Build.HoseSendSeconds then
		hoseLastState = state
		hoseLastSendAt = now
		hoseActive = true
		Game.hoseState:FireServer(state, point)
	end
end

local function releaseAll()
	stopScoop()
	stopPour()
	stopHose()
end

local function stopCollect(kind)
	if kind == "Scoop" then stopScoop() else stopHose() end
end

local function stopDeliver(kind)
	if kind == "Scoop" then stopPour() else stopHose() end
end

--------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------
local function waterLevel()
	return Game.water.Position.Y + Game.water.Size.Y / 2 -- read live, the lake level changes
end

local function characterList()
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	if workspace.CurrentCamera then
		table.insert(list, workspace.CurrentCamera)
	end
	return list
end

local basinParams = RaycastParams.new()
basinParams.FilterType = Enum.RaycastFilterType.Include
basinParams.FilterDescendantsInstances = { Game.basin }

local obstructionParams = RaycastParams.new()
obstructionParams.FilterType = Enum.RaycastFilterType.Exclude
obstructionParams.RespectCanCollide = true

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true

-- Mirrors the two obstruction tests in ScoopController.aimPoint.
local function scoopPathClear(origin, target)
	local delta = target - origin
	local distance = delta.Magnitude
	local basinHit = workspace:Raycast(origin, delta, basinParams)
	if basinHit and (basinHit.Position - origin).Magnitude < distance - 0.6 then
		return false
	end
	obstructionParams.FilterDescendantsInstances = characterList()
	if distance > 0.7 and workspace:Raycast(origin, delta.Unit * (distance - 0.6), obstructionParams) then
		return false
	end
	return true
end

-- Mirrors HoseController.sightBlocked for tools with fillNeedsSight.
local function hoseSightClear(origin, target)
	local delta = target - origin
	sightParams.FilterDescendantsInstances = characterList()
	return workspace:Raycast(origin, delta.Unit * math.max(0.1, delta.Magnitude - 0.2), sightParams) == nil
end

local function groundHeight(x, z, hintY)
	local ignore = characterList()
	table.insert(ignore, Game.water)
	groundParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(Vector3.new(x, math.max(hintY, waterLevel()) + 80, z), Vector3.new(0, -300, 0), groundParams)
	return hit and hit.Position.Y or hintY
end

local DIRECTIONS = 16

-- Nearest lake point to `center`, searching outward in rings, honouring the current water level.
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

local function eyeOffsetOf(character, root)
	local head = character:FindFirstChild("Head")
	local offset = head and (head.Position.Y - root.Position.Y) or 1.5
	return math.clamp(offset, 0.5, 4)
end

-- Per-kind "can reach this water point from this eye position" test.
local function makeReachTest(ctx)
	return function(eye, point)
		if (point - eye).Magnitude > ctx.reachBudget or point.Y >= eye.Y then
			return false
		end
		if ctx.kind == "Scoop" then
			return scoopPathClear(eye, point)
		end
		if ctx.cfg.fillNeedsSight then
			return hoseSightClear(eye, point)
		end
		return true
	end
end

-- A lake point the server should accept right now from where the player stands, or nil.
local function pickAimPoint(ctx)
	local camera = workspace.CurrentCamera
	local origin
	if ctx.kind == "Scoop" and camera then
		origin = camera.CFrame.Position -- ScoopController aims from the camera
	else
		origin = ctx.head and ctx.head.Position or ctx.root.Position -- HoseController aims from the head
	end
	local reachTest = makeReachTest(ctx)
	return nearestWaterPoint(ctx.root.Position, 2, math.floor(ctx.reachBudget), 2, function(point)
		return reachTest(origin, point)
	end)
end

-- Where to stand so a collection is possible at the CURRENT water level.
-- Searches from the spot nearest the PourZone toward the water and checks the real 3D distance from eye height,
-- so a receded shoreline (lower level, larger drop to the surface) pulls the standing spot closer to the water.
local function collectStand(ctx)
	local level = waterLevel()
	local now = os.clock()
	if standCache
		and now - standCache.at < Build.StandCacheSeconds
		and math.abs(standCache.level - level) <= Build.StandLevelTolerance
		and standCache.reach == ctx.reachBudget
		and standCache.squeeze == squeeze
	then
		return standCache.pos
	end

	local pour = Game.pourZone.Position
	local lakePoint = nearestWaterPoint(pour, 2, 250, 4)
	if not lakePoint then
		return nil
	end

	local flat = Vector3.new(pour.X - lakePoint.X, 0, pour.Z - lakePoint.Z)
	local direction = flat.Magnitude > 0.5 and flat.Unit or Vector3.new(1, 0, 0)
	local maxBack = math.min(flat.Magnitude, ctx.reachBudget) - squeeze
	local reachTest = makeReachTest(ctx)

	local chosen = nil
	for back = math.max(maxBack, 0), 0, -1 do
		local x = lakePoint.X + direction.X * back
		local z = lakePoint.Z + direction.Z * back
		local ground = groundHeight(x, z, ctx.root.Position.Y)
		if reachTest(Vector3.new(x, ground + ctx.eyeOffset, z), lakePoint) then
			chosen = Vector3.new(x, ground + 1, z)
			break
		end
	end
	if not chosen then
		chosen = Vector3.new(lakePoint.X, groundHeight(lakePoint.X, lakePoint.Z, ctx.root.Position.Y) + 1, lakePoint.Z)
	end

	standCache = { pos = chosen, level = level, reach = ctx.reachBudget, squeeze = squeeze, at = now }
	standCache.reach = ctx.reachBudget
	return chosen
end

local function mouthPoint()
	local head = Game.grandpa:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head.CFrame:PointToWorldSpace(Build.MouthLocalOffset)
	end
	return nil
end

local function inPourZone(root)
	local radius = (Game.pourZone:GetAttribute("Radius") or Build.PourZoneDefaultRadius) + Build.PourZoneSlack
	return flatDistance(root.Position, Game.pourZone.Position) <= radius
end

local function canSprayFrom(ctx)
	local mouth = mouthPoint()
	if not mouth then
		return false
	end
	if not ctx.cfg.sprayAnywhere then
		local radius = (Game.pourZone:GetAttribute("Radius") or Build.PourZoneDefaultRadius) + Build.HoseRingSlack
		if flatDistance(ctx.root.Position, Game.pourZone.Position) > radius then
			return false
		end
	end
	local camera = workspace.CurrentCamera
	local origin = camera and camera.CFrame.Position or ctx.root.Position
	return (mouth - origin).Magnitude <= ctx.sprayRange
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
local function toolStat(toolName, cfg, key)
	local ok, value = pcall(Game.upg.stat, LocalPlayer, toolName, key)
	if ok and isFiniteNumber(value) then
		return value
	end
	return cfg[key]
end

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
	local cfg = Game.tools[toolName]
	if type(cfg) ~= "table" then
		return "unknown tool: " .. tostring(toolName)
	end
	local kind = cfg.mode == "hold" and "Hose" or "Scoop"

	local capacity = LocalPlayer:GetAttribute(Build.CapacityAttr) or toolStat(toolName, cfg, "capacity")
	if not isFiniteNumber(capacity) or capacity <= 0 then
		return "capacity unreadable"
	end
	local bottomless = Game.upg.BOTTOMLESS_CAP or Build.BottomlessCapFallback
	local tripTarget = capacity
	if capacity >= bottomless then
		local perScoop = toolStat(toolName, cfg, "scoopAmount")
		perScoop = isFiniteNumber(perScoop) and perScoop > 0 and perScoop or 1
		tripTarget = perScoop * Build.BottomlessTripScoops
	end

	local reach
	if kind == "Hose" then
		reach = toolStat(toolName, cfg, "reach")
	else
		reach = cfg.reach
	end
	if not isFiniteNumber(reach) then
		return "tool reach unreadable"
	end
	local margin = kind == "Hose" and Build.HoseReachMargin or Build.ScoopReachMargin
	local sprayRange = kind == "Hose" and toolStat(toolName, cfg, "sprayRange") or nil
	if kind == "Hose" and not isFiniteNumber(sprayRange) then
		return "spray range unreadable"
	end

	local head = character:FindFirstChild("Head")
	return nil, {
		character = character,
		root = root,
		head = head,
		toolName = toolName,
		cfg = cfg,
		kind = kind,
		tripTarget = tripTarget,
		reachBudget = reach - margin,
		sprayRange = sprayRange,
		eyeOffset = eyeOffsetOf(character, root),
	}
end

local function farmTick()
	local reason, ctx = gate()
	if reason then
		releaseAll()
		report("Paused: " .. reason)
		return
	end

	local kind = ctx.kind
	local carried = LocalPlayer:GetAttribute(Build.CarriedAttr) or 0
	local lakeEmpty = (Game.water:GetAttribute(Build.SpoonsLeftAttr) or 1) <= 0

	if phase == "Collect" then
		if carried >= ctx.tripTarget or (lakeEmpty and carried > 0) then
			stopCollect(kind)
			phase = "Deliver"
			return
		end
		if lakeEmpty then
			stopCollect(kind)
			report("Paused: the lake is empty")
			return
		end

		local now = os.clock()
		if not aimPoint or now - aimPickedAt > Build.AimRepickSeconds then
			aimPoint = pickAimPoint(ctx)
			aimPickedAt = now
		end

		if not aimPoint then
			stopCollect(kind)
			if justWalkedToLake then
				-- Arrived but still nothing reachable: stand closer to the water next time.
				squeeze = math.min(squeeze + 1.5, ctx.reachBudget)
				standCache = nil
			end
			local stand = collectStand(ctx)
			if not stand then
				report("Paused: no lake point found near the PourZone")
				return
			end
			report("Walking to the lake")
			justWalkedToLake = true
			if not walkTo(stand) and wanted() then
				report("Could not reach the lake shore")
			end
			aimPickedAt = 0
			return
		end

		justWalkedToLake, squeeze = false, 0
		report(nil)
		if kind == "Scoop" then
			if not scooping or now >= nextScoopSendAt then
				scooping = true
				nextScoopSendAt = now + Build.ScoopRefreshSeconds
				Game.scoopHold:FireServer(true, aimPoint)
			end
		else
			sendHose("fill", aimPoint)
		end
	else
		aimPoint = nil
		if carried <= 0 then
			stopDeliver(kind)
			phase = "Collect"
			return
		end
		if Game.grandpa:GetAttribute(Build.GrandpaStateAttr) == "Doze" then
			stopDeliver(kind)
			report("Paused: Grandpa is asleep")
			return
		end
		if Game.grandpa:GetAttribute(Build.GrandpaWantsChocoAttr) == true then
			stopDeliver(kind)
			report("Paused: Grandpa wants chocolate")
			return
		end

		local inPlace
		if kind == "Scoop" then
			inPlace = inPourZone(ctx.root)
		else
			inPlace = canSprayFrom(ctx)
		end
		if not inPlace then
			stopDeliver(kind)
			report("Walking to Grandpa")
			local zone = Game.pourZone.Position
			if not walkTo(Vector3.new(zone.X, ctx.root.Position.Y, zone.Z)) and wanted() then
				report("Could not reach Grandpa's PourZone")
			end
			return
		end

		report(nil)
		if kind == "Scoop" then
			if not pouring then
				pouring = true
				Game.pourHold:FireServer(true)
			end
		else
			sendHose("spray", nil)
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
	if LocalPlayer:GetAttribute(Build.IntroAttr) == true then
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
-- Loops and lifecycle
--------------------------------------------------------------------------
local function resetPlan()
	phase = "Collect"
	aimPoint, aimPickedAt = nil, 0
	standCache = nil
	squeeze, justWalkedToLake = 0, false
end

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
	resetPlan()
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

-- Release held remote state and re-plan if the character dies or the tool changes mid-run.
table.insert(connections, LocalPlayer.CharacterRemoving:Connect(function()
	releaseAll()
	resetPlan()
end))
table.insert(connections, LocalPlayer:GetAttributeChangedSignal(Build.ToolAttr):Connect(function()
	releaseAll()
	resetPlan()
end))

local function disconnectAll()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

--------------------------------------------------------------------------
-- WindUI front end (API written from memory of Footagesus/WindUI, unverified here)
--------------------------------------------------------------------------
local okLoad, WindUI = pcall(function()
	return loadstring(game:HttpGet(Build.WindUIUrl))()
end)
if not okLoad or type(WindUI) ~= "table" then
	alive = false
	releaseAll()
	disconnectAll()
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
	Desc = "Works with whichever tool you have equipped, including Hose, Vacuum and Hydro Gatling.",
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
	disconnectAll()
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
