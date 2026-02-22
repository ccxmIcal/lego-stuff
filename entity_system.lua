--[[

TroopsHandler (server)

- Each TroopsHandler instance = 1 troop owned by 1 player.
- The troop is driven by a simple state machine:
    "Patrol"  -> walks a fixed path of nodes
    "Attack"  -> stops movement (implicitly) and repeatedly deals damage if target stays valid + in range
    "Capture" -> after finishing patrol, roams randomly inside the center zone while still reacting to enemies
- Two concurrent loops (threads) can exist:
    PatrolThread: controls movement along nodes (and later triggers capture)
    AttackThread: controls repeated damage ticks against a single target
  The "State" field is the coordination mechanism that prevents both loops from fighting over behavior.

Important design decisions:
- Guard clauses keep the troop from doing work if it's dead or unequipped.
- Threads are cancelled before starting a new one to avoid duplicated loops (memory leaks / double damage / weird state).
- GetEnemyInRange is called frequently; it’s intentionally simple and short-circuits fast.

Interactions:
- FlagHandler.Zone:trackItem / untrackItem registers the troop in a zone system (likely for capture logic / scoring / counting occupants).
- Overhead + Animate are attached server-side so the troop is fully self-contained after spawning.

]]

-- Roblox services
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathFindingService = game:GetService("PathfindingService")

-- Shared assets (available on both client + server)
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules")
local ReplicatedAnims = ReplicatedStorage:WaitForChild("Animations")

-- Server-only assets
local ServerModules = ServerStorage:WaitForChild("Modules")
local ServerOverheads = ServerStorage:WaitForChild("Overheads")

-- Data / helpers
local TroopsData = require(ReplicatedModules.TroopsData)
local Types = require(ReplicatedModules.Types)
local LevelsHelper = require(ReplicatedModules.LevelsHelper)

-- External system the troop integrates with (zones / flag capture)
local FlagHandler = require(ServerModules.FlagHandler)

-- Zones are set up once globally. We spawn it so TroopsHandler construction doesn't block on setup.
task.spawn(FlagHandler.SetupZones, FlagHandler)

-- TroopsHandler "class"
local TroopsHandler: Types.TroopClass = {} do
	TroopsHandler.__index = TroopsHandler

	-- =====================
	-- CONSTRUCTOR
	-- =====================
	function TroopsHandler.new(player: Player, TroopName: string, TroopLevel: number, SpawnCFrame: CFrame)
		local self = setmetatable({}, TroopsHandler)

		-- Pull base configuration from TroopsData once.
		-- We then derive final stats (damage/health) by applying the level multipliers,
		-- so runtime logic never needs to re-check the data table.
		local Data = TroopsData[TroopName]

		self.Player = player
		self.Name = TroopName
		self.Level = TroopLevel
		self.SpawnCFrame = SpawnCFrame

		-- Runtime flags:
		-- Alive     -> model exists and is expected to be doing behavior
		-- Unequipped-> permanent stop; prevents respawn and ends loops
		self.Alive = false
		self.Unequipped = false

		-- State is the single source of truth for behavior.
		-- Threads read this value to decide if they should continue.
		self.State = "Patrol"

		-- Keep thread handles so we can cancel them before starting new ones.
		-- This avoids "stacking loops" (double movement, double damage ticks).
		self.PatrolThread = nil
		self.AttackThread = nil

		self.Stats = {
			-- Level scaling is applied up-front so combat is O(1) per tick.
			Damage = LevelsHelper:CalculateLevelDamage(Data.TroopData.Damage, self.Level),
			Health = LevelsHelper:CalculateLevelHealth(Data.TroopData.Health, self.Level),

			-- These are constant per troop type (no scaling here).
			WalkSpeed = Data.TroopData.WalkSpeed,
			RespawnTime = Data.TroopData.RespawnTime,
			AttackSpeed = Data.TroopData.AttackSpeed,
			Range = Data.TroopData.Range
		}

		-- Patrol config:
		-- The troop walks nodes in order and once it finishes, it transitions to Capture mode.
		self.PatrolNodes = workspace.Map.PatrolPaths.Path:GetChildren()
		self.CurrentNode = 1
		self.CompletedPatrol = false

		-- Center zone used by capture logic (random roam within bounds).
		self.CenterZone = workspace.Map.Center.Zone

		-- Spawn starts the state machine by creating the model, wiring events, and starting patrol.
		self:SpawnModel()

		return self
	end

	-- =====================
	-- SPAWN MODEL
	-- =====================
	function TroopsHandler:SpawnModel()
		-- Guard: if player unequipped this troop, we never want to respawn it.
		if self.Unequipped then return end

		-- Create a fresh model each time (including after respawn).
		-- This simplifies cleanup: we can destroy the whole model on death and reset references.
		self.Model = workspace.Map.Troops:WaitForChild(self.Name).CharacterModel:Clone()
		self.Model.Name = self.Name

		-- Attributes let other systems identify troop ownership without holding references to this handler.
		-- This is important for cross-module communication and for filtering enemies.
		self.Model:SetAttribute("Owner", self.Player.Name)
		self.Model:SetAttribute("Troop", true)

		-- Register with zone system.
		-- The zone system likely tracks occupancy counts and triggers capture scoring.
		FlagHandler.Zone:trackItem(self.Model)

		-- Attach animation controller script so the NPC can play default humanoid animations.
		-- Keeping this here ensures troop models are self-sufficient after being spawned.
		local animate = ServerModules.Imports:FindFirstChild("Animate")
		if animate then
			local AnimateClone = animate:Clone()
			AnimateClone.Parent = self.Model
			AnimateClone.Enabled = true
		end

		-- Attach overhead UI to communicate identity to players.
		-- This is server-side so all clients see consistent overheads (and avoids trusting clients).
		local OverheadGui = ServerOverheads.TroopOverHead
		if OverheadGui then
			local OverClone = OverheadGui:Clone()
			OverClone.TextLabel.Text = ` {self.Name} [{self.Level}] `
			OverClone.ImageLabel.Image = Players:GetUserThumbnailAsync(
				self.Player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
			OverClone.Parent = self.Model.Head
		end

		-- Collision group assignment ensures troops behave predictably in physics.
		-- Doing it for every part prevents “one part forgot collision group” bugs.
		for _, v in next, self.Model:GetChildren() do
			if v:IsA("BasePart") or v:IsA("MeshPart") then
				v.CollisionGroup = "Players"
			end
		end

		self.Model:PivotTo(self.SpawnCFrame)
		self.Model.Parent = workspace.Map.SpawnedTroops

		-- Humanoid is the core driver for health + movement.
		-- If a troop model doesn't have one, behavior can't run (so we exit early).
		self.Humanoid = self.Model:FindFirstChildOfClass("Humanoid")
		if not self.Humanoid then return end

		-- Cache animator + pre-load the troop’s attack animation.
		-- Loading once avoids repeated LoadAnimation overhead during combat.
		self.Animator = self.Humanoid:WaitForChild("Animator")
		self.AttackAnimation = self.Animator:LoadAnimation(ReplicatedAnims:FindFirstChild(self.Name))
		self.AttackAnimation.Priority = Enum.AnimationPriority.Action

		-- Apply stats once on spawn.
		self.Humanoid.MaxHealth = self.Stats.Health
		self.Humanoid.Health = self.Stats.Health
		self.Humanoid.WalkSpeed = self.Stats.WalkSpeed

		-- At this point the troop is considered “alive” and eligible to run its loops.
		self.Alive = true
		self.State = "Patrol"

		-- On death:
		-- - remove from zone tracking immediately
		-- - transition handler into cleanup + optional respawn
		self.Humanoid.Died:Connect(function()
			FlagHandler.Zone:untrackItem(self.Model)
			self:OnDeath()
		end)

		-- Start the main behavior loop.
		self:StartPatrol()
	end

	-- =====================
	-- ENEMY SCAN
	-- =====================
	function TroopsHandler:GetEnemyInRange()
		-- Guard: if model is missing or not fully initialized, scanning isn't possible.
		if not self.Model or not self.Model.PrimaryPart then return nil end

		local origin = self.Model.PrimaryPart.Position

		-- This is a simple “nearest valid in range” scan.
		-- It returns the first found enemy in range; it does not attempt to find the closest.
		-- That’s a deliberate tradeoff: faster + simpler logic.
		for _, troop in next, workspace.Map.SpawnedTroops:GetChildren() do
			-- Filter:
			-- - exclude self
			-- - must be a troop
			-- - must belong to another player
			if troop ~= self.Model
				and troop:GetAttribute("Troop")
				and troop:GetAttribute("Owner") ~= self.Player.Name then

				local hum = troop:FindFirstChildOfClass("Humanoid")
				local root = troop.PrimaryPart

				-- Validate target is alive and has a root part.
				if hum and hum.Health > 0 and root then
					-- Distance check is the “aggro” gate.
					-- If within range, we begin Attack mode.
					if (root.Position - origin).Magnitude <= self.Stats.Range then
						return troop, hum
					end
				end
			end
		end
	end

	-- =====================
	-- GIVE DAMAGE
	-- =====================
	function TroopsHandler:GiveDamage(enemyHumanoid: Humanoid)
		-- Guard: don’t waste work if target already dead or invalid.
		if not enemyHumanoid or enemyHumanoid.Health <= 0 then return end

		-- Animation is triggered at the same cadence as damage ticks.
		-- We only call Play if it isn't already running to prevent restarts each tick.
		if self.AttackAnimation and not self.AttackAnimation.IsPlaying then
			self.AttackAnimation:Play()
		end

		enemyHumanoid:TakeDamage(self.Stats.Damage)
	end

	-- =====================
	-- ATTACK LOOP
	-- =====================
	function TroopsHandler:StartAttack(targetModel, targetHumanoid)
		-- If we were already attacking something else, stop that loop.
		-- Without this, you can end up with multiple AttackThreads ticking damage concurrently.
		if self.AttackThread then
			task.cancel(self.AttackThread)
		end

		-- State flip is the coordination mechanism:
		-- Patrol/Capture loops will see State != "Patrol"/"Capture" and back off.
		self.State = "Attack"

		self.AttackThread = task.spawn(function()
			-- Attack loop is intentionally “self-terminating”:
			-- it exits when target is invalid/out-of-range/dead, and restores state.
			while self.Alive and self.State == "Attack" do
				-- Target lost (deleted / despawned / died)
				if not targetModel or not targetModel.Parent or targetHumanoid.Health <= 0 then
					-- We return to Patrol unless we already completed the patrol path,
					-- in which case we resume Capture behavior.
					self.State = self.CompletedPatrol and "Capture" or "Patrol"
					return
				end

				-- Range re-check prevents “infinite sniping” where the troop keeps damaging
				-- after target has walked away.
				local dist = (targetModel.PrimaryPart.Position - self.Model.PrimaryPart.Position).Magnitude
				if dist > self.Stats.Range then
					self.State = self.CompletedPatrol and "Capture" or "Patrol"
					return
				end

				-- Tick damage and wait based on attack speed.
				self:GiveDamage(targetHumanoid)
				task.wait(self.Stats.AttackSpeed)
			end
		end)
	end

	-- =====================
	-- MOVE TO (PATHFINDING)
	-- =====================
	function TroopsHandler:MoveTo(Position: Vector3)
		-- Guard: moving a dead troop causes errors or stalls.
		if not self.Alive or not self.Humanoid then return end

		-- Pathfinding is used so troops can navigate around obstacles.
		-- Tradeoff: CreatePath+ComputeAsync is heavier than direct MoveTo,
		-- but avoids troops getting stuck on walls.
		local Path = PathFindingService:CreatePath()
		Path:ComputeAsync(self.Model.PrimaryPart.Position, Position)

		-- If path fails, we do nothing (troop will try again next tick).
		if Path.Status ~= Enum.PathStatus.Success then return end

		-- Walk waypoints sequentially. MoveToFinished yields, so this is “blocking movement”
		-- inside the loop, but behavior threads still exist concurrently.
		for _, wp in next, Path:GetWaypoints() do
			if not self.Alive then return end
			self.Humanoid:MoveTo(wp.Position)
			self.Humanoid.MoveToFinished:Wait()
		end
	end

	-- =====================
	-- PATROL LOOP
	-- =====================
	function TroopsHandler:StartPatrol()
		-- Cancel existing patrol loop so we never duplicate movement logic.
		if self.PatrolThread then
			task.cancel(self.PatrolThread)
		end

		self.PatrolThread = task.spawn(function()
			-- Patrol is the "default" behavior until the patrol route completes.
			while self.Alive and not self.Unequipped do
				-- Opportunistic combat: even while patrolling, we can switch to attack instantly.
				local enemy, hum = self:GetEnemyInRange()
				if enemy then
					self:StartAttack(enemy, hum)
				end

				-- If we're not in Patrol state, we pause briefly and retry.
				-- This makes PatrolThread “yield control” to AttackThread without exiting.
				if self.State ~= "Patrol" then
					task.wait(0.25)
					continue
				end

				-- Move toward the current patrol node.
				local node = self.PatrolNodes[self.CurrentNode]
				if node then
					self:MoveTo(node.Position)
				end

				-- Advance to next node.
				self.CurrentNode += 1

				-- Finishing patrol triggers the next phase:
				-- we mark CompletedPatrol so Attack can later return us to Capture (not Patrol).
				if self.CurrentNode > #self.PatrolNodes then
					self.CompletedPatrol = true
					self.State = "Capture"
					self:StartCapture()
					return
				end

				-- Small delay avoids a hot loop and gives time for state changes to be noticed.
				task.wait(0.25)
			end
		end)
	end

	-- =====================
	-- CAPTURE FLAG BEHAVIOR
	-- =====================
	function TroopsHandler:StartCapture()
		-- Capture uses its own loop (separate from PatrolThread),
		-- because patrol is “done” and we no longer need node indexing logic.
		task.spawn(function()
			while self.Alive and self.State == "Capture" do
				-- Same combat priority: capturing troops should still defend themselves.
				local enemy, hum = self:GetEnemyInRange()
				if enemy then
					self:StartAttack(enemy, hum)
				end

				-- Random roaming within the zone:
				-- This keeps troops moving and “occupying” the area,
				-- while relying on FlagHandler.Zone tracking to handle scoring/capture.
				local zoneCF = self.CenterZone.CFrame
				local size = self.CenterZone.Size / 2

				local randomPos = zoneCF.Position + Vector3.new(
					math.random(-size.X, size.X),
					0,
					math.random(-size.Z, size.Z)
				)

				self:MoveTo(randomPos)
				task.wait(1)
			end
		end)
	end

	-- =====================
	-- DEATH / CLEANUP + RESPAWN
	-- =====================
	function TroopsHandler:OnDeath()
		-- First flip flags so all loops naturally stop.
		self.Alive = false

		-- Hard-cancel threads to prevent them holding references (leaks)
		-- or continuing to run with a destroyed model.
		if self.PatrolThread then task.cancel(self.PatrolThread) end
		if self.AttackThread then task.cancel(self.AttackThread) end

		-- Destroy model to fully reset physics + humanoid state.
		-- This is safer than trying to “reset” health/movement on the same instance.
		if self.Model then
			self.Model:Destroy()
			self.Model = nil
			self.Humanoid = nil
		end

		-- Stop animation to avoid animation objects persisting between spawns.
		if self.AttackAnimation then
			self.AttackAnimation:Stop()
			self.AttackAnimation = nil
		end

		-- If troop was unequipped, death should be final (no respawn).
		if self.Unequipped then return end

		-- Respawn after delay, but only if still equipped at that time.
		-- This check matters because the player might unequip during respawn wait.
		task.delay(self.Stats.RespawnTime, function()
			if not self.Unequipped then
				self:SpawnModel()
			end
		end)
	end

	-- =====================
	-- UNEQUIP (PERMANENT STOP)
	-- =====================
	function TroopsHandler:Unequip()
		-- Unequip is the “final shutdown” path.
		-- We set Unequipped first so any future respawn attempts immediately abort.
		self.Unequipped = true
		self.Alive = false

		-- Cancel loops to stop behavior immediately.
		if self.PatrolThread then task.cancel(self.PatrolThread) end
		if self.AttackThread then task.cancel(self.AttackThread) end

		-- If model exists, untrack from zones and destroy.
		-- Untracking here avoids ghost occupancy if unequipped while alive.
		if self.Model then
			FlagHandler.Zone:untrackItem(self.Model)
			self.Model:Destroy()
			self.Model = nil
			self.Humanoid = nil
		end

		-- Stop attack animation if it was loaded.
		if self.AttackAnimation then
			self.AttackAnimation:Stop()
			self.AttackAnimation = nil
		end
	end
end

return TroopsHandler
