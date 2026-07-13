----------------------------------------------------------------------------------------
-- [[ TYPES ]] --
----------------------------------------------------------------------------------------

export type NeededStatesDefaults = { [string]: any }

--[=[
	@type MovementState { Character: Model?, Humanoid: Humanoid?, RootPart: BasePart?, CameraLookVector: Vector3?, OnGround: boolean?, GroundNormal: Vector3?, GroundHeight: number?, [string]: any }
	@within ServerAuthToolkit
	@tag General

	Per-player movement state updated each simulation step. Built-in fields track
	the character and ground info; modules add custom fields through `NeededStates`.
]=]
export type MovementState = {
	Character: Model?,
	Humanoid: Humanoid?,
	RootPart: BasePart?,
	CameraLookVector: Vector3?,
	OnGround: boolean?,
	GroundNormal: Vector3?,
	GroundHeight: number?,
	[string]: any,
}

export type Action = {
	Type: Enum.InputActionType,
	Instance: InputAction,
	Enabled: boolean,
	Bindings: { [string]: InputBinding },
	Callbacks: { [string]: (state: any) -> () },
}

--[=[
	@type BindingProps { Backward: Enum.KeyCode?, ClampMagnitudeToOne: boolean?, Down: Enum.KeyCode?, Forward: Enum.KeyCode?, KeyCode: Enum.KeyCode?, Left: Enum.KeyCode?, PointerIndex: number?, PressedThreshold: number?, PrimaryModifier: Enum.KeyCode?, ReleasedThreshold: number?, ResponseCurve: number?, Right: Enum.KeyCode?, Scale: number?, SecondaryModifier: Enum.KeyCode?, UIButton: Enum.UserInputType?, Up: Enum.KeyCode?, Vector2Scale: Vector2?, Vector3Scale: Vector3? }
	@within ServerAuthToolkit
	@tag Input Action System

	Optional input binding settings for an action. Keys map to Roblox
	InputBinding properties such as key codes, modifiers, and scale values.
]=]
export type BindingProps = {
	Backward: Enum.KeyCode?,
	ClampMagnitudeToOne: boolean?,
	Down: Enum.KeyCode?,
	Forward: Enum.KeyCode?,
	KeyCode: Enum.KeyCode?,
	Left: Enum.KeyCode?,
	PointerIndex: number?,
	PressedThreshold: number?,
	PrimaryModifier: Enum.KeyCode?,
	ReleasedThreshold: number?,
	ResponseCurve: number?,
	Right: Enum.KeyCode?,
	Scale: number?,
	SecondaryModifier: Enum.KeyCode?,
	UIButton: Enum.UserInputType?,
	Up: Enum.KeyCode?,
	Vector2Scale: Vector2?,
	Vector3Scale: Vector3?,
}

--[=[
	@type ActionDefinition { Name: string, Type: Enum.InputActionType, Bindings: { [string]: BindingProps }, ApplyInput: (state: MovementState, inputState: any) -> () }
	@within ServerAuthToolkit
	@tag Input Action System

	Describes one input action in a movement module. `ApplyInput` writes the
	action state into the player's movement state each simulation step.
]=]
export type ActionDefinition = {
	Name: string,
	Type: Enum.InputActionType,
	Bindings: { [string]: BindingProps },
	ApplyInput: (state: MovementState, inputState: any) -> (),
}

--[=[
	@type MovementModuleDefinition { Name: string, Priority: number?, Actions: { ActionDefinition }, NeededStates: NeededStatesDefaults, NonReplicatedStates: { string }?, Process: (state: MovementState, deltaTime: number) -> (), Disable: { string }? }
	@within ServerAuthToolkit
	@tag General

	Describes a movement module: input actions, default state, per-frame logic, and
	optional Roblox actions to disable. Lower `Priority` runs first.

	`NonReplicatedStates` lists NeededStates fields that must NOT replicate as
	attributes: fields re-derived every step (for example written by `ApplyInput`
	from the input actions) waste the per-instance attribute payload budget and
	need no rollback restore. Like NeededStates, the list must be identical on
	the server and the client.
]=]
export type MovementModuleDefinition = {
	Name: string,
	Priority: number?,
	Actions: { ActionDefinition },
	NeededStates: NeededStatesDefaults,
	NonReplicatedStates: { string }?,
	Process: (state: MovementState, deltaTime: number) -> (),
	Disable: { string }?,
}

--[=[
	@type GroundDetectionConfig { MaxStepHeight: number?, LandingGap: number?, GroundLeaveVerticalSpeed: number?, MinWalkableNormalY: number? }
	@within ServerAuthToolkit
	@tag General

	Optional tuning for ground detection. Omitted fields keep their defaults.
	Apply the same configuration on the server and the client, before or right
	after `Start`, or grounded state diverges between prediction and authority.
]=]
export type GroundDetectionConfig = {
	MaxStepHeight: number?,
	LandingGap: number?,
	GroundLeaveVerticalSpeed: number?,
	MinWalkableNormalY: number?,
}

export type ConnectionGroup = {
	connections: { RBXScriptConnection },
	cleanupTasks: { () -> () },
}

export type PreCameraSimulationCallback = (deltaTime: number) -> ()

export type PostCameraVisualCallback = (deltaTime: number) -> ()

--[=[
	@type PreCameraSimulationEntry { name: string, callback: PreCameraSimulationCallback }
	@within ServerAuthToolkit
	@tag Callbacks

	Internal entry for a registered pre-camera simulation callback.
]=]
export type PreCameraSimulationEntry = {
	name: string,
	callback: PreCameraSimulationCallback,
}

--[=[
	@type PostCameraVisualEntry { name: string, callback: PostCameraVisualCallback, priority: number }
	@within ServerAuthToolkit
	@tag Callbacks

	Internal entry for a registered post-camera visual callback.
]=]
export type PostCameraVisualEntry = {
	name: string,
	callback: PostCameraVisualCallback,
	priority: number,
}

--[=[
	@type AnimationSettings { Animation: Animation, Speed: number?, Weight: number?, FadeTime: number?, StopFadeTime: number?, InterruptStopFadeTime: number?, Looped: boolean?, Priority: Enum.AnimationPriority? }
	@within ServerAuthToolkit
	@tag General

	Playback settings for a registered animation. Only `Animation` is required;
	omitted fields default to Speed 1, Weight 1, FadeTime 0.1, StopFadeTime 0.1,
	Looped false, and Priority Action.
]=]
export type AnimationSettings = {
	Animation: Animation,
	Speed: number?,
	Weight: number?,
	FadeTime: number?,
	StopFadeTime: number?,
	InterruptStopFadeTime: number?,
	Looped: boolean?,
	Priority: Enum.AnimationPriority?,
}

export type ResolvedAnimationSettings = {
	Animation: Animation,
	Speed: number,
	Weight: number,
	FadeTime: number,
	StopFadeTime: number,
	InterruptStopFadeTime: number?,
	Looped: boolean,
	Priority: Enum.AnimationPriority,
}

export type CharacterAnimationState = {
	rootPart: BasePart,
	animator: Animator,
	tracks: { [string]: AnimationTrack },
	oneShotFinished: { [string]: boolean },
}

export type SerializableValueType = "boolean" | "number" | "Vector2" | "Vector3" | "string"

export type StateAttributeBinding = {
	stateName: string,
	attributeName: string,
	valueType: SerializableValueType,
	defaultValue: any,
}

return nil
