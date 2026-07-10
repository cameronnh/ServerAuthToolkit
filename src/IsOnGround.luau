----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkitTypes = require(script.Parent.ServerAuthToolkitTypes)

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local IsOnGround = {} :: IsOnGround

export type IsOnGround = typeof(IsOnGround) & {
	Get: (self: IsOnGround, state: ServerAuthToolkitTypes.MovementState) -> (boolean, Vector3, number?),
	GetRootStandHeight: (self: IsOnGround, state: ServerAuthToolkitTypes.MovementState) -> number?,
	GetVerticalSpeedExcess: (self: IsOnGround, velocity: Vector3, groundNormal: Vector3) -> number,
	GetMaxStepHeight: (self: IsOnGround) -> number,
}

local self: IsOnGround = IsOnGround

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

const GROUND_RAY_DISTANCE: number = 12
const GROUND_RAYCAST_ORIGIN_SNAP: number = 0.25
const MIN_WALKABLE_NORMAL_Y: number = 0.35
const GROUND_LEAVE_VERTICAL_SPEED: number = 2
const EPSILON: number = 0.001

const GROUND_RAY_HORIZONTAL_OFFSET: number = 0.7
const MAX_STEP_HEIGHT: number = 2.25
const LANDING_GAP: number = 0.35
const FALLBACK_GROUND_RAY_MAX_GAP: number = 3.25

const DEFAULT_GROUND_NORMAL: Vector3 = Vector3.yAxis
const DEFAULT_R6_LEG_HEIGHT: number = 2

const SEAM_PROBE_OFFSETS: { Vector3 } = {
	Vector3.new(0.5, 0, 0),
	Vector3.new(-0.5, 0, 0),
	Vector3.new(0, 0, 0.5),
	Vector3.new(0, 0, -0.5),
}

----------------------------------------------------------------------------------------
-- [[ FIELDS ]] --
----------------------------------------------------------------------------------------

local GroundRaycastParams: RaycastParams = RaycastParams.new()
GroundRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
GroundRaycastParams.RespectCanCollide = true

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

local function isWalkableHit(groundHit: RaycastResult?): boolean
	return groundHit ~= nil and groundHit.Instance ~= nil and groundHit.Normal.Y >= MIN_WALKABLE_NORMAL_Y
end

local function castGroundRay(rayOrigin: Vector3): RaycastResult?
	return workspace:Raycast(rayOrigin, Vector3.new(0, -GROUND_RAY_DISTANCE, 0), GroundRaycastParams)
end

local function getRootStandHeight(state: ServerAuthToolkitTypes.MovementState): number?
	local humanoid: Humanoid? = state.Humanoid
	local rootPart: BasePart? = state.RootPart
	local character: Model? = state.Character

	if not humanoid or not rootPart or not character then
		return nil
	end

	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local leftLeg: Instance? = character:FindFirstChild("Left Leg")
		local legHeight: number = if leftLeg and leftLeg:IsA("BasePart") then leftLeg.Size.Y else DEFAULT_R6_LEG_HEIGHT

		return legHeight + rootPart.Size.Y / 2 + humanoid.HipHeight
	end

	return humanoid.HipHeight + rootPart.Size.Y / 2
end

-- Vertical speed beyond what following the ground plane accounts for. Riding a
-- ramp keeps this near zero while jump or knockback velocity pushes past it.
local function getVerticalSpeedExcess(velocity: Vector3, groundNormal: Vector3): number
	if groundNormal.Y < EPSILON then
		return velocity.Y
	end

	local planeVerticalSpeed: number = -(velocity.X * groundNormal.X + velocity.Z * groundNormal.Z) / groundNormal.Y

	return velocity.Y - planeVerticalSpeed
end

local function isOnGround(state: ServerAuthToolkitTypes.MovementState): (boolean, Vector3, number?)
	local rootPart: BasePart? = state.RootPart
	local character: Model? = state.Character

	if not rootPart or not character then
		return false, DEFAULT_GROUND_NORMAL, nil
	end

	GroundRaycastParams.FilterDescendantsInstances = { character }
	GroundRaycastParams.CollisionGroup = rootPart.CollisionGroup

	local rayOrigin: Vector3 = getDeterministicRaycastOrigin(rootPart)
	local groundHit: RaycastResult? = castGroundRay(rayOrigin)

	if not isWalkableHit(groundHit) then
		for _: number, probeOffset: Vector3 in SEAM_PROBE_OFFSETS do
			local probeHit: RaycastResult? = castGroundRay(rayOrigin + probeOffset)

			if not isWalkableHit(probeHit) then
				continue
			end

			if
				not isWalkableHit(groundHit)
				or (probeHit :: RaycastResult).Position.Y > (groundHit :: RaycastResult).Position.Y
			then
				groundHit = probeHit
			end
		end
	end

	if not groundHit or not isWalkableHit(groundHit) then
		return false, DEFAULT_GROUND_NORMAL, nil
	end

	local groundNormal: Vector3 = groundHit.Normal
	local velocity: Vector3 = state.Velocity or Vector3.zero

	local previousGroundNormal: Vector3 = if typeof(state.GroundNormal) == "Vector3"
		then state.GroundNormal :: Vector3
		else groundNormal

	if getVerticalSpeedExcess(velocity, previousGroundNormal) > GROUND_LEAVE_VERTICAL_SPEED then
		return false, DEFAULT_GROUND_NORMAL, nil
	end

	local rootStandHeight: number? = getRootStandHeight(state)
	local allowedGap: number

	if rootStandHeight then
		local verticalSpeedExcess: number = getVerticalSpeedExcess(velocity, groundNormal)
		local isFollowingGround: boolean = verticalSpeedExcess > -GROUND_LEAVE_VERTICAL_SPEED
		local gapAllowance: number = if isFollowingGround then MAX_STEP_HEIGHT else LANDING_GAP
		local slopeTangent: number = math.sqrt(math.max(0, 1 - groundNormal.Y * groundNormal.Y)) / groundNormal.Y

		allowedGap = rootStandHeight
			+ gapAllowance
			+ GROUND_RAYCAST_ORIGIN_SNAP / 2
			+ GROUND_RAY_HORIZONTAL_OFFSET * slopeTangent
	else
		allowedGap = FALLBACK_GROUND_RAY_MAX_GAP / groundNormal.Y
	end

	if groundHit.Distance > allowedGap then
		return false, DEFAULT_GROUND_NORMAL, nil
	end

	return true, groundNormal, groundHit.Position.Y
end

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

function IsOnGround.Get(self: IsOnGround, state: ServerAuthToolkitTypes.MovementState): (boolean, Vector3, number?)
	return isOnGround(state)
end

function IsOnGround.GetRootStandHeight(self: IsOnGround, state: ServerAuthToolkitTypes.MovementState): number?
	return getRootStandHeight(state)
end

function IsOnGround.GetVerticalSpeedExcess(self: IsOnGround, velocity: Vector3, groundNormal: Vector3): number
	return getVerticalSpeedExcess(velocity, groundNormal)
end

function IsOnGround.GetMaxStepHeight(self: IsOnGround): number
	return MAX_STEP_HEIGHT
end

return self
