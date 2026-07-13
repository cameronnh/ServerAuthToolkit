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
	RestartAnimation: (self: AnimationHelper, animationName: string, speedOverride: number?) -> (),
	StopAnimation: (self: AnimationHelper, animationName: string, stopFadeTimeOverride: number?) -> (),
	StopAnimationInterrupt: (self: AnimationHelper, animationName: string) -> (),
	IsAnimationPlaying: (self: AnimationHelper, animationName: string) -> boolean,
	IsAnimationFinished: (self: AnimationHelper, animationName: string) -> boolean,
	GetLoadedTrackLength: (self: AnimationHelper, rootPart: BasePart, animationName: string) -> number?,
	IsCharacterTracked: (self: AnimationHelper, rootPart: BasePart) -> boolean,

	SetProcessingRootPart: (self: AnimationHelper, rootPart: BasePart?) -> (),
	Start: (self: AnimationHelper) -> (),
	HumanoidAdded: (self: AnimationHelper, humanoid: Humanoid) -> (),
}

local self: AnimationHelper = AnimationHelper

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

const ANIMATION_ATTRIBUTE_PREFIX: string = "SATAnim_"
const ONE_SHOT_FINISH_PLAYTHROUGH: number = 0.98

const DEFAULT_ANIMATION_SPEED: number = 1
const DEFAULT_ANIMATION_WEIGHT: number = 1
const DEFAULT_ANIMATION_FADE_TIME: number = 0.1
const DEFAULT_ANIMATION_STOP_FADE_TIME: number = 0.1
const DEFAULT_ANIMATION_PRIORITY: Enum.AnimationPriority = Enum.AnimationPriority.Action

----------------------------------------------------------------------------------------
-- [[ FIELDS ]] --
----------------------------------------------------------------------------------------

local Animations: { [string]: ServerAuthToolkitTypes.ResolvedAnimationSettings } = {}
local CharacterStates: { [BasePart]: ServerAuthToolkitTypes.CharacterAnimationState } = {}
local LocalDesiredAnimations: { [BasePart]: { [string]: boolean } } = {}
local AlreadyPlayingAnimations: { [string]: boolean } = {}
local ProcessingCharacterState: ServerAuthToolkitTypes.CharacterAnimationState? = nil
local ReconcileBound: boolean = false
local PendingSpeedOverrides: { [BasePart]: { [string]: number } } = {}
local GlobalPendingSpeedOverrides: { [string]: number } = {}
local PendingStopFadeOverrides: { [BasePart]: { [string]: number } } = {}
local OneShotRestartRequests: { [BasePart]: { [string]: boolean } } = {}
local ForceRestartRequests: { [BasePart]: { [string]: boolean } } = {}
local LastObservedDesired: { [BasePart]: { [string]: boolean } } = {}
local LoopedAnimationTimePositions: { [BasePart]: { [string]: number } } = {}
local LoopedTrackWasPlaying: { [BasePart]: { [string]: boolean } } = {}
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

	for animationName: string, _: ServerAuthToolkitTypes.ResolvedAnimationSettings in Animations do
		if isAlreadyPlaying(animationName) then
			desiredState[animationName] = true
		end
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

local function setDesiredAnimationShouldPlay(rootPart: BasePart, animationName: string, shouldPlay: boolean?): ()
	if usesLocalAnimationAuthority(rootPart) then
		local desiredState: { [string]: boolean }? = LocalDesiredAnimations[rootPart]

		if desiredState then
			if shouldPlay == true then
				desiredState[animationName] = true
			else
				desiredState[animationName] = nil
			end
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

local function rememberLoopedTimePosition(rootPart: BasePart, animationName: string, animationTrack: AnimationTrack): ()
	if animationTrack.Length <= 0 then
		return
	end

	local savedByAnimation: { [string]: number } = LoopedAnimationTimePositions[rootPart]

	if not savedByAnimation then
		savedByAnimation = {}
		LoopedAnimationTimePositions[rootPart] = savedByAnimation
	end

	savedByAnimation[animationName] = animationTrack.TimePosition
end

local function getRememberedLoopedTimePosition(rootPart: BasePart, animationName: string): number?
	local savedByAnimation: { [string]: number }? = LoopedAnimationTimePositions[rootPart]

	if not savedByAnimation then
		return nil
	end

	return savedByAnimation[animationName]
end

local function clearRememberedLoopedTimePosition(rootPart: BasePart, animationName: string): ()
	local savedByAnimation: { [string]: number }? = LoopedAnimationTimePositions[rootPart]

	if not savedByAnimation then
		return
	end

	savedByAnimation[animationName] = nil
end

local function setLoopedTrackWasPlaying(rootPart: BasePart, animationName: string, wasPlaying: boolean): ()
	if not wasPlaying then
		local wasPlayingByAnimation: { [string]: boolean }? = LoopedTrackWasPlaying[rootPart]

		if wasPlayingByAnimation then
			wasPlayingByAnimation[animationName] = nil
		end

		return
	end

	local wasPlayingByAnimation: { [string]: boolean } = LoopedTrackWasPlaying[rootPart]

	if not wasPlayingByAnimation then
		wasPlayingByAnimation = {}
		LoopedTrackWasPlaying[rootPart] = wasPlayingByAnimation
	end

	wasPlayingByAnimation[animationName] = true
end

local function getLoopedTrackWasPlaying(rootPart: BasePart, animationName: string): boolean
	local wasPlayingByAnimation: { [string]: boolean }? = LoopedTrackWasPlaying[rootPart]

	return wasPlayingByAnimation ~= nil and wasPlayingByAnimation[animationName] == true
end

local function clearLoopedTrackResumeState(rootPart: BasePart, animationName: string): ()
	clearRememberedLoopedTimePosition(rootPart, animationName)
	setLoopedTrackWasPlaying(rootPart, animationName, false)
end

local function setPendingSpeedOverride(rootPart: BasePart, animationName: string, speed: number): ()
	local overridesByAnimation: { [string]: number } = PendingSpeedOverrides[rootPart]

	if not overridesByAnimation then
		overridesByAnimation = {}
		PendingSpeedOverrides[rootPart] = overridesByAnimation
	end

	overridesByAnimation[animationName] = speed
end

local function consumePendingSpeedOverride(rootPart: BasePart, animationName: string): number?
	local overridesByAnimation: { [string]: number }? = PendingSpeedOverrides[rootPart]

	if not overridesByAnimation then
		return nil
	end

	local speed: number? = overridesByAnimation[animationName]

	overridesByAnimation[animationName] = nil

	return speed
end

local function setOneShotRestartRequested(rootPart: BasePart, animationName: string): ()
	local requestsByAnimation: { [string]: boolean } = OneShotRestartRequests[rootPart]

	if not requestsByAnimation then
		requestsByAnimation = {}
		OneShotRestartRequests[rootPart] = requestsByAnimation
	end

	requestsByAnimation[animationName] = true
end

local function consumeOneShotRestartRequested(rootPart: BasePart, animationName: string): boolean
	local requestsByAnimation: { [string]: boolean }? = OneShotRestartRequests[rootPart]

	if not requestsByAnimation then
		return false
	end

	local wasRequested: boolean = requestsByAnimation[animationName] == true

	requestsByAnimation[animationName] = nil

	return wasRequested
end

local function setForceRestartRequested(rootPart: BasePart, animationName: string): ()
	local requestsByAnimation: { [string]: boolean } = ForceRestartRequests[rootPart]

	if not requestsByAnimation then
		requestsByAnimation = {}
		ForceRestartRequests[rootPart] = requestsByAnimation
	end

	requestsByAnimation[animationName] = true
end

local function consumeForceRestartRequested(rootPart: BasePart, animationName: string): boolean
	local requestsByAnimation: { [string]: boolean }? = ForceRestartRequests[rootPart]

	if not requestsByAnimation then
		return false
	end

	local wasRequested: boolean = requestsByAnimation[animationName] == true

	requestsByAnimation[animationName] = nil

	return wasRequested
end

local function getLastObservedDesired(rootPart: BasePart, animationName: string): boolean
	local desiredByAnimation: { [string]: boolean }? = LastObservedDesired[rootPart]

	return desiredByAnimation ~= nil and desiredByAnimation[animationName] == true
end

local function setLastObservedDesired(rootPart: BasePart, animationName: string, isDesired: boolean): ()
	local desiredByAnimation: { [string]: boolean } = LastObservedDesired[rootPart]

	if not desiredByAnimation then
		desiredByAnimation = {}
		LastObservedDesired[rootPart] = desiredByAnimation
	end

	desiredByAnimation[animationName] = if isDesired then true else nil
end

local function loadAnimationTrack(
	characterState: ServerAuthToolkitTypes.CharacterAnimationState,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings
): AnimationTrack
	local animationTrack: AnimationTrack = characterState.animator:LoadAnimation(animationSettings.Animation)

	animationTrack.Priority = animationSettings.Priority
	animationTrack.Looped = animationSettings.Looped == true

	characterState.tracks[animationName] = animationTrack

	if animationSettings.Looped ~= true then
		animationTrack.Ended:Connect(function()
			characterState.oneShotFinished[animationName] = true
			setDesiredAnimationShouldPlay(characterState.rootPart, animationName, nil)
		end)
	end

	return animationTrack
end

local function playAnimationTrack(
	characterState: ServerAuthToolkitTypes.CharacterAnimationState,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings
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

	local pendingSpeed: number? = consumePendingSpeedOverride(characterState.rootPart, animationName)

	if pendingSpeed == nil then
		pendingSpeed = GlobalPendingSpeedOverrides[animationName]
		GlobalPendingSpeedOverrides[animationName] = nil
	end

	local speed: number = pendingSpeed or animationSettings.Speed

	if animationTrack.IsPlaying then
		if animationSettings.Looped == true then
			rememberLoopedTimePosition(characterState.rootPart, animationName, animationTrack)
			setLoopedTrackWasPlaying(characterState.rootPart, animationName, true)
		end

		if speed ~= animationTrack.Speed then
			animationTrack:AdjustSpeed(speed)
		end

		-- Compare against the ramp target, not the live weight: while a track is
		-- fading in, the live weight sits below the target the whole time, and
		-- re-adjusting every frame cancels the configured fade.
		if animationSettings.Weight ~= animationTrack.WeightTarget then
			animationTrack:AdjustWeight(animationSettings.Weight)
		end

		return
	end

	local rememberedTimePosition: number? = if animationSettings.Looped == true
		then getRememberedLoopedTimePosition(characterState.rootPart, animationName)
		else nil

	local shouldResumeInterruptedLoop: boolean = animationSettings.Looped == true
		and getLoopedTrackWasPlaying(characterState.rootPart, animationName)
		and rememberedTimePosition ~= nil
		and rememberedTimePosition > 0

	local fadeTime: number = if shouldResumeInterruptedLoop then 0 else animationSettings.FadeTime

	animationTrack:Play(fadeTime)
	animationTrack:AdjustSpeed(speed)
	animationTrack:AdjustWeight(animationSettings.Weight)

	if shouldResumeInterruptedLoop and animationTrack.Length > 0 then
		animationTrack.TimePosition = rememberedTimePosition :: number % animationTrack.Length
	end

	if animationSettings.Looped == true then
		setLoopedTrackWasPlaying(characterState.rootPart, animationName, true)
	end
end

local function setPendingStopFadeOverride(rootPart: BasePart, animationName: string, stopFadeTime: number): ()
	local overridesByAnimation: { [string]: number } = PendingStopFadeOverrides[rootPart]

	if not overridesByAnimation then
		overridesByAnimation = {}
		PendingStopFadeOverrides[rootPart] = overridesByAnimation
	end

	overridesByAnimation[animationName] = stopFadeTime
end

local function consumePendingStopFadeOverride(rootPart: BasePart, animationName: string): number?
	local overridesByAnimation: { [string]: number }? = PendingStopFadeOverrides[rootPart]

	if not overridesByAnimation then
		return nil
	end

	local stopFadeTime: number? = overridesByAnimation[animationName]

	overridesByAnimation[animationName] = nil

	return stopFadeTime
end

local function stopAnimationTrack(
	characterState: ServerAuthToolkitTypes.CharacterAnimationState,
	animationName: string,
	animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings
): ()
	local animationTrack: AnimationTrack? = characterState.tracks[animationName]

	if animationSettings.Looped == true then
		clearLoopedTrackResumeState(characterState.rootPart, animationName)
	end

	if not animationTrack or not animationTrack.IsPlaying then
		return
	end

	local pendingStopFadeTime: number? = consumePendingStopFadeOverride(characterState.rootPart, animationName)
	local stopFadeTime: number = pendingStopFadeTime or animationSettings.StopFadeTime

	animationTrack:Stop(stopFadeTime)
end

local function syncCharacterAnimationState(characterState: ServerAuthToolkitTypes.CharacterAnimationState): ()
	local rootPart: BasePart = characterState.rootPart
	local isAttributeObserver: boolean = IsClient and not usesLocalAnimationAuthority(rootPart)

	for animationName: string, animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings in Animations do
		local shouldPlay: boolean? = getDesiredAnimationShouldPlay(rootPart, animationName)
		local animationTrack: AnimationTrack? = characterState.tracks[animationName]
		local isOneShot: boolean = animationSettings.Looped ~= true
		local wasDesired: boolean = getLastObservedDesired(rootPart, animationName)

		setLastObservedDesired(rootPart, animationName, shouldPlay == true)

		if shouldPlay == true then
			local forceRestart: boolean = isOneShot and consumeForceRestartRequested(rootPart, animationName)
			local restartRequested: boolean = isOneShot and consumeOneShotRestartRequested(rootPart, animationName)

			if isOneShot and not restartRequested and isAttributeObserver and not wasDesired then
				restartRequested = true
			end

			if forceRestart and animationTrack and animationTrack.IsPlaying then
				animationTrack:Stop(0)
			end

			if restartRequested or forceRestart then
				if not (animationTrack and animationTrack.IsPlaying) then
					characterState.oneShotFinished[animationName] = nil

					if animationTrack then
						animationTrack.TimePosition = 0
					end
				end
			end

			if isOneShot and characterState.oneShotFinished[animationName] == true then
				setDesiredAnimationShouldPlay(rootPart, animationName, nil)
				continue
			end

			playAnimationTrack(characterState, animationName, animationSettings)
		elseif animationTrack and animationTrack.IsPlaying then
			stopAnimationTrack(characterState, animationName, animationSettings)

			if isOneShot then
				characterState.oneShotFinished[animationName] = true
			end
		end
	end
end

local function reconcileAnimationStates(): ()
	for rootPart: BasePart, characterState: ServerAuthToolkitTypes.CharacterAnimationState in CharacterStates do
		if not rootPart.Parent then
			CharacterStates[rootPart] = nil
			LocalDesiredAnimations[rootPart] = nil
			LoopedAnimationTimePositions[rootPart] = nil
			LoopedTrackWasPlaying[rootPart] = nil
			PendingSpeedOverrides[rootPart] = nil
			PendingStopFadeOverrides[rootPart] = nil
			OneShotRestartRequests[rootPart] = nil
			ForceRestartRequests[rootPart] = nil
			LastObservedDesired[rootPart] = nil
			continue
		end

		syncCharacterAnimationState(characterState)
	end
end

local function bindAnimationReconciliation(): ()
	if ReconcileBound then
		return
	end

	ReconcileBound = true
	RunService.PostSimulation:Connect(reconcileAnimationStates)
end

local function setPlayingAnimationState(rootPart: BasePart?, animationName: string, shouldPlay: boolean?): ()
	if not rootPart then
		if shouldPlay == true then
			AlreadyPlayingAnimations[animationName] = true
		else
			AlreadyPlayingAnimations[animationName] = nil
		end

		return
	end

	local animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings? = Animations[animationName]

	if shouldPlay == true then
		consumePendingStopFadeOverride(rootPart, animationName)

		if animationSettings and animationSettings.Looped ~= true then
			setOneShotRestartRequested(rootPart, animationName)
		end
	else
		consumePendingSpeedOverride(rootPart, animationName)
		consumeOneShotRestartRequested(rootPart, animationName)
		consumeForceRestartRequested(rootPart, animationName)
	end

	setDesiredAnimationShouldPlay(rootPart, animationName, if shouldPlay == true then true else nil)
end

local function applyAlreadyPlayingAnimations(characterState: ServerAuthToolkitTypes.CharacterAnimationState): ()
	for animationName: string, _: ServerAuthToolkitTypes.ResolvedAnimationSettings in Animations do
		if isAlreadyPlaying(animationName) then
			setDesiredAnimationShouldPlay(characterState.rootPart, animationName, true)
		end
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
	local resolvedSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings = {
		Animation = animationSettings.Animation,
		Speed = animationSettings.Speed or DEFAULT_ANIMATION_SPEED,
		Weight = animationSettings.Weight or DEFAULT_ANIMATION_WEIGHT,
		FadeTime = animationSettings.FadeTime or DEFAULT_ANIMATION_FADE_TIME,
		StopFadeTime = animationSettings.StopFadeTime or DEFAULT_ANIMATION_STOP_FADE_TIME,
		InterruptStopFadeTime = animationSettings.InterruptStopFadeTime,
		Looped = animationSettings.Looped == true,
		Priority = animationSettings.Priority or DEFAULT_ANIMATION_PRIORITY,
	}

	Animations[animationName] = resolvedSettings

	for _: BasePart, characterState: ServerAuthToolkitTypes.CharacterAnimationState in CharacterStates do
		loadAnimationTrack(characterState, animationName, resolvedSettings)

		if isAlreadyPlaying(animationName) then
			setDesiredAnimationShouldPlay(characterState.rootPart, animationName, true)
		end
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

	local rootPart: BasePart? = ProcessingCharacterState and ProcessingCharacterState.rootPart or nil

	if speedOverride then
		if rootPart then
			setPendingSpeedOverride(rootPart, animationName, speedOverride)
		else
			GlobalPendingSpeedOverrides[animationName] = speedOverride
		end
	end

	setPlayingAnimationState(rootPart, animationName, true)
end

function AnimationHelper.RestartAnimation(self: AnimationHelper, animationName: string, speedOverride: number?): ()
	local animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings? = Animations[animationName]

	if not animationSettings then
		warn(`[AnimationHelper] Attempted to restart unregistered animation "{animationName}"`)
		return
	end

	if animationSettings.Looped == true then
		self:PlayAnimation(animationName, speedOverride)
		return
	end

	local rootPart: BasePart? = ProcessingCharacterState and ProcessingCharacterState.rootPart or nil

	if not rootPart then
		self:PlayAnimation(animationName, speedOverride)
		return
	end

	if speedOverride then
		setPendingSpeedOverride(rootPart, animationName, speedOverride)
	end

	setForceRestartRequested(rootPart, animationName)
	setPlayingAnimationState(rootPart, animationName, true)
end

function AnimationHelper.StopAnimation(self: AnimationHelper, animationName: string, stopFadeTimeOverride: number?): ()
	if not Animations[animationName] then
		warn(`[AnimationHelper] Attempted to stop unregistered animation "{animationName}"`)
		return
	end

	local rootPart: BasePart? = ProcessingCharacterState and ProcessingCharacterState.rootPart or nil

	if rootPart and stopFadeTimeOverride ~= nil then
		setPendingStopFadeOverride(rootPart, animationName, stopFadeTimeOverride)
	end

	setPlayingAnimationState(rootPart, animationName, nil)
end

function AnimationHelper.StopAnimationInterrupt(self: AnimationHelper, animationName: string): ()
	local animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings? = Animations[animationName]

	if not animationSettings then
		warn(`[AnimationHelper] Attempted to interrupt unregistered animation "{animationName}"`)
		return
	end

	local interruptStopFadeTime: number = if animationSettings.InterruptStopFadeTime ~= nil
		then animationSettings.InterruptStopFadeTime
		else 0

	self:StopAnimation(animationName, interruptStopFadeTime)
end

function AnimationHelper.IsAnimationPlaying(self: AnimationHelper, animationName: string): boolean
	if not Animations[animationName] then
		return false
	end

	if ProcessingCharacterState then
		return getDesiredAnimationShouldPlay(ProcessingCharacterState.rootPart, animationName) == true
	end

	return AlreadyPlayingAnimations[animationName] == true
end

function AnimationHelper.IsAnimationFinished(self: AnimationHelper, animationName: string): boolean
	local animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings? = Animations[animationName]

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

function AnimationHelper.GetLoadedTrackLength(self: AnimationHelper, rootPart: BasePart, animationName: string): number?
	local characterState: ServerAuthToolkitTypes.CharacterAnimationState? = CharacterStates[rootPart]

	if not characterState then
		return nil
	end

	local animationTrack: AnimationTrack? = characterState.tracks[animationName]

	if not animationTrack or animationTrack.Length <= 0 then
		return nil
	end

	return animationTrack.Length
end

function AnimationHelper.IsCharacterTracked(self: AnimationHelper, rootPart: BasePart): boolean
	return CharacterStates[rootPart] ~= nil
end

function AnimationHelper.Start(self: AnimationHelper): ()
	bindAnimationReconciliation()
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

	for animationName: string, animationSettings: ServerAuthToolkitTypes.ResolvedAnimationSettings in Animations do
		loadAnimationTrack(characterState, animationName, animationSettings)
	end

	applyAlreadyPlayingAnimations(characterState)

	humanoid.Destroying:Connect(function()
		CharacterStates[rootPart] = nil
		LocalDesiredAnimations[rootPart] = nil
		LoopedAnimationTimePositions[rootPart] = nil
		LoopedTrackWasPlaying[rootPart] = nil
		PendingSpeedOverrides[rootPart] = nil
		PendingStopFadeOverrides[rootPart] = nil
		OneShotRestartRequests[rootPart] = nil
		ForceRestartRequests[rootPart] = nil
		LastObservedDesired[rootPart] = nil
	end)
end

return self
