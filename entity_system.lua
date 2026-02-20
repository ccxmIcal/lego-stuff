-- Roblox services
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathFindingService = game:GetService("PathfindingService")

-- Shared assets
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules")
local ReplicatedAnims = ReplicatedStorage:WaitForChild("Animations")

-- Server-only assets
local ServerModules = ServerStorage:WaitForChild("Modules")
local ServerOverheads = ServerStorage:WaitForChild("Overheads")

-- Data / helpers
local TroopsData = require(ReplicatedModules.TroopsData)
local Types = require(ReplicatedModules.Types)
local LevelsHelper = require(ReplicatedModules.LevelsHelper)

-- Flag capture system
local FlagHandler = require(ServerModules.FlagHandler)

-- Initialize flag zones on server start
task.spawn(FlagHandler.SetupZones, FlagHandler)

-- TroopsHandler "class"
local TroopsHandler: Types.TroopClass = {} do
	TroopsHandler.__index = TroopsHandler

	-- =====================
	-- CONSTRUCTOR
	-- =====================
	function TroopsHandler.new(player: Player, TroopName: string, TroopLevel: number, SpawnCFrame: CFrame)
		local self = setmetatable({}, TroopsHandler)

		-- Base troop config from data table
		local Data = TroopsData[TroopName]

		-- Owner + identity
		self.Player = player
		self.Name = TroopName
		self.Level = TroopLevel
		self.SpawnCFrame = SpawnCFrame

		-- Runtime state flags
		self.Alive = false
		self.Unequipped = false
		self.State = "Patrol"

		-- Threads for patrol + attacking
		self.PatrolThread = nil
		self.AttackThread = nil

		-- Final stats (scaled by level)
		self.Stats = {
			Damage = LevelsHelper:CalculateLevelDamage(Data.TroopData.Damage, self.Level),
			Health = LevelsHelper:CalculateLevelHealth(Data.TroopData.Health, self.Level),
			WalkSpeed = Data.TroopData.WalkSpeed,
			RespawnTime = Data.TroopData.RespawnTime,
			AttackSpeed = Data.TroopData.AttackSpeed,
			Range = Data.TroopData.Range
		}

		-- Patrol path nodes
		self.PatrolNodes = workspace.Map.PatrolPaths.Path:GetChildren()
		self.CurrentNode = 1
		self.CompletedPatrol = false

		-- Center capture zone
		self.CenterZone = workspace.Map.Center.Zone

		-- Spawn physical model
		self:SpawnModel()

		return self
	end

	-- =====================
	-- SPAWN MODEL
	-- =====================
	function TroopsHandler:SpawnModel()
		if self.Unequipped then return end

		-- Clone troop model
		self.Model = workspace.Map.Troops:WaitForChild(self.Name).CharacterModel:Clone()
		self.Model.Name = self.Name

		-- Attributes used for identification
		self.Model:SetAttribute("Owner", self.Player.Name)
		self.Model:SetAttribute("Troop", true)

		-- Register with flag system
		FlagHandler.Zone:trackItem(self.Model)

		-- Add Animate script
		local animate = ServerModules.Imports:FindFirstChild("Animate")
		if animate then
			local AnimateClone = animate:Clone()
			AnimateClone.Parent = self.Model
			AnimateClone.Enabled = true
		end

		-- Overhead UI (name, level, player avatar)
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

		-- Set collision group for all parts
		for _, v in next, self.Model:GetChildren() do
			if v:IsA("BasePart") or v:IsA("MeshPart") then
				v.CollisionGroup = "Players"
			end
		end

		-- Position model
		self.Model:PivotTo(self.SpawnCFrame)
		self.Model.Parent = workspace.Map.SpawnedTroops

		-- Grab humanoid
		self.Humanoid = self.Model:FindFirstChildOfClass("Humanoid")
		if not self.Humanoid then return end

		-- Animator + attack animation
		self.Animator = self.Humanoid:WaitForChild("Animator")
		self.AttackAnimation = self.Animator:LoadAnimation(ReplicatedAnims:FindFirstChild(self.Name))
		self.AttackAnimation.Priority = Enum.AnimationPriority.Action

		-- Apply stats
		self.Humanoid.MaxHealth = self.Stats.Health
		self.Humanoid.Health = self.Stats.Health
		self.Humanoid.WalkSpeed = self.Stats.WalkSpeed

		self.Alive = true
		self.State = "Patrol"

		-- Death listener
		self.Humanoid.Died:Connect(function()
			FlagHandler.Zone:untrackItem(self.Model)
			self:OnDeath()
		end)

		-- Begin patrol loop
		self:StartPatrol()
	end

	-- =====================
	-- ENEMY SCAN
	-- =====================
	function TroopsHandler:GetEnemyInRange()
		if not self.Model or not self.Model.PrimaryPart then return nil end

		local origin = self.Model.PrimaryPart.Position

		-- Loop through all spawned troops
		for _, troop in next, workspace.Map.SpawnedTroops:GetChildren() do
			if troop ~= self.Model
				and troop:GetAttribute("Troop")
				and troop:GetAttribute("Owner") ~= self.Player.Name then

				local hum = troop:FindFirstChildOfClass("Humanoid")
				local root = troop.PrimaryPart

				-- Valid alive enemy inside range
				if hum and hum.Health > 0 and root then
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
		if not enemyHumanoid or enemyHumanoid.Health <= 0 then return end

		-- Play attack animation if not already playing
		if self.AttackAnimation and not self.AttackAnimation.IsPlaying then
			self.AttackAnimation:Play()
		end

		enemyHumanoid:TakeDamage(self.Stats.Damage)
	end

	-- =====================
	-- ATTACK LOOP
	-- =====================
	function TroopsHandler:StartAttack(targetModel, targetHumanoid)
		if self.AttackThread then
			task.cancel(self.AttackThread)
		end

		self.State = "Attack"

		self.AttackThread = task.spawn(function()
			while self.Alive and self.State == "Attack" do
				-- Target lost or dead
				if not targetModel or not targetModel.Parent or targetHumanoid.Health <= 0 then
					self.State = self.CompletedPatrol and "Capture" or "Patrol"
					return
				end

				-- Out of range
				local dist = (targetModel.PrimaryPart.Position - self.Model.PrimaryPart.Position).Magnitude
				if dist > self.Stats.Range then
					self.State = self.CompletedPatrol and "Capture" or "Patrol"
					return
				end

				self:GiveDamage(targetHumanoid)
				task.wait(self.Stats.AttackSpeed)
			end
		end)
	end

	-- =====================
	-- MOVE USING PATHFINDING
	-- =====================
	function TroopsHandler:MoveTo(Position: Vector3)
		if not self.Alive or not self.Humanoid then return end

		local Path = PathFindingService:CreatePath()
		Path:ComputeAsync(self.Model.PrimaryPart.Position, Position)

		if Path.Status ~= Enum.PathStatus.Success then return end

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
		if self.PatrolThread then
			task.cancel(self.PatrolThread)
		end

		self.PatrolThread = task.spawn(function()
			while self.Alive and not self.Unequipped do
				-- Check for nearby enemies
				local enemy, hum = self:GetEnemyInRange()
				if enemy then
					self:StartAttack(enemy, hum)
				end

				if self.State ~= "Patrol" then
					task.wait(0.25)
					continue
				end

				-- Move to next patrol node
				local node = self.PatrolNodes[self.CurrentNode]
				if node then
					self:MoveTo(node.Position)
				end

				self.CurrentNode += 1

				-- Patrol finished → capture mode
				if self.CurrentNode > #self.PatrolNodes then
					self.CompletedPatrol = true
					self.State = "Capture"
					self:StartCapture()
					return
				end

				task.wait(0.25)
			end
		end)
	end

	-- =====================
	-- CAPTURE FLAG LOOP
	-- =====================
	function TroopsHandler:StartCapture()
		task.spawn(function()
			while self.Alive and self.State == "Capture" do
				-- Still attack enemies while capturing
				local enemy, hum = self:GetEnemyInRange()
				if enemy then
					self:StartAttack(enemy, hum)
				end

				-- Random roaming inside center zone
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
	-- DEATH HANDLING
	-- =====================
	function TroopsHandler:OnDeath()
		self.Alive = false

		if self.PatrolThread then task.cancel(self.PatrolThread) end
		if self.AttackThread then task.cancel(self.AttackThread) end

		if self.Model then
			self.Model:Destroy()
			self.Model = nil
			self.Humanoid = nil
		end

		if self.AttackAnimation then
			self.AttackAnimation:Stop()
			self.AttackAnimation = nil
		end

		-- Respawn unless unequipped
		if self.Unequipped then return end

		task.delay(self.Stats.RespawnTime, function()
			if not self.Unequipped then
				self:SpawnModel()
			end
		end)
	end

	-- =====================
	-- UNEQUIP (PERMANENT REMOVAL)
	-- =====================
	function TroopsHandler:Unequip()
		self.Unequipped = true
		self.Alive = false

		if self.PatrolThread then task.cancel(self.PatrolThread) end
		if self.AttackThread then task.cancel(self.AttackThread) end

		if self.Model then
			FlagHandler.Zone:untrackItem(self.Model)
			self.Model:Destroy()
			self.Model = nil
			self.Humanoid = nil
		end

		if self.AttackAnimation then
			self.AttackAnimation:Stop()
			self.AttackAnimation = nil
		end
	end
end

return TroopsHandler
