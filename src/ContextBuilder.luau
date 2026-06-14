----------------------------------------------------------------------------------------
-- [[ ROBLOX SERVICES ]] --
----------------------------------------------------------------------------------------

local HttpService = game:GetService("HttpService")

----------------------------------------------------------------------------------------
-- [[ DEPENDENCIES ]] --
----------------------------------------------------------------------------------------

local ServerAuthToolkitTypes = require(script.Parent.ServerAuthToolkitTypes)

----------------------------------------------------------------------------------------
-- [[ MODULE & EXPORT ]] --
----------------------------------------------------------------------------------------

local ContextBuilder = {}
ContextBuilder.__index = ContextBuilder

export type ContextBuilder = {
	new: (name: string, parent: Instance, priority: number?, sink: boolean?) -> ContextBuilder,
	Destroy: (self: ContextBuilder) -> (),

	AddAction: (
		self: ContextBuilder,
		actionName: string,
		type: Enum.InputActionType,
		priority: number?
	) -> ServerAuthToolkitTypes.Action,
	HasAction: (self: ContextBuilder, actionName: string) -> boolean,
	SetActionEnabled: (self: ContextBuilder, actionName: string, enabled: boolean) -> (),
	AddBinding: (
		self: ContextBuilder,
		actionName: string,
		bindingName: string,
		props: ServerAuthToolkitTypes.BindingProps
	) -> (),
	AddActionCallback: (self: ContextBuilder, actionName: string, callback: (state: any) -> (), id: string?) -> (),
	RemoveActionCallback: (self: ContextBuilder, actionName: string, id: string) -> (),

	_actions: { [string]: ServerAuthToolkitTypes.Action },
	_connections: { RBXScriptConnection },
	_inputContext: InputContext,
}

----------------------------------------------------------------------------------------
-- [[ CONSTANTS ]] --
----------------------------------------------------------------------------------------

const DEFAULT_PRIORITY: number = 1000

----------------------------------------------------------------------------------------
-- [[ LOCAL METHODS ]] --
----------------------------------------------------------------------------------------

local function vWarn(message: string): ()
	warn(`[ContextBuilder] {message}`)
end

local function disconnectAll(connections: { RBXScriptConnection }): ()
	for connectionIndex: number, connection: RBXScriptConnection in connections do
		connection:Disconnect()
		connections[connectionIndex] = nil :: any
	end
end

----------------------------------------------------------------------------------------
-- [[ CONSTRUCTOR ]] --
----------------------------------------------------------------------------------------

function ContextBuilder.new(name: string, parent: Instance, priority: number?, sink: boolean?): ContextBuilder
	local self = setmetatable({
		_actions = {},
		_connections = {},
		_inputContext = Instance.new("InputContext"),
	}, ContextBuilder) :: ContextBuilder

	self._inputContext.Name = name
	self._inputContext.Priority = priority or DEFAULT_PRIORITY
	self._inputContext.Parent = parent
	self._inputContext.Sink = sink or false

	return self
end

----------------------------------------------------------------------------------------
-- [[ PUBLIC METHODS ]] --
----------------------------------------------------------------------------------------

function ContextBuilder.AddAction(
	self: ContextBuilder,
	actionName: string,
	type: Enum.InputActionType,
	priority: number?
): ServerAuthToolkitTypes.Action
	local action: ServerAuthToolkitTypes.Action = {
		Type = type,
		Enabled = true,
		Instance = Instance.new("InputAction"),
		Bindings = {},
		Callbacks = {},
	}

	action.Instance.Name = actionName
	action.Instance.Type = type
	action.Instance.Parent = self._inputContext

	table.insert(
		self._connections,
		action.Instance.StateChanged:Connect(function(state: any)
			for _: string, callback: (state: any) -> () in action.Callbacks do
				callback(state)
			end
		end)
	)

	self._actions[actionName] = action

	return action
end

function ContextBuilder.HasAction(self: ContextBuilder, actionName: string): boolean
	return self._actions[actionName] ~= nil
end

function ContextBuilder.SetActionEnabled(self: ContextBuilder, actionName: string, enabled: boolean): ()
	if not self._actions[actionName] then
		vWarn(`Action "{actionName}" not found on :SetActionEnabled`)
		return
	end

	self._actions[actionName].Enabled = enabled
	self._actions[actionName].Instance.Enabled = enabled
end

function ContextBuilder.AddActionCallback(
	self: ContextBuilder,
	actionName: string,
	callback: (state: any) -> (),
	id: string?
): ()
	if not self._actions[actionName] then
		vWarn(`Action "{actionName}" not found on :AddActionCallback`)
		return
	end

	id = id or HttpService:GenerateGUID(false)

	self._actions[actionName].Callbacks[id] = callback
end

function ContextBuilder.RemoveActionCallback(self: ContextBuilder, actionName: string, id: string): ()
	if not self._actions[actionName] then
		vWarn(`Action "{actionName}" not found on :RemoveActionCallback`)
		return
	end

	if not self._actions[actionName].Callbacks[id] then
		vWarn(`Callback with id {id} not found on :RemoveActionCallback`)
		return
	end

	self._actions[actionName].Callbacks[id] = nil
end

function ContextBuilder.AddBinding(
	self: ContextBuilder,
	actionName: string,
	bindingName: string,
	props: ServerAuthToolkitTypes.BindingProps
): ()
	if not self._actions[actionName] then
		vWarn(`Action "{actionName}" not found on :AddBinding`)
		return
	end

	local binding: InputBinding = Instance.new("InputBinding")
	binding.Name = bindingName

	for key: string, value: any in props :: any do
		(binding :: any)[key] = value
	end

	self._actions[actionName].Bindings[bindingName] = binding
	binding.Parent = self._actions[actionName].Instance
end

function ContextBuilder.Destroy(self: ContextBuilder): ()
	disconnectAll(self._connections)

	for _: string, action: ServerAuthToolkitTypes.Action in self._actions do
		action.Instance:Destroy()
	end

	table.clear(self._actions)
	self._inputContext:Destroy()
	setmetatable(self, nil)
end

return ContextBuilder :: ContextBuilder
