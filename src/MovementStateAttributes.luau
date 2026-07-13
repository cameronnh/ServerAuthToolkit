----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkitTypes = require(script.Parent.ServerAuthToolkitTypes)

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

const ATTRIBUTE_PREFIX: string = "SAT_"

const FLAT_LOOK_DIRECTION_ATTRIBUTE_NAME: string = `{ATTRIBUTE_PREFIX}FlatLookDirection`

const DEFAULT_FLAT_LOOK_DIRECTION: Vector3 = Vector3.new(0, 0, -1)
const YAW_QUANTIZATION_STEP: number = math.rad(0.25)

-- OnGround and GroundHeight are recomputed at the top of every simulation step
-- before anything reads them (grounded hysteresis derives from the replicated
-- Velocity), so replicating them would only spend payload.
const EXCLUDED_STATE_NAMES: { [string]: boolean } = {
	Character = true,
	Humanoid = true,
	RootPart = true,
	CameraLookVector = true,
	OnGround = true,
	GroundNormal = true,
	GroundHeight = true,
}

-- GroundNormal is the one cross-step input to ground detection: the leave gate
-- measures velocity against the plane the character moved along LAST step. It
-- must be captured and restored around rollbacks or the first resimulated step
-- uses the abandoned timeline's plane and the grounded verdict diverges from
-- the server -- most visibly during slides and jumps across ramps and crests.
-- It stays in EXCLUDED_STATE_NAMES so module NeededStates cannot double-bind it.
const CORE_STATE_BINDINGS: { ServerAuthToolkitTypes.StateAttributeBinding } = {
	{
		stateName = "GroundNormal",
		attributeName = `{ATTRIBUTE_PREFIX}GroundNormal`,
		valueType = "Vector3",
		defaultValue = Vector3.yAxis,
	},
}

----------------------------------------------------------------------------------------
-- [[ FIELDS ]] --
----------------------------------------------------------------------------------------

local stateAttributeBindings: { ServerAuthToolkitTypes.StateAttributeBinding } = {}
local warnedUnserializableStateNames: { [string]: boolean } = {}

----------------------------------------------------------------------------------------
-- [[ LOCAL METHODS ]] --
----------------------------------------------------------------------------------------

local function getSerializableValueType(defaultValue: any): ServerAuthToolkitTypes.SerializableValueType?
	local valueType: string = typeof(defaultValue)

	if
		valueType == "boolean"
		or valueType == "number"
		or valueType == "Vector2"
		or valueType == "Vector3"
		or valueType == "string"
	then
		return valueType :: ServerAuthToolkitTypes.SerializableValueType
	end

	return nil
end

local function buildStateAttributeBindings(
	mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults,
	nonReplicatedStateNames: { [string]: boolean }
): { ServerAuthToolkitTypes.StateAttributeBinding }
	local bindings: { ServerAuthToolkitTypes.StateAttributeBinding } = {}

	for stateName: string, defaultValue: any in mergedNeededStates do
		if EXCLUDED_STATE_NAMES[stateName] or nonReplicatedStateNames[stateName] then
			continue
		end

		local valueType: ServerAuthToolkitTypes.SerializableValueType? = getSerializableValueType(defaultValue)

		if not valueType then
			if not warnedUnserializableStateNames[stateName] then
				warnedUnserializableStateNames[stateName] = true
				warn(
					`[ServerAuthToolkit] NeededStates field "{stateName}" ({typeof(defaultValue)}) is not`
						.. ` attribute-serializable and will not replicate or restore on rollback;`
						.. ` use a serializable type or list it in the module's NonReplicatedStates`
				)
			end

			continue
		end

		table.insert(bindings, {
			stateName = stateName,
			attributeName = `{ATTRIBUTE_PREFIX}{stateName}`,
			valueType = valueType,
			defaultValue = defaultValue,
		})
	end

	return bindings
end

local function readVector2(rootPart: BasePart, attributeName: string, fallback: Vector2): Vector2
	local storedValue: unknown = rootPart:GetAttribute(attributeName)

	if typeof(storedValue) == "Vector2" then
		return storedValue :: Vector2
	end

	return fallback
end

local function readBool(rootPart: BasePart, attributeName: string, fallback: boolean): boolean
	local storedValue: unknown = rootPart:GetAttribute(attributeName)

	if typeof(storedValue) == "boolean" then
		return storedValue
	end

	return fallback
end

local function readNumber(rootPart: BasePart, attributeName: string, fallback: number): number
	local storedValue: unknown = rootPart:GetAttribute(attributeName)

	if typeof(storedValue) == "number" then
		return storedValue
	end

	return fallback
end

local function readVector3(rootPart: BasePart, attributeName: string, fallback: Vector3): Vector3
	local storedValue: unknown = rootPart:GetAttribute(attributeName)

	if typeof(storedValue) == "Vector3" then
		return storedValue :: Vector3
	end

	return fallback
end

local function readString(rootPart: BasePart, attributeName: string, fallback: string): string
	local storedValue: unknown = rootPart:GetAttribute(attributeName)

	if typeof(storedValue) == "string" then
		return storedValue
	end

	return fallback
end

local function getReadFallback(
	state: ServerAuthToolkitTypes.MovementState,
	binding: ServerAuthToolkitTypes.StateAttributeBinding
): any
	local currentValue: any = state[binding.stateName]

	if binding.valueType == "boolean" then
		return currentValue == true
	end

	if binding.valueType == "number" then
		if typeof(currentValue) == "number" then
			return currentValue
		end

		return binding.defaultValue
	end

	if binding.valueType == "Vector2" then
		if typeof(currentValue) == "Vector2" then
			return currentValue
		end

		return binding.defaultValue
	end

	if binding.valueType == "Vector3" then
		if typeof(currentValue) == "Vector3" then
			return currentValue
		end

		return binding.defaultValue
	end

	if typeof(currentValue) == "string" then
		return currentValue
	end

	return binding.defaultValue
end

local function applyBindingToState(
	rootPart: BasePart,
	state: ServerAuthToolkitTypes.MovementState,
	binding: ServerAuthToolkitTypes.StateAttributeBinding
): ()
	local fallback: any = getReadFallback(state, binding)

	if binding.valueType == "boolean" then
		state[binding.stateName] = readBool(rootPart, binding.attributeName, fallback)
	elseif binding.valueType == "number" then
		state[binding.stateName] = readNumber(rootPart, binding.attributeName, fallback)
	elseif binding.valueType == "Vector2" then
		state[binding.stateName] = readVector2(rootPart, binding.attributeName, fallback)
	elseif binding.valueType == "Vector3" then
		state[binding.stateName] = readVector3(rootPart, binding.attributeName, fallback)
	else
		state[binding.stateName] = readString(rootPart, binding.attributeName, fallback)
	end
end

local function captureBindingFromState(
	rootPart: BasePart,
	state: ServerAuthToolkitTypes.MovementState,
	binding: ServerAuthToolkitTypes.StateAttributeBinding
): ()
	if binding.valueType == "boolean" then
		rootPart:SetAttribute(binding.attributeName, state[binding.stateName] == true)
	elseif binding.valueType == "number" then
		local currentValue: any = state[binding.stateName]
		rootPart:SetAttribute(
			binding.attributeName,
			if typeof(currentValue) == "number" then currentValue else binding.defaultValue
		)
	elseif binding.valueType == "Vector2" then
		local currentValue: any = state[binding.stateName]
		rootPart:SetAttribute(
			binding.attributeName,
			if typeof(currentValue) == "Vector2" then currentValue else binding.defaultValue
		)
	elseif binding.valueType == "Vector3" then
		local currentValue: any = state[binding.stateName]
		rootPart:SetAttribute(
			binding.attributeName,
			if typeof(currentValue) == "Vector3" then currentValue else binding.defaultValue
		)
	else
		local currentValue: any = state[binding.stateName]
		rootPart:SetAttribute(
			binding.attributeName,
			if typeof(currentValue) == "string" then currentValue else binding.defaultValue
		)
	end
end

local function quantizeFlatDirection(flatDirection: Vector3): Vector3
	if flatDirection.Magnitude < 0.001 then
		return flatDirection
	end

	local yaw: number = math.atan2(-flatDirection.X, -flatDirection.Z)
	yaw = math.round(yaw / YAW_QUANTIZATION_STEP) * YAW_QUANTIZATION_STEP

	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local MovementStateAttributes = {} :: MovementStateAttributes

export type MovementStateAttributes = typeof(MovementStateAttributes) & {
	Configure: (
		self: MovementStateAttributes,
		mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults,
		nonReplicatedStateNames: { [string]: boolean }
	) -> (),
	ApplyToMovementState: (
		self: MovementStateAttributes,
		rootPart: BasePart,
		state: ServerAuthToolkitTypes.MovementState
	) -> (),
	CaptureFromMovementState: (
		self: MovementStateAttributes,
		rootPart: BasePart,
		state: ServerAuthToolkitTypes.MovementState
	) -> (),
	Clear: (self: MovementStateAttributes, rootPart: BasePart) -> (),

	QuantizeFlatDirection: (self: MovementStateAttributes, flatDirection: Vector3) -> Vector3,
	ReadFlatLookDirection: (self: MovementStateAttributes, rootPart: BasePart) -> Vector3,
	WriteFlatLookDirection: (self: MovementStateAttributes, rootPart: BasePart, flatLookDirection: Vector3) -> (),
}

local self: MovementStateAttributes = MovementStateAttributes

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

function MovementStateAttributes.Configure(
	self: MovementStateAttributes,
	mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults,
	nonReplicatedStateNames: { [string]: boolean }
): ()
	local bindings: { ServerAuthToolkitTypes.StateAttributeBinding } =
		buildStateAttributeBindings(mergedNeededStates, nonReplicatedStateNames)

	for _: number, coreBinding: ServerAuthToolkitTypes.StateAttributeBinding in CORE_STATE_BINDINGS do
		table.insert(bindings, coreBinding)
	end

	stateAttributeBindings = bindings
end

function MovementStateAttributes.QuantizeFlatDirection(self: MovementStateAttributes, flatDirection: Vector3): Vector3
	return quantizeFlatDirection(flatDirection)
end

function MovementStateAttributes.ReadFlatLookDirection(self: MovementStateAttributes, rootPart: BasePart): Vector3
	return readVector3(rootPart, FLAT_LOOK_DIRECTION_ATTRIBUTE_NAME, DEFAULT_FLAT_LOOK_DIRECTION)
end

function MovementStateAttributes.WriteFlatLookDirection(
	self: MovementStateAttributes,
	rootPart: BasePart,
	flatLookDirection: Vector3
): ()
	rootPart:SetAttribute(FLAT_LOOK_DIRECTION_ATTRIBUTE_NAME, flatLookDirection)
end

function MovementStateAttributes.ApplyToMovementState(
	self: MovementStateAttributes,
	rootPart: BasePart,
	state: ServerAuthToolkitTypes.MovementState
): ()
	for _: number, binding: ServerAuthToolkitTypes.StateAttributeBinding in stateAttributeBindings do
		applyBindingToState(rootPart, state, binding)
	end
end

function MovementStateAttributes.CaptureFromMovementState(
	self: MovementStateAttributes,
	rootPart: BasePart,
	state: ServerAuthToolkitTypes.MovementState
): ()
	for _: number, binding: ServerAuthToolkitTypes.StateAttributeBinding in stateAttributeBindings do
		captureBindingFromState(rootPart, state, binding)
	end
end

function MovementStateAttributes.Clear(self: MovementStateAttributes, rootPart: BasePart): ()
	for _: number, binding: ServerAuthToolkitTypes.StateAttributeBinding in stateAttributeBindings do
		rootPart:SetAttribute(binding.attributeName, nil)
	end

	rootPart:SetAttribute(FLAT_LOOK_DIRECTION_ATTRIBUTE_NAME, nil)
end

return self
