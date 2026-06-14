--[=[
	@class ServerAuthToolkit

	Server-authoritative movement toolkit for Roblox Input Actions and client
	prediction.

	Register movement modules and animations, then call `Start` on both the server
	and client. Modules run each simulation step in priority order and replicate
	state through root-part attributes.
]=]

----------------------------------------------------------------------------------------
-- [[ ROBLOX SERVICES ]] --
----------------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ContextBuilder = require(script.ContextBuilder)
local ServerAuthToolkitTypes = require(script.ServerAuthToolkitTypes)
local MovementStateAttributes = require(script.MovementStateAttributes)
local MovementStateBuilder = require(script.MovementStateBuilder)
local IsOnGround = require(script.IsOnGround)
local AnimationHelper = require(script.AnimationHelper)

----------------------------------------------------------------------------------------
-- [[ TYPES ]] --
----------------------------------------------------------------------------------------

export type MovementState = ServerAuthToolkitTypes.MovementState
export type AnimationSettings = ServerAuthToolkitTypes.AnimationSettings
export type MovementModuleDefinition = ServerAuthToolkitTypes.MovementModuleDefinition
export type PostCameraVisualEntry = ServerAuthToolkitTypes.PostCameraVisualEntry
export type PreCameraSimulationEntry = ServerAuthToolkitTypes.PreCameraSimulationEntry

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkit = {} :: ServerAuthToolkit

export type ServerAuthToolkit = typeof(ServerAuthToolkit) & {
	--Register
	RegisterDefinition: (self: ServerAuthToolkit, definition: ServerAuthToolkitTypes.MovementModuleDefinition) -> (),
	RegisterAnimations: (
		self: ServerAuthToolkit,
		animations: { [string]: ServerAuthToolkitTypes.AnimationSettings }
	) -> (),
	Start: (self: ServerAuthToolkit) -> (),

	--Camera
	RegisterPreCameraSimulation: (
		self: ServerAuthToolkit,
		callbackName: string,
		callback: ServerAuthToolkitTypes.PreCameraSimulationCallback
	) -> () -> (),
	RegisterPostCameraVisualEffect: (
		self: ServerAuthToolkit,
		callbackName: string,
		callback: ServerAuthToolkitTypes.PostCameraVisualCallback,
		renderPriorityOffset: number?
	) -> () -> (),
	GetStoredSimulationCameraBaseCFrame: (self: ServerAuthToolkit) -> CFrame?,

	--States
	ResetNeededStates: (self: ServerAuthToolkit, playerMovementState: ServerAuthToolkitTypes.MovementState) -> (),
	GetLocalMovementState: (self: ServerAuthToolkit) -> ServerAuthToolkitTypes.MovementState?,

	--Animations
	PlayAnimation: (self: ServerAuthToolkit, animationName: string, speedOverride: number?) -> (),
	StopAnimation: (self: ServerAuthToolkit, animationName: string) -> (),
	IsAnimationPlaying: (self: ServerAuthToolkit, animationName: string) -> boolean,
	IsAnimationFinished: (self: ServerAuthToolkit, animationName: string) -> boolean,

	--Utility
	WriteFlatLookDirection: (self: ServerAuthToolkit, rootPart: BasePart, flatLookDirection: Vector3) -> (),
	ReadFlatLookDirection: (self: ServerAuthToolkit, rootPart: BasePart) -> Vector3,
	QuantizeFlatDirection: (self: ServerAuthToolkit, flatDirection: Vector3) -> Vector3,
}

local self: ServerAuthToolkit = ServerAuthToolkit

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

const GET_ROBLOX_CONTEXT_TIMEOUT: number = 5
const MOVEMENT_CONTEXT_NAME: string = "MovementContext"
const MOVEMENT_CAMERA_LOOK_ACTION_NAME: string = "MovementCameraLook"
const MOVEMENT_CAMERA_RELATIVE_ROTATION_ACTION_NAME: string = "MovementCameraRelativeRotation"
const SIMULATION_CAMERA_LOOK_CAPTURE_PRIORITY_OFFSET: number = 1
const DEFAULT_POST_CAMERA_VISUAL_PRIORITY_OFFSET: number = 2

----------------------------------------------------------------------------------------
-- [[ FIELDS ]] --
----------------------------------------------------------------------------------------

local Definitions: { ServerAuthToolkitTypes.MovementModuleDefinition } = {}
local RegisteredDefinitionNames: { [string]: boolean } = {}
local MergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults = {}
local MovementStates: { [Player]: ServerAuthToolkitTypes.MovementState } = {}
local PlayerMovementContexts: { [Player]: ContextBuilder.ContextBuilder } = {}
local DisabledActionNames: { [string]: boolean } = {}
local PlayerConnectionGroups: { [Player]: ServerAuthToolkitTypes.ConnectionGroup } = {}
local CharacterConnectionGroups: { [Player]: ServerAuthToolkitTypes.ConnectionGroup } = {}

local Started: boolean = false
local ServerSimulationBound: boolean = false
local ClientSimulationBound: boolean = false
local ClientPreSimulationBound: boolean = false

local PostCameraVisualEffectsBound: { [number]: boolean } = {}
local SimulationCameraLookCaptureBound: boolean = false
local PreCameraSimulationCallbacks: { ServerAuthToolkitTypes.PreCameraSimulationEntry } = {}
local PreCameraSimulationCallbackNames: { [string]: boolean } = {}
local PostCameraVisualCallbacks: { ServerAuthToolkitTypes.PostCameraVisualEntry } = {}
local PostCameraVisualCallbackNames: { [string]: boolean } = {}
local StoredSimulationCameraLookVector: Vector3? = nil
local StoredSimulationCameraBaseCFrame: CFrame? = nil

local IsServer: boolean = RunService:IsServer()
local IsClient: boolean = RunService:IsClient()

----------------------------------------------------------------------------------------
-- [[ LOCAL METHODS ]] --
----------------------------------------------------------------------------------------

local function getOrCreateConnectionGroup(
	connectionGroups: { [Player]: ServerAuthToolkitTypes.ConnectionGroup },
	player: Player
): ServerAuthToolkitTypes.ConnectionGroup
	local existingConnectionGroup: ServerAuthToolkitTypes.ConnectionGroup? = connectionGroups[player]

	if existingConnectionGroup then
		return existingConnectionGroup
	end

	local connectionGroup: ServerAuthToolkitTypes.ConnectionGroup = {
		connections = {},
		cleanupTasks = {},
	}

	connectionGroups[player] = connectionGroup

	return connectionGroup
end

local function runConnectionGroupCleanup(connectionGroup: ServerAuthToolkitTypes.ConnectionGroup): ()
	for connectionIndex: number, connection: RBXScriptConnection in connectionGroup.connections do
		connection:Disconnect()
		connectionGroup.connections[connectionIndex] = nil :: any
	end

	for _: number, cleanupTask: () -> () in connectionGroup.cleanupTasks do
		cleanupTask()
	end

	table.clear(connectionGroup.cleanupTasks)
end

local function addPlayerConnection(player: Player, connection: RBXScriptConnection): ()
	table.insert(getOrCreateConnectionGroup(PlayerConnectionGroups, player).connections, connection)
end

local function addPlayerCleanupTask(player: Player, cleanupTask: () -> ()): ()
	table.insert(getOrCreateConnectionGroup(PlayerConnectionGroups, player).cleanupTasks, cleanupTask)
end

local function addCharacterCleanupTask(player: Player, cleanupTask: () -> ()): ()
	table.insert(getOrCreateConnectionGroup(CharacterConnectionGroups, player).cleanupTasks, cleanupTask)
end

local function cleanupCharacter(player: Player): ()
	local characterConnectionGroup: ServerAuthToolkitTypes.ConnectionGroup? = CharacterConnectionGroups[player]

	if characterConnectionGroup then
		runConnectionGroupCleanup(characterConnectionGroup)
		CharacterConnectionGroups[player] = nil
	end
end

local function cleanupPlayer(player: Player): ()
	cleanupCharacter(player)

	local playerConnectionGroup: ServerAuthToolkitTypes.ConnectionGroup? = PlayerConnectionGroups[player]

	if playerConnectionGroup then
		runConnectionGroupCleanup(playerConnectionGroup)
		PlayerConnectionGroups[player] = nil
	end

	MovementStates[player] = nil
	PlayerMovementContexts[player] = nil
end

local function disableRobloxAction(inputContexts: Folder, actionName: string): ()
	local characterContext: InputContext =
		inputContexts:WaitForChild("CharacterContext", GET_ROBLOX_CONTEXT_TIMEOUT) :: InputContext

	local moveAction: InputAction = characterContext:WaitForChild(actionName, GET_ROBLOX_CONTEXT_TIMEOUT) :: InputAction

	moveAction.Enabled = false
end

local function getDefinitionPriority(definition: ServerAuthToolkitTypes.MovementModuleDefinition): number
	return definition.Priority or 0
end

local function sortDefinitionsByPriority(): ()
	table.sort(
		Definitions,
		function(
			definitionA: ServerAuthToolkitTypes.MovementModuleDefinition,
			definitionB: ServerAuthToolkitTypes.MovementModuleDefinition
		): boolean
			local priorityA: number = getDefinitionPriority(definitionA)
			local priorityB: number = getDefinitionPriority(definitionB)

			if priorityA ~= priorityB then
				return priorityA < priorityB
			end

			return definitionA.Name < definitionB.Name
		end
	)
end

local function runProcess(
	definition: ServerAuthToolkitTypes.MovementModuleDefinition,
	state: ServerAuthToolkitTypes.MovementState,
	deltaTime: number
): ()
	definition.Process(state, deltaTime)
end

local function isValidCameraLookVector(cameraLookVector: Vector3): boolean
	return not (
		cameraLookVector.X ~= cameraLookVector.X
		or cameraLookVector.Y ~= cameraLookVector.Y
		or cameraLookVector.Z ~= cameraLookVector.Z
		or cameraLookVector.X == math.huge
		or cameraLookVector.Y == math.huge
		or cameraLookVector.Z == math.huge
	)
end

local function syncCameraLookFromInput(
	movementContextInstance: Instance,
	playerMovementState: ServerAuthToolkitTypes.MovementState
): ()
	local movementCameraLookAction: Instance? = movementContextInstance:FindFirstChild(MOVEMENT_CAMERA_LOOK_ACTION_NAME)

	if not movementCameraLookAction or not movementCameraLookAction:IsA("InputAction") then
		return
	end

	local cameraLookVector: Vector3 = movementCameraLookAction:GetState()

	if isValidCameraLookVector(cameraLookVector) then
		playerMovementState.CameraLookVector = cameraLookVector
	end

	local movementCameraRelativeRotationAction: Instance? =
		movementContextInstance:FindFirstChild(MOVEMENT_CAMERA_RELATIVE_ROTATION_ACTION_NAME)

	if movementCameraRelativeRotationAction and movementCameraRelativeRotationAction:IsA("InputAction") then
		playerMovementState.IsCameraRelativeRotation = movementCameraRelativeRotationAction:GetState()
	end
end

local function captureSimulationCameraLookVector(): ()
	if not IsClient then
		return
	end

	local currentCamera: Camera? = workspace.CurrentCamera

	if not currentCamera then
		return
	end

	local cameraLookVector: Vector3 = currentCamera.CFrame.LookVector

	if isValidCameraLookVector(cameraLookVector) then
		StoredSimulationCameraLookVector = cameraLookVector
		StoredSimulationCameraBaseCFrame = currentCamera.CFrame
	end
end

local function getSimulationCameraLookVector(currentCamera: Camera): Vector3?
	if StoredSimulationCameraLookVector and isValidCameraLookVector(StoredSimulationCameraLookVector) then
		return StoredSimulationCameraLookVector
	end

	local cameraLookVector: Vector3 = currentCamera.CFrame.LookVector

	if isValidCameraLookVector(cameraLookVector) then
		return cameraLookVector
	end

	return nil
end

local function bindSimulationCameraLookCapture(): ()
	if SimulationCameraLookCaptureBound then
		return
	end

	SimulationCameraLookCaptureBound = true

	RunService:BindToRenderStep(
		"ServerAuthToolkit_SimulationCameraLook",
		Enum.RenderPriority.Camera.Value + SIMULATION_CAMERA_LOOK_CAPTURE_PRIORITY_OFFSET,
		captureSimulationCameraLookVector
	)
end

local function getPostCameraVisualPriorityOffsets(): { number }
	local priorityOffsets: { number } = {}

	for _: number, entry: ServerAuthToolkitTypes.PostCameraVisualEntry in PostCameraVisualCallbacks do
		if not table.find(priorityOffsets, entry.priority) then
			table.insert(priorityOffsets, entry.priority)
		end
	end

	table.sort(priorityOffsets)

	return priorityOffsets
end

local function runPostCameraVisualCallbacks(deltaTime: number, renderPriorityOffset: number): ()
	for _: number, entry: ServerAuthToolkitTypes.PostCameraVisualEntry in PostCameraVisualCallbacks do
		if entry.priority == renderPriorityOffset then
			entry.callback(deltaTime)
		end
	end
end

local function bindPostCameraVisualPriority(renderPriorityOffset: number): ()
	if PostCameraVisualEffectsBound[renderPriorityOffset] then
		return
	end

	PostCameraVisualEffectsBound[renderPriorityOffset] = true

	RunService:BindToRenderStep(
		`ServerAuthToolkit_PostCameraVisual_{renderPriorityOffset}`,
		Enum.RenderPriority.Camera.Value + renderPriorityOffset,
		function(deltaTime: number)
			runPostCameraVisualCallbacks(deltaTime, renderPriorityOffset)
		end
	)
end

local function bindPostCameraVisualEffects(): ()
	for _: number, renderPriorityOffset: number in getPostCameraVisualPriorityOffsets() do
		bindPostCameraVisualPriority(renderPriorityOffset)
	end

	bindSimulationCameraLookCapture()
end

local function fireCameraInputForLocalPlayer(): ()
	if not IsClient then
		return
	end

	local player: Player = Players.LocalPlayer
	local playerMovementState: ServerAuthToolkitTypes.MovementState? = MovementStates[player]

	if not playerMovementState then
		return
	end

	local inputContexts: Folder? = player:FindFirstChild("InputContexts") :: Folder?

	if not inputContexts then
		return
	end

	local movementContextInstance: Instance? = inputContexts:FindFirstChild(MOVEMENT_CONTEXT_NAME)

	if not movementContextInstance then
		return
	end

	local currentCamera: Camera? = workspace.CurrentCamera

	if not currentCamera then
		return
	end

	local cameraLookVector: Vector3? = getSimulationCameraLookVector(currentCamera)

	if not cameraLookVector then
		return
	end

	if not isValidCameraLookVector(cameraLookVector) then
		return
	end

	local isCameraRelativeRotation: boolean = player.CameraMode == Enum.CameraMode.LockFirstPerson

	local movementCameraLookAction: Instance? = movementContextInstance:FindFirstChild(MOVEMENT_CAMERA_LOOK_ACTION_NAME)

	if movementCameraLookAction and movementCameraLookAction:IsA("InputAction") then
		movementCameraLookAction:Fire(cameraLookVector)
	end

	local movementCameraRelativeRotationAction: Instance? =
		movementContextInstance:FindFirstChild(MOVEMENT_CAMERA_RELATIVE_ROTATION_ACTION_NAME)

	if movementCameraRelativeRotationAction and movementCameraRelativeRotationAction:IsA("InputAction") then
		movementCameraRelativeRotationAction:Fire(isCameraRelativeRotation)
	end
end

local function runPreCameraSimulationCallbacks(deltaTime: number): ()
	for _: number, entry: ServerAuthToolkitTypes.PreCameraSimulationEntry in PreCameraSimulationCallbacks do
		entry.callback(deltaTime)
	end
end

local function unregisterPreCameraSimulation(callbackName: string): ()
	if not PreCameraSimulationCallbackNames[callbackName] then
		return
	end

	PreCameraSimulationCallbackNames[callbackName] = nil

	for index: number = #PreCameraSimulationCallbacks, 1, -1 do
		if PreCameraSimulationCallbacks[index].name == callbackName then
			table.remove(PreCameraSimulationCallbacks, index)
			break
		end
	end
end

local function unregisterPostCameraVisualEffect(callbackName: string): ()
	if not PostCameraVisualCallbackNames[callbackName] then
		return
	end

	PostCameraVisualCallbackNames[callbackName] = nil

	for index: number = #PostCameraVisualCallbacks, 1, -1 do
		if PostCameraVisualCallbacks[index].name == callbackName then
			table.remove(PostCameraVisualCallbacks, index)
			break
		end
	end
end

local function bindClientPreSimulation(): ()
	if ClientPreSimulationBound then
		return
	end

	ClientPreSimulationBound = true

	RunService.PreSimulation:Connect(function(deltaTime: number)
		runPreCameraSimulationCallbacks(deltaTime)
	end)
end

local function syncDefinitionInputsFromInput(
	player: Player,
	playerMovementState: ServerAuthToolkitTypes.MovementState
): ()
	local inputContexts: Folder? = player:FindFirstChild("InputContexts") :: Folder?

	if not inputContexts then
		return
	end

	local movementContextInstance: Instance? = inputContexts:FindFirstChild(MOVEMENT_CONTEXT_NAME)

	if not movementContextInstance then
		return
	end

	for _: number, definition: ServerAuthToolkitTypes.MovementModuleDefinition in Definitions do
		for _: number, action: ServerAuthToolkitTypes.ActionDefinition in definition.Actions do
			local actionInstance: Instance? = movementContextInstance:FindFirstChild(action.Name)

			if actionInstance and actionInstance:IsA("InputAction") then
				action.ApplyInput(playerMovementState, actionInstance:GetState())
			end
		end
	end

	syncCameraLookFromInput(movementContextInstance, playerMovementState)
end

local function isMovementInputReady(player: Player, state: ServerAuthToolkitTypes.MovementState): boolean
	if not state.RootPart or not state.Character then
		return false
	end

	local inputContexts: Folder? = player:FindFirstChild("InputContexts") :: Folder?

	if not inputContexts then
		return false
	end

	return inputContexts:FindFirstChild(MOVEMENT_CONTEXT_NAME) ~= nil
end

local function syncMovementStateFromAttributes(state: ServerAuthToolkitTypes.MovementState): ()
	local rootPart: BasePart? = state.RootPart

	if not rootPart then
		return
	end

	MovementStateAttributes:ApplyToMovementState(rootPart, state)
end

local function finishSimulationStep(state: ServerAuthToolkitTypes.MovementState): ()
	local rootPart: BasePart? = state.RootPart

	if not rootPart or not rootPart.Parent then
		return
	end

	MovementStateAttributes:CaptureFromMovementState(rootPart, state)

	local velocity: Vector3 = state.Velocity or Vector3.zero
	rootPart.AssemblyLinearVelocity = velocity

	local flatLookDirection: Vector3 = MovementStateAttributes:ReadFlatLookDirection(rootPart)

	if flatLookDirection.Magnitude > 0.001 then
		local characterPosition: Vector3 = rootPart.Position
		rootPart.CFrame = CFrame.lookAt(characterPosition, characterPosition + flatLookDirection)
	end

	local currentAngularVelocity: Vector3 = rootPart.AssemblyAngularVelocity
	rootPart.AssemblyAngularVelocity = Vector3.new(currentAngularVelocity.X, 0, currentAngularVelocity.Z)
end

local function runDefinitionsForState(
	player: Player,
	state: ServerAuthToolkitTypes.MovementState,
	deltaTime: number
): ()
	if not isMovementInputReady(player, state) then
		return
	end

	syncDefinitionInputsFromInput(player, state)

	local onGround: boolean, groundNormal: Vector3 = IsOnGround:Get(state)
	state.OnGround = onGround
	state.GroundNormal = groundNormal

	AnimationHelper:SetProcessingRootPart(state.RootPart)

	for _: number, definition: ServerAuthToolkitTypes.MovementModuleDefinition in Definitions do
		runProcess(definition, state, deltaTime)
	end

	finishSimulationStep(state)
	AnimationHelper:SetProcessingRootPart(nil)
end

local function registerMovementCameraLookAction(movementContext: ContextBuilder.ContextBuilder): ()
	if movementContext:HasAction(MOVEMENT_CAMERA_LOOK_ACTION_NAME) then
		return
	end

	movementContext:AddAction(MOVEMENT_CAMERA_LOOK_ACTION_NAME, Enum.InputActionType.Direction3D)
end

local function registerMovementCameraRelativeRotationAction(movementContext: ContextBuilder.ContextBuilder): ()
	if movementContext:HasAction(MOVEMENT_CAMERA_RELATIVE_ROTATION_ACTION_NAME) then
		return
	end

	movementContext:AddAction(MOVEMENT_CAMERA_RELATIVE_ROTATION_ACTION_NAME, Enum.InputActionType.Bool)
end

local function registerActions(
	definition: ServerAuthToolkitTypes.MovementModuleDefinition,
	movementContext: ContextBuilder.ContextBuilder
): ()
	registerMovementCameraLookAction(movementContext)
	registerMovementCameraRelativeRotationAction(movementContext)

	for _: number, action: ServerAuthToolkitTypes.ActionDefinition in definition.Actions do
		if not movementContext:HasAction(action.Name) then
			movementContext:AddAction(action.Name, action.Type)

			for bindingName: string, bindingProps: ServerAuthToolkitTypes.BindingProps in action.Bindings do
				movementContext:AddBinding(action.Name, bindingName, bindingProps)
			end
		end
	end
end

local function disableActionsForPlayer(player: Player, definition: ServerAuthToolkitTypes.MovementModuleDefinition): ()
	local disableActions: { string }? = definition.Disable

	if not disableActions then
		return
	end

	local inputContexts: Folder? = player:FindFirstChild("InputContexts") :: Folder?

	if not inputContexts then
		return
	end

	for _: number, actionName: string in disableActions do
		disableRobloxAction(inputContexts, actionName)
	end
end

local function registerDisableActionsFromDefinition(definition: ServerAuthToolkitTypes.MovementModuleDefinition): ()
	local disableActions: { string }? = definition.Disable

	if not disableActions then
		return
	end

	for _: number, actionName: string in disableActions do
		if DisabledActionNames[actionName] then
			continue
		end

		DisabledActionNames[actionName] = true

		if not Started then
			continue
		end

		for _: number, player: Player in Players:GetPlayers() do
			disableActionsForPlayer(player, definition)
		end
	end
end

local function applyDefinitionToActivePlayers(definition: ServerAuthToolkitTypes.MovementModuleDefinition): ()
	for player: Player, playerMovementState: ServerAuthToolkitTypes.MovementState in MovementStates do
		MovementStateBuilder:ApplyNeededStatesFromDefinition(playerMovementState, definition)

		if IsServer then
			local movementContext: ContextBuilder.ContextBuilder? = PlayerMovementContexts[player]

			if movementContext then
				registerActions(definition, movementContext)
			end
		end
	end
end

local function bindServerSimulation(): ()
	if ServerSimulationBound then
		return
	end

	ServerSimulationBound = true

	RunService:BindToSimulation(function(deltaTime: number)
		for player: Player, state: ServerAuthToolkitTypes.MovementState in MovementStates do
			runDefinitionsForState(player, state, deltaTime)
		end
	end, Enum.StepFrequency.Hz60)
end

local function bindClientSimulation(): ()
	if ClientSimulationBound then
		return
	end

	ClientSimulationBound = true

	-- Custom inputs must be fired from the render loop (matching Roblox's
	-- ControlModule), never from inside BindToSimulation: simulation callbacks
	-- re-run during resimulation, and firing there desyncs the input timeline
	-- between client and server.
	RunService:BindToRenderStep("ServerAuthToolkit_CameraInput", Enum.RenderPriority.Last.Value, function()
		fireCameraInputForLocalPlayer()
	end)

	RunService:BindToSimulation(function(deltaTime: number)
		local localPlayer: Player = Players.LocalPlayer
		local localMovementState: ServerAuthToolkitTypes.MovementState? = MovementStates[localPlayer]

		if not localMovementState then
			return
		end

		runDefinitionsForState(localPlayer, localMovementState, deltaTime)
	end, Enum.StepFrequency.Hz60)
end

local function bindRollbackStateSync(): ()
	if not IsClient then
		return
	end

	RunService.Rollback:Connect(function(_rollbackTime: number)
		for _: Player, state: ServerAuthToolkitTypes.MovementState in MovementStates do
			if state.RootPart and state.RootPart.Parent then
				syncMovementStateFromAttributes(state)
			end
		end
	end)
end

local function clearCharacterRefs(playerMovementState: ServerAuthToolkitTypes.MovementState): ()
	playerMovementState.Character = nil
	playerMovementState.Humanoid = nil
	playerMovementState.RootPart = nil
	playerMovementState.CameraLookVector = nil
	ServerAuthToolkit.ResetNeededStates(ServerAuthToolkit, playerMovementState)
end

local function onCharacterAdded(player: Player, character: Model): ()
	cleanupCharacter(player)

	local playerMovementState: ServerAuthToolkitTypes.MovementState? = MovementStates[player]

	if not playerMovementState then
		return
	end

	local humanoid: Humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart: BasePart = character:WaitForChild("HumanoidRootPart") :: BasePart

	playerMovementState.Character = character
	playerMovementState.Humanoid = humanoid
	playerMovementState.RootPart = rootPart
	playerMovementState.CameraLookVector = Vector3.zero
	ServerAuthToolkit.ResetNeededStates(ServerAuthToolkit, playerMovementState)
	playerMovementState.Velocity = Vector3.zero
	MovementStateAttributes:Clear(rootPart)

	local spawnFlatLook: Vector3 = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)

	if spawnFlatLook.Magnitude > 0.001 then
		MovementStateAttributes:WriteFlatLookDirection(rootPart, spawnFlatLook.Unit)
	end

	MovementStateAttributes:CaptureFromMovementState(rootPart, playerMovementState)

	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = true

	if IsClient and player == Players.LocalPlayer then
		RunService:SetPredictionMode(rootPart, Enum.PredictionMode.On)
	end

	getOrCreateConnectionGroup(CharacterConnectionGroups, player)

	addCharacterCleanupTask(player, function()
		clearCharacterRefs(playerMovementState)
	end)

	AnimationHelper:HumanoidAdded(humanoid)
end

local function onPlayerAdded(player: Player): ()
	if MovementStates[player] then
		return
	end

	local inputContexts: Folder = player:WaitForChild("InputContexts", GET_ROBLOX_CONTEXT_TIMEOUT) :: Folder

	if IsServer then
		local movementContext: ContextBuilder.ContextBuilder = ContextBuilder.new(MOVEMENT_CONTEXT_NAME, inputContexts)

		PlayerMovementContexts[player] = movementContext

		for _: number, definition: ServerAuthToolkitTypes.MovementModuleDefinition in Definitions do
			registerActions(definition, movementContext)
		end

		addPlayerCleanupTask(player, function()
			movementContext:Destroy()
			PlayerMovementContexts[player] = nil
		end)
	end

	for actionName: string, _: boolean in DisabledActionNames do
		disableRobloxAction(inputContexts, actionName)
	end

	if IsClient and player == Players.LocalPlayer then
		inputContexts:WaitForChild(MOVEMENT_CONTEXT_NAME, GET_ROBLOX_CONTEXT_TIMEOUT)
	end

	local playerMovementState: ServerAuthToolkitTypes.MovementState =
		MovementStateBuilder:CreateMovementState(MergedNeededStates)
	MovementStates[player] = playerMovementState

	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	addPlayerConnection(
		player,
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
	)
end

local function connectServerLifecycle(): ()
	Players.PlayerRemoving:Connect(cleanupPlayer)

	for _: number, player: Player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
end

local function connectClientLifecycle(): ()
	onPlayerAdded(Players.LocalPlayer)
end

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

--[=[
	Registers a movement module with input actions, default state fields, and a
	`Process` function.

	Modules run in priority order (lower runs first). Register before `Start`
	when possible; if already started, active players are updated immediately.
	Duplicate names are ignored.

	@tag Register
	@param definition ServerAuthToolkitTypes.MovementModuleDefinition -- Module definition to register
]=]
function ServerAuthToolkit.RegisterDefinition(
	self: ServerAuthToolkit,
	definition: ServerAuthToolkitTypes.MovementModuleDefinition
): ()
	if RegisteredDefinitionNames[definition.Name] then
		warn(`[ServerAuthToolkit] Movement module "{definition.Name}" is already registered`)
		return
	end

	RegisteredDefinitionNames[definition.Name] = true
	table.insert(Definitions, definition)
	sortDefinitionsByPriority()
	MergedNeededStates = MovementStateBuilder:GetMergedNeededStates(Definitions)
	MovementStateAttributes:Configure(MergedNeededStates)

	registerDisableActionsFromDefinition(definition)

	if Started then
		applyDefinitionToActivePlayers(definition)

		if IsClient then
			bindClientPreSimulation()
			bindSimulationCameraLookCapture()
		end
	end
end

--[=[
	Registers a callback that runs on the client before movement simulation each
	frame.

	Use for client-only setup that must happen before input is applied. Callbacks
	run in registration order. Server calls log a warning and return a no-op
	unregister function.

	@client
	@tag Camera
	@param callbackName string -- Unique name for this callback
	@param callback ServerAuthToolkitTypes.PreCameraSimulationCallback -- Called each pre-simulation step with deltaTime
	@return () -> () -- Unregisters the callback
]=]
function ServerAuthToolkit.RegisterPreCameraSimulation(
	self: ServerAuthToolkit,
	callbackName: string,
	callback: ServerAuthToolkitTypes.PreCameraSimulationCallback
): () -> ()
	if not IsClient then
		warn(`[ServerAuthToolkit] RegisterPreCameraSimulation is client-only ({callbackName})`)
		return function() end
	end

	if PreCameraSimulationCallbackNames[callbackName] then
		warn(`[ServerAuthToolkit] Pre-camera simulation callback "{callbackName}" is already registered`)
		return function() end
	end

	PreCameraSimulationCallbackNames[callbackName] = true
	table.insert(PreCameraSimulationCallbacks, {
		name = callbackName,
		callback = callback,
	})

	bindClientPreSimulation()

	return function()
		unregisterPreCameraSimulation(callbackName)
	end
end

--[=[
	Registers a visual callback that runs on the client after the camera updates.

	Use for camera shake, FOV changes, or other effects that should not affect
	movement simulation. Server calls log a warning and return a no-op unregister
	function.

	@client
	@tag Camera
	@param callbackName string -- Unique name for this callback
	@param callback ServerAuthToolkitTypes.PostCameraVisualCallback -- Called each render step with deltaTime
	@param renderPriorityOffset number? -- Offset from camera render priority. Defaults to 2
	@return () -> () -- Unregisters the callback
]=]
function ServerAuthToolkit.RegisterPostCameraVisualEffect(
	self: ServerAuthToolkit,
	callbackName: string,
	callback: ServerAuthToolkitTypes.PostCameraVisualCallback,
	renderPriorityOffset: number?
): () -> ()
	if not IsClient then
		warn(`[ServerAuthToolkit] RegisterPostCameraVisualEffect is client-only ({callbackName})`)
		return function() end
	end

	if PostCameraVisualCallbackNames[callbackName] then
		warn(`[ServerAuthToolkit] Post-camera visual callback "{callbackName}" is already registered`)
		return function() end
	end

	local resolvedPriorityOffset: number = renderPriorityOffset or DEFAULT_POST_CAMERA_VISUAL_PRIORITY_OFFSET

	PostCameraVisualCallbackNames[callbackName] = true
	table.insert(PostCameraVisualCallbacks, {
		name = callbackName,
		callback = callback,
		priority = resolvedPriorityOffset,
	})

	bindPostCameraVisualEffects()

	return function()
		unregisterPostCameraVisualEffect(callbackName)
	end
end

--[=[
	Returns the camera CFrame captured for client movement simulation.

	The toolkit stores this after the camera updates so simulation uses a stable
	camera state. Returns nil on the server or before a capture exists.

	@client
	@tag Camera
	@return CFrame? -- The stored simulation camera CFrame
]=]
function ServerAuthToolkit.GetStoredSimulationCameraBaseCFrame(self: ServerAuthToolkit): CFrame?
	if not IsClient then
		return nil
	end

	return StoredSimulationCameraBaseCFrame
end

--[=[
	Resets a player's custom movement state fields to the merged defaults from
	all registered modules.

	Only fields from module `NeededStates` are reset. Built-in fields like
	`Character` and `RootPart` are not changed.

	@tag States
	@param playerMovementState ServerAuthToolkitTypes.MovementState -- The movement state to reset
]=]
function ServerAuthToolkit.ResetNeededStates(
	self: ServerAuthToolkit,
	playerMovementState: ServerAuthToolkitTypes.MovementState
): ()
	MovementStateBuilder:ResetNeededStates(playerMovementState, MergedNeededStates)
end

--[=[
	Returns the local player's movement state table.

	This is the same table updated each simulation step by registered modules.
	Returns nil on the server.

	@client
	@tag States
	@return ServerAuthToolkitTypes.MovementState? -- The local player's movement state
]=]
function ServerAuthToolkit.GetLocalMovementState(self: ServerAuthToolkit): ServerAuthToolkitTypes.MovementState?
	if not IsClient then
		return nil
	end

	return MovementStates[Players.LocalPlayer]
end

--[=[
	Registers animations for use with the animation API.

	Each name maps to playback settings used by `PlayAnimation`, `StopAnimation`,
	and the animation query methods.

	@tag Register
	@param animations { [string]: ServerAuthToolkitTypes.AnimationSettings } -- Animation names to settings
]=]
function ServerAuthToolkit.RegisterAnimations(
	self: ServerAuthToolkit,
	animations: { [string]: ServerAuthToolkitTypes.AnimationSettings }
): ()
	for animationName: string, animationSettings: ServerAuthToolkitTypes.AnimationSettings in animations do
		AnimationHelper:RegisterAnimation(animationName, animationSettings)
	end
end

--[=[
	Plays a registered animation.

	The animation must be registered first with `RegisterAnimations`.

	@tag Animations
	@param animationName string -- The animation to play
	@param speedOverride number? -- Optional playback speed. Uses registered speed if omitted
]=]
function ServerAuthToolkit.PlayAnimation(self: ServerAuthToolkit, animationName: string, speedOverride: number?): ()
	AnimationHelper:PlayAnimation(animationName, speedOverride)
end

--[=[
	Stops a registered animation.

	Uses the registered stop fade time when blending out.

	@tag Animations
	@param animationName string -- The animation to stop
]=]
function ServerAuthToolkit.StopAnimation(self: ServerAuthToolkit, animationName: string): ()
	AnimationHelper:StopAnimation(animationName)
end

--[=[
	Returns whether a registered animation is currently playing.

	@tag Animations
	@param animationName string -- The animation to check
	@return boolean -- True if the animation is playing
]=]
function ServerAuthToolkit.IsAnimationPlaying(self: ServerAuthToolkit, animationName: string): boolean
	return AnimationHelper:IsAnimationPlaying(animationName)
end

--[=[
	Returns whether a non-looped animation has finished playing.

	Looped animations always return false.

	@tag Animations
	@param animationName string -- The animation to check
	@return boolean -- True if the animation has finished
]=]
function ServerAuthToolkit.IsAnimationFinished(self: ServerAuthToolkit, animationName: string): boolean
	return AnimationHelper:IsAnimationFinished(animationName)
end

--[=[
	Stores a flat look direction on a root part for replication.

	The toolkit reads this at the end of each simulation step to orient the
	character. The Y component should usually be zero.

	@tag Utility
	@param rootPart BasePart -- The character root part
	@param flatLookDirection Vector3 -- The horizontal look direction in world space
]=]
function ServerAuthToolkit.WriteFlatLookDirection(
	self: ServerAuthToolkit,
	rootPart: BasePart,
	flatLookDirection: Vector3
): ()
	MovementStateAttributes:WriteFlatLookDirection(rootPart, flatLookDirection)
end

--[=[
	Reads the flat look direction stored on a root part.

	Returns `Vector3.new(0, 0, -1)` if no direction has been stored.

	@tag Utility
	@param rootPart BasePart -- The character root part
	@return Vector3 -- The stored flat look direction
]=]
function ServerAuthToolkit.ReadFlatLookDirection(self: ServerAuthToolkit, rootPart: BasePart): Vector3
	return MovementStateAttributes:ReadFlatLookDirection(rootPart)
end

--[=[
	Rounds a flat direction to a fixed yaw step for stable network replication.

	Yaw is quantized to 0.25 degree steps. Useful before calling
	`WriteFlatLookDirection`.

	@tag Utility
	@param flatDirection Vector3 -- The direction to quantize
	@return Vector3 -- The quantized direction on the horizontal plane
]=]
function ServerAuthToolkit.QuantizeFlatDirection(self: ServerAuthToolkit, flatDirection: Vector3): Vector3
	return MovementStateAttributes:QuantizeFlatDirection(flatDirection)
end

--[=[
	Starts movement simulation, player lifecycle handling, and the animation helper.

	Call once on the server and once on the client after registering modules.
	Safe to call multiple times; later calls do nothing.

	@tag Register
]=]
function ServerAuthToolkit.Start(self: ServerAuthToolkit): ()
	if Started then
		return
	end

	Started = true

	if IsServer then
		bindServerSimulation()
		connectServerLifecycle()
	end

	if IsClient then
		bindClientPreSimulation()
		bindSimulationCameraLookCapture()
		bindPostCameraVisualEffects()
		bindRollbackStateSync()
		bindClientSimulation()
		connectClientLifecycle()
	end

	AnimationHelper:Start()
end

return self
