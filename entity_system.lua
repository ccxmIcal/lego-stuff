local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathFindingService = game:GetService("PathfindingService")

local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules")
local ReplicatedAnims = ReplicatedStorage:WaitForChild("Animations")

local ServerModules = ServerStorage:WaitForChild("Modules")
local ServerOverheads = ServerStorage:WaitForChild("Overheads")

local TroopsData = require(ReplicatedModules.TroopsData)
local Types = require(ReplicatedModules.Types)
local LevelsHelper = require(ReplicatedModules.LevelsHelper)

local FlagHandler = require(ServerModules.FlagHandler)

task.spawn(FlagHandler.SetupZones, FlagHandler)

local TroopsHandler: Types.TroopClass = {} do
	TroopsHandler.__index = TroopsHandler

	-- =====================
	-- CONSTRUCTOR
	-- =====================
	function TroopsHandler.new(player: Player, TroopName: string, TroopLevel: number, SpawnCFrame: CFrame)
		local self = setmetatable({}, TroopsHandler)

		local Data = TroopsData[TroopName]

		self.Player = player
		self.Name = TroopName
		self.Level = TroopLevel
		self.SpawnCFrame = SpawnCFrame

		self.Alive = false
		self.Unequipped = false
		self.State = "Patrol"

		self.PatrolThread = nil
		self.AttackThread = nil

		self.Stats = {
			Damage = LevelsHelper:CalculateLevelDamage(Data.TroopData.Damage, self.Level),
			Health = LevelsHelper:CalculateLevelHealth(Data.TroopData.Health, self.Level),
			WalkSpeed = Data.TroopData.WalkSpeed,
			RespawnTime = Data.TroopData.RespawnTime,
			AttackSpeed = Data.TroopData.AttackSpeed,
			Range = Data.TroopData.Range
		}

		self.PatrolNodes = workspace.Map.PatrolPaths.Path:GetChildren()
		self.CurrentNode = 1
		self.CompletedPatrol = false

		self.CenterZone = workspace.Map.Center.Zone

		self:SpawnModel()

		return self
	end

	-- =====================
	-- SPAWN MODEL
	-- =====================
	function TroopsHandler:SpawnModel()
		if self.Unequipped then return end

		self.Model = workspace.Map.Troops:WaitForChild(self.Name).CharacterModel:Clone()
		self.Model.Name = self.Name

		self.Model:SetAttribute("Owner", self.Player.Name)
		self.Model:SetAttribute("Troop", true)

		FlagHandler.Zone:trackItem(self.Model)

		local animate = ServerModules.Imports:FindFirstChild("Animate")
		if animate then
			local AnimateClone = animate:Clone()
			AnimateClone.Parent = self.Model
			AnimateClone.Enabled = true
		end

		local OverheadGui = ServerOverheads.TroopOverHead
		if OverheadGui then
			local OverClone = OverheadGui:Clone()
			OverClone.TextLabel.Text = ` {self.Name} [{self.Level}] `
			OverClone.ImageLabel.Image = Players:GetUserThumbnailAsync(self.Player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
			OverClone.Parent = self.Model.Head
		end

		for _, v in next, self.Model:GetChildren() do
			if v:IsA("BasePart") or v:IsA("MeshPart") then
				v.CollisionGroup = "Players"
			end
		end

		self.Model:PivotTo(self.SpawnCFrame)
		self.Model.Parent = workspace.Map.SpawnedTroops

		self.Humanoid = self.Model:FindFirstChildOfClass("Humanoid")
		if not self.Humanoid then return end
		
		local Animator = self.Humanoid:WaitForChild("Animator")
		self.Animator = Animator
		
		self.AttackAnimation = self.Animator:LoadAnimation(ReplicatedAnims:FindFirstChild(self.Name))
		self.AttackAnimation.Priority = Enum.AnimationPriority.Action

		self.Humanoid.MaxHealth = self.Stats.Health
		self.Humanoid.Health = self.Stats.Health
		self.Humanoid.WalkSpeed = self.Stats.WalkSpeed

		self.Alive = true
		self.State = "Patrol"

		self.Humanoid.Died:Connect(function()
			FlagHandler.Zone:untrackItem(self.Model)
			self:OnDeath()
		end)

		self:StartPatrol()
	end

	-- =====================
	-- ENEMY SCAN
	-- =====================
	function TroopsHandler:GetEnemyInRange()
		if not self.Model or not self.Model.PrimaryPart then return nil end

		local origin = self.Model.PrimaryPart.Position

		for _, troop in next, workspace.Map.SpawnedTroops:GetChildren() do
			if troop ~= self.Model
				and troop:GetAttribute("Troop")
				and troop:GetAttribute("Owner") ~= self.Player.Name then

				local hum = troop:FindFirstChildOfClass("Humanoid")
				local root = troop.PrimaryPart

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

		if self.AttackAnimation then
			if not self.AttackAnimation.IsPlaying then
				self.AttackAnimation:Play()
			end
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
				if not targetModel
					or not targetModel.Parent
					or targetHumanoid.Health <= 0 then
					self.State = self.CompletedPatrol and "Capture" or "Patrol"
					return
				end

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
	-- MOVE TO
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
				local enemy, hum = self:GetEnemyInRange()
				if enemy then
					self:StartAttack(enemy, hum)
				end

				if self.State ~= "Patrol" then
					task.wait(0.25)
					continue
				end

				local node = self.PatrolNodes[self.CurrentNode]
				if node then
					self:MoveTo(node.Position)
				end

				self.CurrentNode += 1
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
	-- CAPTURE FLAG
	-- =====================
	function TroopsHandler:StartCapture()
		task.spawn(function()
			while self.Alive and self.State == "Capture" do
				local enemy, hum = self:GetEnemyInRange()
				if enemy then
					self:StartAttack(enemy, hum)
				end

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
	-- DEATH
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

		if self.Unequipped then return end

		task.delay(self.Stats.RespawnTime, function()
			if not self.Unequipped then
				self:SpawnModel()
			end
		end)
	end

	-- =====================
	-- UNEQUIP
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
