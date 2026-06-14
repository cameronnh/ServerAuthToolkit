----------------------------------------------------------------------------------------
-- [[ TYPES ]] --
----------------------------------------------------------------------------------------

export type NeededStatesDefaults = { [string]: any }

export type MovementState = {
	Character: Model?,
	Humanoid: Humanoid?,
	RootPart: BasePart?,
	CameraLookVector: Vector3?,
	OnGround: boolean?,
	GroundNormal: Vector3?,
	[string]: any,
}

export type Action = {
	Type: Enum.InputActionType,
	Instance: InputAction,
	Enabled: boolean,
	Bindings: { [string]: InputBinding },
	Callbacks: { [string]: (state: any) -> () },
}

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

export type ActionDefinition = {
	Name: string,
	Type: Enum.InputActionType,
	Bindings: { [string]: BindingProps },
	ApplyInput: (state: MovementState, inputState: any) -> (),
}

export type MovementModuleDefinition = {
	Name: string,
	Priority: number?,
	Actions: { ActionDefinition },
	NeededStates: NeededStatesDefaults,
	Process: (state: MovementState, deltaTime: number) -> (),
	Disable: { string }?,
}

export type ConnectionGroup = {
	connections: { RBXScriptConnection },
	cleanupTasks: { () -> () },
}

export type PreCameraSimulationCallback = (deltaTime: number) -> ()

export type PostCameraVisualCallback = (deltaTime: number) -> ()

export type PreCameraSimulationEntry = {
	name: string,
	callback: PreCameraSimulationCallback,
}

export type PostCameraVisualEntry = {
	name: string,
	callback: PostCameraVisualCallback,
	priority: number,
}

export type AnimationSettings = {
	Speed: number,
	Weight: number,
	FadeTime: number,
	StopFadeTime: number,
	Looped: boolean,
	Priority: Enum.AnimationPriority,
	Animation: Animation,
}

export type CharacterAnimationState = {
	rootPart: BasePart,
	animator: Animator,
	tracks: { [string]: AnimationTrack },
	oneShotFinished: { [string]: boolean },
}

export type SerializableValueType = "boolean" | "number" | "Vector3" | "string"

export type StateAttributeBinding = {
	stateName: string,
	attributeName: string,
	valueType: SerializableValueType,
	defaultValue: any,
}

return nil
