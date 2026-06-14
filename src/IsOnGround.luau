----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkitTypes = require(script.Parent.ServerAuthToolkitTypes)

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local IsOnGround = {} :: IsOnGround

export type IsOnGround = typeof(IsOnGround) & {
	Get: (self: IsOnGround, state: ServerAuthToolkitTypes.MovementState) -> (boolean, Vector3),
}

local self: IsOnGround = IsOnGround

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

const GROUND_RAY_DISTANCE: number = 8
const GROUND_RAY_MAX_GAP: number = 3.25
const GROUND_RAYCAST_ORIGIN_SNAP: number = 0.25
const MIN_WALKABLE_NORMAL_Y: number = 0.35
const GROUND_LEAVE_VERTICAL_SPEED: number = 2

const DEFAULT_GROUND_NORMAL: Vector3 = Vector3.yAxis

----------------------------------------------------------------------------------------
-- [[ FIELDS ]] --
----------------------------------------------------------------------------------------

local GroundRaycastParams: RaycastParams = RaycastParams.new()
GroundRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

----------------------------------------------------------------------------------------
-- [[ LOCAL METHODS ]] --
----------------------------------------------------------------------------------------

local function getDeterministicRaycastOrigin(rootPart: BasePart): Vector3
	local position: Vector3 = rootPart.Position
	local snap: number = GROUND_RAYCAST_ORIGIN_SNAP

	return Vector3.new(
		math.round(position.X / snap) * snap,
		math.round(position.Y / snap) * snap,
		math.round(position.Z / snap) * snap
	)
end

local function isOnGround(state: ServerAuthToolkitTypes.MovementState): (boolean, Vector3)
	local rootPart: BasePart? = state.RootPart
	local character: Model? = state.Character

	if not rootPart or not character then
		return false, DEFAULT_GROUND_NORMAL
	end

	GroundRaycastParams.FilterDescendantsInstances = { character }

	local rayOrigin: Vector3 = getDeterministicRaycastOrigin(rootPart)
	local rayDirection: Vector3 = Vector3.new(0, -GROUND_RAY_DISTANCE, 0)
	local groundHit: RaycastResult? = workspace:Raycast(rayOrigin, rayDirection, GroundRaycastParams)

	if not groundHit or not groundHit.Instance then
		return false, DEFAULT_GROUND_NORMAL
	end

	local groundNormal: Vector3 = groundHit.Normal

	if groundNormal.Y < MIN_WALKABLE_NORMAL_Y then
		return false, DEFAULT_GROUND_NORMAL
	end

	local velocity: Vector3 = state.Velocity or Vector3.zero

	if velocity:Dot(groundNormal) > GROUND_LEAVE_VERTICAL_SPEED then
		return false, DEFAULT_GROUND_NORMAL
	end

	local allowedGap: number = GROUND_RAY_MAX_GAP / groundNormal.Y

	if groundHit.Distance > allowedGap then
		return false, DEFAULT_GROUND_NORMAL
	end

	return true, groundNormal
end

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

function IsOnGround.Get(self: IsOnGround, state: ServerAuthToolkitTypes.MovementState): (boolean, Vector3)
	return isOnGround(state)
end

return self
