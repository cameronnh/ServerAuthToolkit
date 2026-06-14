----------------------------------------------------------------------------------------
-- [[ ROBLOX SERVICES ]] --
----------------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkitTypes = require(script.Parent.ServerAuthToolkitTypes)

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local AnimationHelper = {} :: AnimationHelper

export type AnimationHelper = typeof(AnimationHelper) & {
	RegisterAnimation: (
		self: AnimationHelper,
		animationName: string,
		animationSettings: ServerAuthToolkitTypes.AnimationSettings
	) -> (),
	PlayAnimation: (self: AnimationHelper, animationName: string, speedOverride: number?) -> (),
	StopAnimation: (self: AnimationHelper, animationName: string) -> (),
	IsAnimationPlaying: (self: AnimationHelper, animationName: string) -> boolean,
	IsAnimationFinished: (self: AnimationHelper, animationName: string) -> boolean,

	SetProcessingRootPart: (self: AnimationHelper, rootPart: BasePart?) -> (),
	Start: (self: AnimationHelper) -> (),
	HumanoidAdded: (self: AnimationHelper, humanoid: Humanoid) -> (),
}

local self: AnimationHelper = AnimationHelper

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

local ANIMATION_ATTRIBUTE_PREFIX: string = "ServerAuthToolkitAnim_"
local ONE_SHOT_FINISH_PLAYTHROUGH: number = 0.98

----------------------------------------------------------------------------------------
-- [[ FIELDS ]] --
----------------------------------------------------------------------------------------

local Animations: { [string]: ServerAuthToolkitTypes.AnimationSettings } = {}
local CharacterStates: { [BasePart]: ServerAuthToolkitTypes.CharacterAnimationState } = {}
local LocalDesiredAnimations: { [BasePart]: { [string]: boolean } } = {}
local AlreadyPlayingAnimations: { [string]: boolean } = {}
local ProcessingCharacterState: ServerAuthToolkitTypes.CharacterAnimationState? = nil
local SimulationBound: boolean = false
local PendingSpeedOverrides: { [string]: number } = {}
local IsClient: boolean = RunService:IsClient()

----------------------------------------------------------------------------------------
-- [[ LOCAL METHODS ]] --
----------------------------------------------------------------------------------------

local function getAnimationAttributeName(animationName: string): string
	return `{ANIMATION_ATTRIBUTE_PREFIX}{animationName}`
end

-- Animation attributes must NOT live on the HumanoidRootPart: it is a predicted
-- instance, and any server-side attribute change the client did not predict
-- triggers a full rollback and resimulation. The character model is not
-- predicted, so its attributes replicate normally without affecting prediction.
local function getAnimationAttributeHolder(rootPart: BasePart): Instance
	return rootPart.Parent or rootPart
end

local function isAlreadyPlaying(animationName: string): boolean
	return AlreadyPlayingAnimations[animationName] == true
end

local function usesLocalAnimationAuthority(rootPart: BasePart): boolean
	if not IsClient then
		return false
	end

	local character: Model? = Players.LocalPlayer.Character

	if not character then
		return false
	end

	return rootPart == character:FindFirstChild("HumanoidRootPart")
end

local function initializeLocalDesiredAnimations(rootPart: BasePart): ()
	local desiredState: { [string]: boolean } = {}

	for animationName: string, _: ServerAuthToolkitTypes.AnimationSettings in Animations do
		desiredState[animationName] = isAlreadyPlaying(animationName)
	end

	LocalDesiredAnimations[rootPart] = desiredState
end

local function getDesiredAnimationShouldPlay(rootPart: BasePart, animationName: string): boolean?
	if usesLocalAnimationAuthority(rootPart) then
		local desiredState: { [string]: boolean }? = LocalDesiredAnimations[rootPart]

		if not desiredState then
			return nil
		end

		return desiredState[animationName]
	end

	return getAnimationAttributeHolder(rootPart):GetAttribute(getAnimationAttributeName(animationName)) :: boolean?
end

local function setDesiredAnimationShouldPlay(rootPart: BasePart, animationName: string, shouldPlay: boolean): ()
	if usesLocalAnimationAuthority(rootPart) then
		local desiredState: { [string]: boolean }? = LocalDesiredAnimations[rootPart]

		if desiredState then
			desiredState[animationName] = shouldPlay
		end

		return
	end

	getAnimationAttributeHolder(rootPart):SetAttribute(getAnimationAttributeName(animationName), shouldPlay)
end

local function getOrCreateAnimator(humanoid: Humanoid): Animator?
	local existingAnimator: Animator? = humanoid:FindFirstChildOfClass("Animator")

	if existingAnimator then
		return existingAnimator
	end

	local newAnimator: Animator = Instance.new("Animator")
	newAnimator.Parent = humanoid

	return newAnimator
end

local function loadAnimationTrack(
	characterState: ServerAuthToolkitTypes.CharacterAnimationState,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.AnimationSettings
): AnimationTrack
	local animationTrack: AnimationTrack = characterState.animator:LoadAnimation(animationSettings.Animation)

	animationTrack.Priority = animationSettings.Priority
	animationTrack.Looped = animationSettings.Looped == true

	characterState.tracks[animationName] = animationTrack

	if animationSettings.Looped ~= true then
		animationTrack.Ended:Connect(function()
			characterState.oneShotFinished[animationName] = true
			setDesiredAnimationShouldPlay(characterState.rootPart, animationName, false)
		end)
	end

	return animationTrack
end

local function playAnimationTrack(
	characterState: ServerAuthToolkitTypes.CharacterAnimationState,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.AnimationSettings
): ()
	local animationTrack: AnimationTrack? = characterState.tracks[animationName]

	if not animationTrack then
		return
	end

	animationTrack.Priority = animationSettings.Priority
	animationTrack.Looped = animationSettings.Looped == true

	if animationSettings.Looped ~= true then
		if characterState.oneShotFinished[animationName] == true then
			return
		end

		if not animationTrack.IsPlaying and animationTrack.Length > 0 then
			local playthrough: number = animationTrack.TimePosition / animationTrack.Length

			if playthrough >= ONE_SHOT_FINISH_PLAYTHROUGH then
				characterState.oneShotFinished[animationName] = true
				return
			end
		end
	end

	if animationTrack.IsPlaying then
		local speed: number = PendingSpeedOverrides[animationName] or animationSettings.Speed

		if speed ~= animationTrack.Speed then
			animationTrack:AdjustSpeed(speed)
		end

		if animationSettings.Weight ~= animationTrack.WeightCurrent then
			animationTrack:AdjustWeight(animationSettings.Weight)
		end

		PendingSpeedOverrides[animationName] = nil
		return
	end

	local speed: number = PendingSpeedOverrides[animationName] or animationSettings.Speed
	PendingSpeedOverrides[animationName] = nil

	animationTrack:Play(animationSettings.FadeTime)
	animationTrack:AdjustSpeed(speed)
	animationTrack:AdjustWeight(animationSettings.Weight)
end

local function stopAnimationTrack(
	characterState: ServerAuthToolkitTypes.CharacterAnimationState,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.AnimationSettings
): ()
	local animationTrack: AnimationTrack? = characterState.tracks[animationName]

	if not animationTrack or not animationTrack.IsPlaying then
		return
	end

	animationTrack:Stop(animationSettings.StopFadeTime)
end

local function syncCharacterAnimationState(characterState: ServerAuthToolkitTypes.CharacterAnimationState): ()
	for animationName: string, animationSettings: ServerAuthToolkitTypes.AnimationSettings in Animations do
		local shouldPlay: boolean? = getDesiredAnimationShouldPlay(characterState.rootPart, animationName)

		if shouldPlay == nil then
			continue
		end

		if shouldPlay then
			if not animationSettings.Looped and characterState.oneShotFinished[animationName] == true then
				setDesiredAnimationShouldPlay(characterState.rootPart, animationName, false)
				continue
			end

			playAnimationTrack(characterState, animationName, animationSettings)
		else
			stopAnimationTrack(characterState, animationName, animationSettings)
		end
	end
end

local function stepAnimationSimulation(_deltaTime: number): ()
	for rootPart: BasePart, characterState: ServerAuthToolkitTypes.CharacterAnimationState in CharacterStates do
		if not rootPart.Parent then
			CharacterStates[rootPart] = nil
			LocalDesiredAnimations[rootPart] = nil
			continue
		end

		syncCharacterAnimationState(characterState)
	end
end

local function bindAnimationSimulation(): ()
	if SimulationBound then
		return
	end

	SimulationBound = true

	RunService:BindToSimulation(stepAnimationSimulation, Enum.StepFrequency.Hz60)
end

local function setPlayingAnimationState(rootPart: BasePart?, animationName: string, shouldPlay: boolean): ()
	if rootPart then
		local characterState: ServerAuthToolkitTypes.CharacterAnimationState? = CharacterStates[rootPart]

		if shouldPlay and characterState then
			local animationSettings: ServerAuthToolkitTypes.AnimationSettings? = Animations[animationName]
			local animationTrack: AnimationTrack? = characterState.tracks[animationName]

			if animationSettings and not animationSettings.Looped and animationTrack then
				animationTrack.Looped = false

				if animationTrack.IsPlaying then
					setDesiredAnimationShouldPlay(rootPart, animationName, true)
					return
				end

				characterState.oneShotFinished[animationName] = nil

				if animationTrack.IsPlaying then
					animationTrack:Stop(0)
				end

				animationTrack.TimePosition = 0
			end
		elseif not shouldPlay and characterState then
			local animationSettings: ServerAuthToolkitTypes.AnimationSettings? = Animations[animationName]

			if animationSettings and not animationSettings.Looped then
				characterState.oneShotFinished[animationName] = true
			end
		end

		setDesiredAnimationShouldPlay(rootPart, animationName, shouldPlay)
		return
	end

	AlreadyPlayingAnimations[animationName] = shouldPlay
end

local function applyAlreadyPlayingAnimations(characterState: ServerAuthToolkitTypes.CharacterAnimationState): ()
	for animationName: string, _: ServerAuthToolkitTypes.AnimationSettings in Animations do
		setDesiredAnimationShouldPlay(characterState.rootPart, animationName, isAlreadyPlaying(animationName))
	end
end

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

function AnimationHelper.RegisterAnimation(
	self: AnimationHelper,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.AnimationSettings
): ()
	Animations[animationName] = animationSettings

	if AlreadyPlayingAnimations[animationName] == nil then
		AlreadyPlayingAnimations[animationName] = false
	end

	for _: BasePart, characterState: ServerAuthToolkitTypes.CharacterAnimationState in CharacterStates do
		loadAnimationTrack(characterState, animationName, animationSettings)
		setDesiredAnimationShouldPlay(characterState.rootPart, animationName, isAlreadyPlaying(animationName))
	end
end

function AnimationHelper.SetProcessingRootPart(self: AnimationHelper, rootPart: BasePart?): ()
	if not rootPart then
		ProcessingCharacterState = nil
		return
	end

	ProcessingCharacterState = CharacterStates[rootPart]
end

function AnimationHelper.PlayAnimation(self: AnimationHelper, animationName: string, speedOverride: number?): ()
	if not Animations[animationName] then
		warn(`[AnimationHelper] Attempted to play unregistered animation "{animationName}"`)
		return
	end

	if speedOverride then
		PendingSpeedOverrides[animationName] = speedOverride
	end

	local rootPart: BasePart? = ProcessingCharacterState and ProcessingCharacterState.rootPart or nil
	setPlayingAnimationState(rootPart, animationName, true)
end

function AnimationHelper.StopAnimation(self: AnimationHelper, animationName: string): ()
	if not Animations[animationName] then
		warn(`[AnimationHelper] Attempted to stop unregistered animation "{animationName}"`)
		return
	end

	local rootPart: BasePart? = ProcessingCharacterState and ProcessingCharacterState.rootPart or nil
	setPlayingAnimationState(rootPart, animationName, false)
end

function AnimationHelper.IsAnimationPlaying(self: AnimationHelper, animationName: string): boolean
	if not Animations[animationName] then
		return false
	end

	if ProcessingCharacterState then
		local animationTrack: AnimationTrack? = ProcessingCharacterState.tracks[animationName]

		return animationTrack ~= nil and animationTrack.IsPlaying
	end

	return AlreadyPlayingAnimations[animationName] == true
end

function AnimationHelper.IsAnimationFinished(self: AnimationHelper, animationName: string): boolean
	local animationSettings: ServerAuthToolkitTypes.AnimationSettings? = Animations[animationName]

	if not animationSettings or animationSettings.Looped then
		return false
	end

	if not ProcessingCharacterState then
		return false
	end

	local animationTrack: AnimationTrack? = ProcessingCharacterState.tracks[animationName]

	if not animationTrack or animationTrack.Length <= 0 then
		return false
	end

	local playthrough: number = animationTrack.TimePosition / animationTrack.Length

	return playthrough >= ONE_SHOT_FINISH_PLAYTHROUGH
end

function AnimationHelper.Start(self: AnimationHelper): ()
	bindAnimationSimulation()
end

function AnimationHelper.HumanoidAdded(self: AnimationHelper, humanoid: Humanoid): ()
	local rootPart: BasePart? = humanoid.RootPart

	if not rootPart then
		return
	end

	if CharacterStates[rootPart] then
		return
	end

	local animator: Animator? = getOrCreateAnimator(humanoid)

	if not animator then
		warn("[AnimationHelper] Failed to create Animator for character")
		return
	end

	local characterState: ServerAuthToolkitTypes.CharacterAnimationState = {
		rootPart = rootPart,
		animator = animator,
		tracks = {},
		oneShotFinished = {},
	}

	CharacterStates[rootPart] = characterState

	if usesLocalAnimationAuthority(rootPart) then
		initializeLocalDesiredAnimations(rootPart)
	end

	for animationName: string, animationSettings: ServerAuthToolkitTypes.AnimationSettings in Animations do
		loadAnimationTrack(characterState, animationName, animationSettings)
	end

	applyAlreadyPlayingAnimations(characterState)

	humanoid.Destroying:Connect(function()
		CharacterStates[rootPart] = nil
		LocalDesiredAnimations[rootPart] = nil
	end)
end

return self
