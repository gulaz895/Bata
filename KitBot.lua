--[[
  KitBot.lua  -  auto-player for "[⚔️] Kit PVP FFA"
  Target build : PlaceId 75260404327641, dump 2026-11-22 (Dumper v2.0). Client-side Luau, executor context.
  NOT RUN ANYWHERE YET. Written from the dump only. Every value below is tagged:
    [DUMP]    read from the dump (file named)
    [RUNTIME] read from the game's own modules/attributes while running
    [TUNING]  my choice, uncalibrated
    [ASSUMED] derived guess, verify in game
    [UNSET]   unknown; the feature that needs it is gated and says so in the log
  Design: the bot only produces REAL INPUT (VirtualInputManager) plus camera aim, so the game's own
  client code builds the Attack/ItemAction payloads. It never calls remotes itself.
  Toggle: F6.  Needs: first-person or normal back camera (front camera mode is detected and refused).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if _G.KitBot and _G.KitBot.Stop then pcall(_G.KitBot.Stop) end

---------------------------------------------------------------- config
local EXPECTED_PLACE_ID = 75260404327641 -- [DUMP] summary.txt
local KIT_ORDER = { "sword", "mace", "spearmace", "elytra", "tnt", "crystal", "archer", "orbital", "god" } -- [DUMP] GameConfig.Classes.Order
local BLOCK = 3.2 -- [DUMP] VoxelWeapons.Block

local Tuning = {
	AutoStart = true,
	ToggleKey = Enum.KeyCode.F6,
	MaxChaseDistance = 250,        -- [TUNING]
	PreferredRangeFactor = 0.62,   -- [TUNING] fraction of weapon reach to hold
	AimDegPerSec = 540,            -- [TUNING] max turn speed
	AimLambda = 14,                -- [TUNING] exponential smoothing
	AimNoiseDeg = 0.35,            -- [TUNING]
	AimTolDeg = 4.5,               -- [TUNING] aim error allowed before clicking
	ChargeThreshold = 0.92,        -- [TUNING] attack when weapon charge >= this (+ jitter)
	StrafeSwitch = { 0.6, 1.4 },   -- [TUNING] seconds
	EatBelow = 0.55,               -- [TUNING] health fraction
	EatSafeDistance = 14,          -- [TUNING] studs, no enemy closer than this when eating
	PearlMinDistance = 45,         -- [TUNING]
	BowMin = 22, BowMax = 75,      -- [TUNING] studs
	BowDraw = 0.97,                -- [DUMP] VoxelBowClient clamps draw time to 1s
	TntPlaceDistance = 13,         -- [ASSUMED] ItemClient aimPoint reach for TNT = 4.5 blocks
	TntMinHealth = 0.6,            -- [TUNING]
	TntFlee = 1.9,                 -- [ASSUMED] fuse 1.5s [DUMP] + margin
	CrystalMinHealth = 0.7,        -- [TUNING] also requires a Totem
	CrystalDistance = 12,          -- [TUNING]
	MaceComboMin = 9, MaceComboMax = 60, -- [TUNING] studs
	ElytraGlide = true,            -- [TUNING] glide approach; steering by camera look is UNVERIFIED
	ElytraMinDistance = 70,        -- [TUNING]
}

local Unset = {
	ArrowSpeed = nil,   -- [UNSET] server-side. nil => arrows are aimed straight at the target, no lead/drop
	TntRadiusStuds = 25.6, -- [ASSUMED] vanilla radius 2*power(4) blocks * 3.2 (kit text says "vanilla power-4 blast")
}

---------------------------------------------------------------- utils
local function now() return os.clock() end
local function rand(a, b) return a + math.random() * (b - a) end
local function finiteV3(v) return typeof(v) == "Vector3" and v.X == v.X and v.Y == v.Y and v.Z == v.Z and v.Magnitude < 1e6 end
local lastLog = {}
local function log(key, msg)
	if lastLog[key] and now() - lastLog[key] < 5 then return end
	lastLog[key] = now()
	print("[KitBot] " .. msg)
end

local function safeRequire(name)
	local inst = ReplicatedStorage:WaitForChild(name, 5)
	if not inst then return nil end
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end

local GameConfig = safeRequire("GameConfig")
local Weapons = safeRequire("VoxelWeapons")
local Geometry = safeRequire("VoxelMeleeGeometry")
local ControllerInput = safeRequire("ControllerInput")
local HeldItemFov = safeRequire("HeldItemFov")
local BowAmmo = safeRequire("VoxelBowAmmo")

local PB = (GameConfig and GameConfig.PracticeBots) or {}
local Human = { -- [RUNTIME] GameConfig.PracticeBots, fallback = [DUMP] values
	ViewDelay = PB.ViewDelay or 0.1,
	MissChance = PB.MissChance or 0.1,
	WTapChance = PB.WTapChance or 0.75,
	TapSeconds = PB.TapSeconds or { 0.1, 0.2 },
	JumpCritChance = PB.JumpCritChance or 0.35,
}
local Items = (GameConfig and GameConfig.Items) or {}
local function itemField(kind, field, fallback)
	local it = Items[kind]
	return it and it[field] or fallback
end

local S = { running = false, kit = "sword", kitSource = "default", inv = {} }
local Task = { cur = nil }

if game.PlaceId ~= EXPECTED_PLACE_ID then
	warn("[KitBot] PlaceId " .. tostring(game.PlaceId) .. " ~= " .. EXPECTED_PLACE_ID .. ", refusing to run (offsets/attributes are from another place).")
	return
end
if not (Weapons and Geometry and ControllerInput) then
	warn("[KitBot] could not require VoxelWeapons / VoxelMeleeGeometry / ControllerInput. Refusing to run.")
	return
end

---------------------------------------------------------------- input (real input only)
local VIM
do
	local ok, svc = pcall(function() return game:GetService("VirtualInputManager") end)
	VIM = ok and svc or nil
end
if not VIM then
	warn("[KitBot] VirtualInputManager unavailable in this environment. Refusing to run.")
	return
end

local DEFAULT_PC = { -- [DUMP] PlayerSettingsConfig defaults
	Attack = Enum.UserInputType.MouseButton1, Use = Enum.UserInputType.MouseButton2,
	Sprint = Enum.KeyCode.LeftControl, Sneak = Enum.KeyCode.LeftShift, Jump = Enum.KeyCode.Space,
}
local function bound(action)
	local k = ControllerInput.PCKeys and ControllerInput.PCKeys[action] -- [RUNTIME] honors player's rebinds
	return k or DEFAULT_PC[action]
end

local inputFails = 0
local function send(fn)
	local ok = pcall(fn)
	if not ok then
		inputFails += 1
		if inputFails > 20 then warn("[KitBot] input injection keeps failing, stopping."); if _G.KitBot then _G.KitBot.Stop() end end
	end
end

local downActions = {}
local function setAction(action, down)
	if downActions[action] == down then return end
	downActions[action] = down or nil
	local inp = bound(action)
	if not inp then return end
	local vs = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
	if inp.EnumType == Enum.UserInputType then
		local btn = (inp == Enum.UserInputType.MouseButton1 and 0) or (inp == Enum.UserInputType.MouseButton2 and 1) or 2
		send(function() VIM:SendMouseButtonEvent(vs.X / 2, vs.Y / 2, btn, down, game, 0) end)
	else
		send(function() VIM:SendKeyEvent(down, inp, false, game) end)
	end
end

local downKeys = {}
local function setKey(code, down)
	if downKeys[code] == down then return end
	downKeys[code] = down or nil
	send(function() VIM:SendKeyEvent(down, code, false, game) end)
end

local function tap(action, hold)
	setAction(action, true)
	task.delay(hold or rand(0.03, 0.07), function() setAction(action, false) end)
end

local function releaseAll()
	for a in pairs(table.clone(downActions)) do setAction(a, false) end
	for k in pairs(table.clone(downKeys)) do setKey(k, false) end
end

---------------------------------------------------------------- snapshot / inventory
local function classify(tool)
	local ci = tool:GetAttribute("ClassItem")
	if tool:GetAttribute("VoxelBow") == true or tool.Name == "Bow" then return "bow" end
	if type(ci) == "string" then return ci end
	if tool.Name == "Gold Apple" then return "GoldenApple" end
	local wt = tool:GetAttribute("WeaponType")
	if type(wt) == "string" then return wt end
	return nil
end

local function toolCount(tool) return tonumber(tool:GetAttribute("Count")) or 1 end

local lastInv = -1
local function snapshot()
	local ch = LocalPlayer.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	S.ch, S.hum, S.root = ch, hum, root
	S.alive = hum ~= nil and root ~= nil and hum.Health > 0
	S.inArena = LocalPlayer:GetAttribute("InArena") == true
	S.protected = LocalPlayer:GetAttribute("ArenaProtected") == true
	S.hpFrac = S.alive and hum.Health / math.max(1, hum.MaxHealth) or 0
	S.grounded = S.alive and hum.FloorMaterial ~= Enum.Material.Air
	S.held = ch and ch:FindFirstChildOfClass("Tool")
	if now() - lastInv > 0.25 then
		lastInv = now()
		local inv = {}
		local function scan(container)
			if not container then return end
			for _, t in ipairs(container:GetChildren()) do
				if t:IsA("Tool") then
					local k = classify(t)
					if k and toolCount(t) > 0 then
						inv[k] = inv[k] or {}
						table.insert(inv[k], t)
					end
				end
			end
		end
		scan(LocalPlayer:FindFirstChild("Backpack"))
		scan(ch)
		S.inv = inv
	end
end
local function has(kind) return S.inv[kind] ~= nil and #S.inv[kind] > 0 end

---------------------------------------------------------------- kit detection
local function isKit(id)
	if GameConfig and GameConfig.Classes and GameConfig.Classes.IsClass then
		local ok, r = pcall(GameConfig.Classes.IsClass, id)
		if ok then return r == true end
	end
	return table.find(KIT_ORDER, id) ~= nil
end

local function detectKit()
	local attr = LocalPlayer:GetAttribute("EquippedClass") -- [DUMP] SidebarScoreboard / VoxelPackHUD
	if type(attr) == "string" and isKit(attr) then return attr, "attribute" end
	if has("OrbitalStrike") then return "orbital", "inferred from inventory" end
	if has("bow") and has("spear") and has("EndCrystal") then return "god", "inferred from inventory" end
	if has("spear") then return "spearmace", "inferred from inventory" end
	if has("SwapChestplate") then return "elytra", "inferred from inventory" end
	if has("mace") then return "mace", "inferred from inventory" end
	if has("EndCrystal") then return "crystal", "inferred from inventory" end
	if has("TNT") then return "tnt", "inferred from inventory" end
	if has("bow") then return "archer", "inferred from inventory" end
	return "sword", "default"
end

-- which behaviours each kit plays. Gated again by what is actually in the backpack.
local Plans = {
	sword     = { pearl = true },
	mace      = { pearl = true, maceCombo = true },
	spearmace = { pearl = true, maceCombo = true, spear = true },
	elytra    = { pearl = true, maceCombo = true, elytra = true },
	tnt       = { pearl = true, tnt = true },
	crystal   = { pearl = true, crystal = true },
	archer    = { pearl = true, bow = true },
	orbital   = { pearl = true, crystal = true, orbital = true },
	god       = { pearl = true, maceCombo = true, spear = true, bow = true, tnt = true, crystal = true, orbital = true, elytra = true },
}

---------------------------------------------------------------- targeting
local function characterFilter()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do if p.Character then table.insert(list, p.Character) end end
	return list
end
local function visible(from, to)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = characterFilter()
	rp.IgnoreWater = true
	rp.RespectCanCollide = true
	local r = Workspace:Raycast(from, to - from, rp)
	return r == nil
end

local current
local function pickTarget()
	if not S.alive then current = nil return nil end
	local best, bestScore
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character and p:GetAttribute("InArena") == true and p:GetAttribute("ArenaProtected") ~= true then
			local ch = p.Character
			local h = ch:FindFirstChildOfClass("Humanoid")
			local r = ch:FindFirstChild("HumanoidRootPart")
			if h and r and h.Health > 0 and ch:GetAttribute("Invisible") ~= true and finiteV3(r.Position) then
				local d = (r.Position - S.root.Position).Magnitude
				if d <= Tuning.MaxChaseDistance then
					local score = d + h.Health * 0.6 - (current and current.player == p and 12 or 0) -- hysteresis
					if not bestScore or score < bestScore then best, bestScore = { player = p, ch = ch, hum = h, root = r }, score end
				end
			end
		end
	end
	if best and (not current or current.player ~= best.player) then
		best.acquiredAt = now() + Human.ViewDelay + rand(0, 0.1) -- reaction delay
	elseif best then
		best.acquiredAt = current.acquiredAt
	end
	current = best
	return best
end

---------------------------------------------------------------- aim (camera only; input path stays the game's)
local Aim = { pointFn = nil, noise = Vector3.zero, noiseAt = 0 }
local function aimError(point)
	local cam = Workspace.CurrentCamera
	local eye = Geometry.Eye(S.root.Position, S.ch:GetAttribute("Sneaking"))
	local want = (point - eye)
	if want.Magnitude < 0.01 then return 0 end
	return math.deg(math.acos(math.clamp(cam.CFrame.LookVector:Dot(want.Unit), -1, 1)))
end

local function aimStep(dt)
	if not (S.running and S.alive and Aim.pointFn) then return end
	if LocalPlayer:GetAttribute("FrontCameraAimDirection") ~= nil then
		log("front", "front camera mode active: the game ignores camera aim there. Switch to first person / back view.")
		return
	end
	local cam = Workspace.CurrentCamera
	local point = Aim.pointFn()
	if not finiteV3(point) then return end
	if now() > Aim.noiseAt then
		Aim.noiseAt = now() + rand(0.15, 0.4)
		local n = math.rad(Tuning.AimNoiseDeg)
		Aim.noise = Vector3.new(rand(-n, n), rand(-n, n), rand(-n, n))
	end
	local eye = Geometry.Eye(S.root.Position, S.ch:GetAttribute("Sneaking"))
	local want = (point - eye)
	if want.Magnitude < 0.01 then return end
	want = (want.Unit + Aim.noise)
	want = Vector3.new(want.X, math.clamp(want.Y, -0.985, 0.985), want.Z).Unit -- avoid degenerate straight up/down
	local look = cam.CFrame.LookVector
	local ang = math.acos(math.clamp(look:Dot(want), -1, 1))
	if ang < 1e-4 then return end
	local step = math.min(ang, ang * (1 - math.exp(-Tuning.AimLambda * dt)), math.rad(Tuning.AimDegPerSec) * dt)
	local a = CFrame.lookAt(Vector3.zero, look):Lerp(CFrame.lookAt(Vector3.zero, want), step / ang)
	cam.CFrame = CFrame.lookAt(cam.CFrame.Position, cam.CFrame.Position + a.LookVector)
end

---------------------------------------------------------------- movement (real keys: W/A/S/D/Space)
local Move = { fwd = false, back = false, left = false, right = false }
local function applyMove()
	setKey(Enum.KeyCode.W, Move.fwd and S.alive)
	setKey(Enum.KeyCode.S, Move.back and S.alive)
	setKey(Enum.KeyCode.A, Move.left and S.alive)
	setKey(Enum.KeyCode.D, Move.right and S.alive)
end
local function stopMove() Move.fwd, Move.back, Move.left, Move.right = false, false, false, false end

local function groundAhead(dir)
	local origin = S.root.Position + dir * 6 + Vector3.new(0, 2, 0)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = characterFilter()
	rp.RespectCanCollide = true
	return Workspace:Raycast(origin, Vector3.new(0, -80, 0), rp) ~= nil
end
local function blockedAhead(dir)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = characterFilter()
	rp.RespectCanCollide = true
	return Workspace:Raycast(S.root.Position + Vector3.new(0, -1.5, 0), dir * 4, rp) ~= nil
end

---------------------------------------------------------------- task runner
local function sleep(tok, t)
	local e = now() + t
	while now() < e do
		if tok.cancelled or not S.alive or not S.running then return false end
		task.wait()
	end
	return true
end
local function runTask(name, fn)
	if Task.cur then return false end
	local tok = { name = name, cancelled = false }
	Task.cur = tok
	task.spawn(function()
		local ok, err = pcall(fn, tok)
		if not ok then log("task" .. name, "task '" .. name .. "' error: " .. tostring(err)) end
		Aim.pointFn = nil
		setAction("Use", false); setAction("Attack", false)
		stopMove(); applyMove()
		Task.cur = nil
	end)
	return true
end

local function equip(tok, kind)
	local list = S.inv[kind]
	local tool = list and list[1]
	if not tool or not S.hum then return false end
	if S.held ~= tool then
		S.hum:UnequipTools() -- [DUMP] same calls VoxelPackHUD makes
		S.hum:EquipTool(tool)
		local t0 = now()
		while S.ch:FindFirstChildOfClass("Tool") ~= tool do
			if now() - t0 > 0.7 or not sleep(tok, 0.02) then return false end
		end
		S.held = tool
		if not sleep(tok, rand(0.04, 0.11)) then return false end
	end
	return true
end

local lastUse = {}
local function itemReady(kind)
	local cd = math.max(itemField(kind, "useDelay", 0.36) + 0.01, (itemField(kind, "cooldown", 0) or 0))
	if now() - (lastUse[kind] or -1e9) < cd then return false end
	local attr = tonumber(LocalPlayer:GetAttribute("ItemCooldown_" .. kind)) or 0 -- [DUMP] ItemClient
	return attr <= Workspace:GetServerTimeNow() + 0.05
end

local function aimUntil(tok, fn, timeout)
	Aim.pointFn = fn
	local t0 = now()
	while now() - t0 < (timeout or 1) do
		if tok.cancelled or not S.alive then return false end
		if aimError(fn()) < Tuning.AimTolDeg then return true end
		task.wait()
	end
	return false
end

local function useClassItem(tok, kind, fn)
	if not has(kind) or not itemReady(kind) then return false end
	if not equip(tok, kind) then return false end
	aimUntil(tok, fn, 0.9)
	if tok.cancelled or not S.alive then return false end
	lastUse[kind] = now()
	tap("Use", rand(0.04, 0.08))
	return sleep(tok, 0.12)
end

local function charge()
	if HeldItemFov and type(HeldItemFov.Charge) == "function" then
		local ok, c = pcall(HeldItemFov.Charge)
		if ok and type(c) == "number" then return c end
	end
	return 1
end

local function canHit(tg, reach)
	local eye = Geometry.Eye(S.root.Position, S.ch:GetAttribute("Sneaking"))
	local look = Workspace.CurrentCamera.CFrame.LookVector
	local d = Geometry.Hit(eye, look, tg.root.Position, tg.ch:GetAttribute("Sneaking"), reach) -- [DUMP] same test the game runs
	return d ~= nil and visible(eye, tg.root.Position + Vector3.new(0, 0.3, 0))
end
local function heldReach() return Weapons.Held(S.ch).reach end
local function bodyPoint(tg) return tg.root.Position + Vector3.new(0, 0.3, 0) end
local function feetPoint(tg) return tg.root.Position - Vector3.new(0, 3, 0) end

---------------------------------------------------------------- behaviours
local function tHeal(tok)
	if not equip(tok, "GoldenApple") then return end
	Aim.pointFn = nil
	setAction("Use", true)
	if not sleep(tok, 0.45) then setAction("Use", false) return end
	local t0 = now()
	while S.ch:GetAttribute("EatingApple") == true and now() - t0 < 3.2 do
		if not sleep(tok, 0.05) then break end
	end
	setAction("Use", false)
end

local lastBuff = { SpeedPotion = -1e9, StrengthPotion = -1e9 }
local function tBuff(tok, kind)
	local ok = useClassItem(tok, kind, function() return S.root.Position + Vector3.new(0.2, -12, 0.2) end)
	if ok then lastBuff[kind] = now() end
end
local function wantBuff(kind)
	if not has(kind) then return false end
	local secs = itemField(kind, "seconds", 90) -- [DUMP] 90
	if kind == "SpeedPotion" then
		local e = tonumber(S.ch:GetAttribute("Effect_speed")) or 0 -- [DUMP] attribute name seen in VoxelCombatClient
		if e > 0 and now() - lastBuff[kind] < secs then return false end
	end
	return now() - lastBuff[kind] > secs - 6 -- Effect_strength name is UNVERIFIED, so strength is timer-based
end

local function tPearl(tok, tg)
	useClassItem(tok, "Pearl", function() return tg.root.Position + Vector3.new(0, 1.5, 0) end)
end

local function tBow(tok, tg)
	local bowTool = S.inv.bow and S.inv.bow[1]
	local ammo = bowTool and BowAmmo and select(2, pcall(BowAmmo.Count, LocalPlayer, bowTool)) or 1
	if type(ammo) ~= "number" or ammo < 1 then return end
	if (tonumber(LocalPlayer:GetAttribute("BowNextShotAt")) or 0) > Workspace:GetServerTimeNow() then return end
	if not equip(tok, "bow") then return end
	if Unset.ArrowSpeed == nil then log("arrow", "ArrowSpeed [UNSET]: shooting without lead or drop compensation.") end
	local function point()
		local p = bodyPoint(tg)
		if Unset.ArrowSpeed then
			local t = (p - S.root.Position).Magnitude / Unset.ArrowSpeed
			p += tg.root.AssemblyLinearVelocity * t
		end
		return p
	end
	aimUntil(tok, point, 0.8)
	setAction("Use", true) -- [DUMP] hold Use = Draw
	local t0 = now()
	while now() - t0 < Tuning.BowDraw + rand(0, 0.03) do
		if not sleep(tok, 0.02) then setAction("Use", false) return end
	end
	setAction("Use", false) -- release = shoot toward camera look
	sleep(tok, 0.2)
end

local function tMaceCombo(tok, tg)
	if not (has("mace") and has("WindCharge")) or not itemReady("WindCharge") then return end
	if not useClassItem(tok, "WindCharge", function() return S.root.Position + Vector3.new(0.1, -12, 0.1) end) then return end
	if not equip(tok, "mace") then return end
	local t0 = now()
	Move.fwd = true
	while now() - t0 < 3.2 and S.alive and tg.hum.Health > 0 do
		Aim.pointFn = function() return bodyPoint(tg) end
		Move.fwd = true; applyMove()
		local vy = S.root.AssemblyLinearVelocity.Y
		if vy < -2 and canHit(tg, heldReach()) and aimError(bodyPoint(tg)) < Tuning.AimTolDeg and charge() >= 0.95 then
			tap("Attack"); sleep(tok, 0.25); break
		end
		if S.grounded and now() - t0 > 0.8 then break end
		if not sleep(tok, 0.03) then return end
	end
end

local function tSpear(tok, tg)
	if not equip(tok, "spear") then return end
	local t0 = now()
	while now() - t0 < 2.2 and tg.hum.Health > 0 do
		Aim.pointFn = function() return bodyPoint(tg) end
		Move.fwd = true; applyMove()
		if canHit(tg, heldReach()) and charge() >= 0.98 and aimError(bodyPoint(tg)) < Tuning.AimTolDeg then
			tap("Attack"); sleep(tok, 0.3); break
		end
		if not sleep(tok, 0.03) then return end
	end
	equip(tok, "sword")
end

local function fleeFrom(tok, pos, secs)
	local t0 = now()
	while now() - t0 < secs do
		local away = (S.root.Position - pos) * Vector3.new(1, 0, 1)
		if away.Magnitude < 0.1 then away = -S.root.CFrame.LookVector end
		local tgt = S.root.Position + away.Unit * 40
		Aim.pointFn = function() return tgt end
		Move.fwd = true; applyMove()
		if not sleep(tok, 0.05) then return end
	end
	stopMove(); applyMove()
end

local function tTnt(tok, tg)
	local spot = feetPoint(tg)
	if not useClassItem(tok, "TNT", function() return spot end) then return end
	fleeFrom(tok, spot, Tuning.TntFlee)
end

local function nearestCrystal(pos)
	local folder = Workspace:FindFirstChild("EndCrystals") -- [DUMP] VoxelCombatClient.crystalPick
	if not folder then return nil end
	local best, bd
	for _, c in ipairs(folder:GetChildren()) do
		local f = c:GetAttribute("CrystalFeet")
		if typeof(f) == "Vector3" then
			local d = (f - pos).Magnitude
			if not bd or d < bd then best, bd = f, d end
		end
	end
	return best, bd
end

local function tCrystal(tok, tg)
	local spot = feetPoint(tg)
	if has("Obsidian") then useClassItem(tok, "Obsidian", function() return spot end) end
	if tok.cancelled then return end
	if not useClassItem(tok, "EndCrystal", function() return spot end) then return end
	if not sleep(tok, 0.15) then return end
	local feet = nearestCrystal(spot)
	if not feet then log("crystal", "no crystal appeared after placing (placement rules are server-side, UNVERIFIED).") return end
	equip(tok, "sword")
	local t0 = now()
	while now() - t0 < 1.6 do
		local f = nearestCrystal(spot)
		if not f then break end
		local center = f + Vector3.new(0, 3.2, 0)
		Aim.pointFn = function() return center end
		if (center - S.root.Position).Magnitude <= heldReach() and aimError(center) < Tuning.AimTolDeg and charge() >= 0.9 then
			tap("Attack"); sleep(tok, 0.2)
		end
		if not sleep(tok, 0.03) then return end
	end
end

local function tOrbital(tok, tg)
	useClassItem(tok, "OrbitalStrike", function() return feetPoint(tg) end)
end

local elytraCooldown = -1e9
local function tElytra(tok, tg)
	if S.ch:GetAttribute("ArmorChest") ~= "Elytra" then
		if has("SwapElytra") then useClassItem(tok, "SwapElytra", function() return S.root.Position + S.root.CFrame.LookVector * 20 end) end
		if S.ch:GetAttribute("ArmorChest") ~= "Elytra" then elytraCooldown = now() + 20 return end
	end
	Aim.pointFn = function() return tg.root.Position + Vector3.new(0, 10, 0) end
	Move.fwd = true; applyMove()
	tap("Jump", 0.05); if not sleep(tok, 0.35) then return end
	tap("Jump", 0.05) -- [DUMP] glide starts on a fresh jump press while airborne wearing Elytra
	local t0 = now()
	while now() - t0 < 2 and LocalPlayer:GetAttribute("LocalGliding") ~= true do if not sleep(tok, 0.05) then return end end
	if LocalPlayer:GetAttribute("LocalGliding") ~= true then
		log("glide", "glide did not start; elytra approach paused 20s (trigger conditions UNVERIFIED).")
		elytraCooldown = now() + 20 return
	end
	local lastRocket = 0
	t0 = now()
	while now() - t0 < 9 and LocalPlayer:GetAttribute("LocalGliding") == true and tg.hum.Health > 0 do
		-- steering by camera look is UNVERIFIED
		Aim.pointFn = function() return tg.root.Position + Vector3.new(0, 2, 0) end
		if has("FireworkRocket") and now() - lastRocket > 1.3 then
			lastRocket = now()
			local k = S.inv.FireworkRocket[1]
			if S.held ~= k then equip(tok, "FireworkRocket") end
			tap("Use")
		end
		if (tg.root.Position - S.root.Position).Magnitude < 28 then break end
		if not sleep(tok, 0.05) then return end
	end
	if has("SwapChestplate") then useClassItem(tok, "SwapChestplate", function() return bodyPoint(tg) end) end
	if has("mace") then
		equip(tok, "mace")
		t0 = now()
		while now() - t0 < 2.5 and tg.hum.Health > 0 do
			Aim.pointFn = function() return bodyPoint(tg) end
			if canHit(tg, heldReach()) and aimError(bodyPoint(tg)) < Tuning.AimTolDeg and charge() >= 0.95 then tap("Attack"); break end
			if not sleep(tok, 0.03) then return end
		end
	end
	equip(tok, "sword")
end

---------------------------------------------------------------- melee + chase (default loop)
local Melee = { strafeDir = 1, strafeUntil = 0, wtapUntil = 0, jumpUntil = 0, missUntil = 0, nextJump = 0, lastPos = nil, lastProg = 0, stuck = 0 }

local function meleeStep(tg, dt)
	local reach = heldReach()
	local toT = (tg.root.Position - S.root.Position)
	local flat = toT * Vector3.new(1, 0, 1)
	local dist = flat.Magnitude
	if S.held == nil or classify(S.held) ~= "sword" and classify(S.held) ~= "mace" and classify(S.held) ~= "spear" and classify(S.held) ~= "axe" then
		local tk = S.inv.sword and S.inv.sword[1]
		if tk then S.hum:UnequipTools(); S.hum:EquipTool(tk) end
	end
	Aim.pointFn = function() return bodyPoint(tg) end
	local pref = math.max(3.5, reach * Tuning.PreferredRangeFactor) -- 3.5 = [DUMP] PracticeBots.MinDistance
	Move.left, Move.right = false, false
	local dirFlat = dist > 0.01 and flat.Unit or S.root.CFrame.LookVector

	if now() > Melee.strafeUntil then
		Melee.strafeUntil = now() + rand(Tuning.StrafeSwitch[1], Tuning.StrafeSwitch[2])
		Melee.strafeDir = (math.random() < 0.5) and -1 or 1
	end
	local wtap = now() < Melee.wtapUntil
	if dist > pref then
		Move.fwd = not wtap and groundAhead(dirFlat)
		Move.back = false
		if dist < reach * 1.5 then Move.left, Move.right = Melee.strafeDir < 0, Melee.strafeDir > 0 end
	else
		Move.fwd = false
		Move.back = dist < pref * 0.6
		Move.left, Move.right = Melee.strafeDir < 0, Melee.strafeDir > 0
	end

	-- obstacles / stuck
	if Move.fwd and blockedAhead(dirFlat) and S.grounded and now() > Melee.nextJump then
		Melee.nextJump = now() + 0.6; tap("Jump", 0.08)
	end
	if Melee.lastPos and Move.fwd then
		if (S.root.Position - Melee.lastPos).Magnitude < 0.6 * dt * 10 then Melee.stuck += dt else Melee.stuck = 0 end
		if Melee.stuck > 1.2 then Melee.stuck = 0; Melee.strafeDir = -Melee.strafeDir; tap("Jump", 0.08) end
	end
	Melee.lastPos = S.root.Position

	-- jump-crit sometimes
	if S.grounded and dist < reach * 1.2 and dist > reach * 0.5 and now() > Melee.nextJump and math.random() < Human.JumpCritChance * dt then
		Melee.nextJump = now() + 1.2; tap("Jump", 0.08); Melee.jumpUntil = now() + 0.45
	end

	-- attack
	local airborneRising = now() < Melee.jumpUntil and S.root.AssemblyLinearVelocity.Y > 0.5
	if now() > Melee.missUntil and not airborneRising and now() >= tg.acquiredAt then
		if canHit(tg, reach) and aimError(bodyPoint(tg)) < Tuning.AimTolDeg + 2 and charge() >= Tuning.ChargeThreshold + rand(0, 0.07) then
			if math.random() < Human.MissChance then
				Melee.missUntil = now() + rand(0.08, 0.2) -- human hesitation
			else
				tap("Attack", rand(0.03, 0.06))
				if math.random() < Human.WTapChance then
					Melee.wtapUntil = now() + rand(Human.TapSeconds[1], Human.TapSeconds[2])
				end
			end
		end
	end
end

---------------------------------------------------------------- decision
local function decide(tg, dt)
	local plan = Plans[S.kit] or Plans.sword
	local dist = (tg.root.Position - S.root.Position).Magnitude
	local nearest = dist -- FFA: only the chosen target matters for the safety check

	if S.hpFrac <= Tuning.EatBelow and has("GoldenApple") and nearest > Tuning.EatSafeDistance then
		return runTask("heal", tHeal)
	end
	if now() < tg.acquiredAt then return false end
	for _, k in ipairs({ "SpeedPotion", "StrengthPotion" }) do
		if dist < 70 and wantBuff(k) then return runTask("buff", function(t) tBuff(t, k) end) end
	end
	if plan.orbital and has("OrbitalStrike") and itemReady("OrbitalStrike") and dist < itemField("OrbitalStrike", "reach", 64) * BLOCK - 10 and visible(S.root.Position, tg.root.Position) then
		return runTask("orbital", function(t) tOrbital(t, tg) end)
	end
	if plan.elytra and Tuning.ElytraGlide and now() > elytraCooldown and dist > Tuning.ElytraMinDistance and S.grounded and (has("SwapElytra") or S.ch:GetAttribute("ArmorChest") == "Elytra") then
		return runTask("elytra", function(t) tElytra(t, tg) end)
	end
	if plan.pearl and has("Pearl") and itemReady("Pearl") and dist > Tuning.PearlMinDistance and visible(S.root.Position, tg.root.Position) then
		return runTask("pearl", function(t) tPearl(t, tg) end)
	end
	if plan.bow and has("bow") and dist > Tuning.BowMin and dist < Tuning.BowMax and visible(S.root.Position, tg.root.Position) then
		return runTask("bow", function(t) tBow(t, tg) end)
	end
	if plan.maceCombo and S.grounded and dist > Tuning.MaceComboMin and dist < Tuning.MaceComboMax and S.hpFrac > 0.4 then
		return runTask("maceCombo", function(t) tMaceCombo(t, tg) end)
	end
	if plan.spear and has("spear") and dist > 11 and dist < 4.5 * BLOCK - 1 and S.grounded then
		return runTask("spear", function(t) tSpear(t, tg) end)
	end
	if plan.tnt and has("TNT") and dist < Tuning.TntPlaceDistance and S.hpFrac >= Tuning.TntMinHealth then
		log("tnt", "TNT radius is [ASSUMED] " .. Unset.TntRadiusStuds .. " studs; fleeing after placement.")
		return runTask("tnt", function(t) tTnt(t, tg) end)
	end
	if plan.crystal and (has("EndCrystal")) and has("Totem") and S.hpFrac >= Tuning.CrystalMinHealth and dist < Tuning.CrystalDistance then
		return runTask("crystal", function(t) tCrystal(t, tg) end)
	end
	return false
end

---------------------------------------------------------------- main
local conns = {}
local lastKitCheck = 0
local statusGui

local function setStatus(text)
	if not statusGui then
		local ok = pcall(function()
			local g = Instance.new("ScreenGui")
			g.Name = "KitBotStatus"; g.ResetOnSpawn = false; g.DisplayOrder = 999
			local l = Instance.new("TextLabel")
			l.Size = UDim2.fromOffset(330, 20); l.Position = UDim2.new(0, 6, 1, -26)
			l.BackgroundTransparency = 0.5; l.BackgroundColor3 = Color3.new(0, 0, 0)
			l.TextColor3 = Color3.new(1, 1, 1); l.TextXAlignment = Enum.TextXAlignment.Left
			l.Font = Enum.Font.Code; l.TextSize = 13; l.Parent = g
			g.Parent = LocalPlayer:WaitForChild("PlayerGui")
			statusGui = l
		end)
		if not ok then return end
	end
	statusGui.Text = text
end

local function think(dt)
	if not S.running then return end
	snapshot()
	if now() - lastKitCheck > 1 then
		lastKitCheck = now()
		local k, src = detectKit()
		if k ~= S.kit then log("kit", "kit -> " .. k .. " (" .. src .. ")") end
		S.kit, S.kitSource = k, src
	end
	if not S.alive or not S.inArena or S.protected then
		if Task.cur then Task.cur.cancelled = true end
		Aim.pointFn = nil; stopMove(); applyMove(); releaseAll()
		setStatus("KitBot | idle (not in arena / dead / protected) | kit " .. S.kit)
		return
	end
	if ControllerInput.IsBlocked() then stopMove(); applyMove(); releaseAll(); setStatus("KitBot | input blocked by a menu") return end
	local tg = pickTarget()
	if not tg then
		Aim.pointFn = nil; stopMove(); applyMove()
		setStatus("KitBot | no target | kit " .. S.kit)
		return
	end
	setStatus(("KitBot | %s (%s) | target %s | %s"):format(S.kit, S.kitSource, tg.player.Name, Task.cur and Task.cur.name or "melee"))
	if Task.cur then return end
	if not decide(tg, dt) then
		meleeStep(tg, dt)
		applyMove()
	end
end

local function start()
	if S.running then return end
	S.running = true
	log("start", "started. kit detection: EquippedClass attribute, inventory fallback.")
end
local function stop()
	S.running = false
	if Task.cur then Task.cur.cancelled = true end
	Aim.pointFn = nil
	stopMove(); releaseAll()
	setStatus("KitBot | stopped")
end

table.insert(conns, RunService.Heartbeat:Connect(think))
RunService:BindToRenderStep("KitBotAim", Enum.RenderPriority.Camera.Value + 5, aimStep)
table.insert(conns, UserInputService.InputBegan:Connect(function(i, gp)
	if not gp and i.KeyCode == Tuning.ToggleKey then if S.running then stop() else start() end end
end))
table.insert(conns, UserInputService.WindowFocusReleased:Connect(function() releaseAll() end))
table.insert(conns, LocalPlayer.CharacterRemoving:Connect(function()
	if Task.cur then Task.cur.cancelled = true end
	stopMove(); releaseAll()
end))

_G.KitBot = {
	Start = start, Stop = function()
		stop()
		for _, c in ipairs(conns) do c:Disconnect() end
		pcall(function() RunService:UnbindFromRenderStep("KitBotAim") end)
		if statusGui and statusGui.Parent then statusGui.Parent:Destroy() end
		_G.KitBot = nil
	end,
	State = S, Tuning = Tuning,
}

if Tuning.AutoStart then start() end
