----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkitTypes = require(script.Parent.ServerAuthToolkitTypes)

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local MovementStateBuilder = {} :: MovementStateBuilder

export type MovementStateBuilder = typeof(MovementStateBuilder) & {
	GetMergedNeededStates: (
		self: MovementStateBuilder,
		definitions: { ServerAuthToolkitTypes.MovementModuleDefinition }
	) -> ServerAuthToolkitTypes.NeededStatesDefaults,
	CreateMovementState: (
		self: MovementStateBuilder,
		mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults
	) -> ServerAuthToolkitTypes.MovementState,
	ResetNeededStates: (
		self: MovementStateBuilder,
		state: ServerAuthToolkitTypes.MovementState,
		mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults
	) -> (),
	ApplyNeededStatesFromDefinition: (
		self: MovementStateBuilder,
		state: ServerAuthToolkitTypes.MovementState,
		definition: ServerAuthToolkitTypes.MovementModuleDefinition
	) -> (),
}

----------------------------------------------------------------------------------------
-- [[ LOCAL METHODS ]] --
----------------------------------------------------------------------------------------

local function copyDefaultValue(defaultValue: any): any
	if typeof(defaultValue) == "Vector2" then
		return defaultValue :: Vector2
	end

	if typeof(defaultValue) == "Vector3" then
		return defaultValue :: Vector3
	end

	if typeof(defaultValue) == "table" then
		return table.clone(defaultValue)
	end

	return defaultValue
end

local function defaultsConflict(existingDefault: any, newDefault: any): boolean
	if typeof(existingDefault) ~= typeof(newDefault) then
		return true
	end

	if typeof(existingDefault) == "Vector2" then
		return (existingDefault :: Vector2) ~= (newDefault :: Vector2)
	end

	if typeof(existingDefault) == "Vector3" then
		return (existingDefault :: Vector3) ~= (newDefault :: Vector3)
	end

	return existingDefault ~= newDefault
end

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

function MovementStateBuilder.GetMergedNeededStates(
	self: MovementStateBuilder,
	definitions: { ServerAuthToolkitTypes.MovementModuleDefinition }
): ServerAuthToolkitTypes.NeededStatesDefaults
	local mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults = {}

	for _: number, definition: ServerAuthToolkitTypes.MovementModuleDefinition in definitions do
		for stateName: string, defaultValue: any in definition.NeededStates do
			local existingDefault: any = mergedNeededStates[stateName]

			if existingDefault ~= nil and defaultsConflict(existingDefault, defaultValue) then
				warn(`[MovementStateBuilder] Conflicting default for "{stateName}" in module "{definition.Name}"`)
				continue
			end

			if existingDefault == nil then
				mergedNeededStates[stateName] = copyDefaultValue(defaultValue)
			end
		end
	end

	return mergedNeededStates
end

function MovementStateBuilder.CreateMovementState(
	self: MovementStateBuilder,
	mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults
): ServerAuthToolkitTypes.MovementState
	local movementState: ServerAuthToolkitTypes.MovementState = {
		Character = nil :: Model?,
		Humanoid = nil :: Humanoid?,
		RootPart = nil :: BasePart?,
	}

	for stateName: string, defaultValue: any in mergedNeededStates do
		movementState[stateName] = copyDefaultValue(defaultValue)
	end

	return movementState
end

function MovementStateBuilder.ResetNeededStates(
	self: MovementStateBuilder,
	state: ServerAuthToolkitTypes.MovementState,
	mergedNeededStates: ServerAuthToolkitTypes.NeededStatesDefaults
): ()
	for stateName: string, defaultValue: any in mergedNeededStates do
		state[stateName] = copyDefaultValue(defaultValue)
	end
end

function MovementStateBuilder.ApplyNeededStatesFromDefinition(
	self: MovementStateBuilder,
	state: ServerAuthToolkitTypes.MovementState,
	definition: ServerAuthToolkitTypes.MovementModuleDefinition
): ()
	for stateName: string, defaultValue: any in definition.NeededStates do
		if state[stateName] == nil then
			state[stateName] = copyDefaultValue(defaultValue)
		end
	end
end

return MovementStateBuilder
