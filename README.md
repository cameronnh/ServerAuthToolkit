<div align="center" style="margin-bottom: 2rem;">
	<h1>ServerAuthToolkit</h1>
	<p>Server-authoritative movement toolkit for Roblox Input Actions and client prediction.</p>
	<a href="https://cameronnh.github.io/ServerAuthToolkit/"><strong>View docs</strong></a>
</div>
<!--moonwave-hide-before-this-line-->


Register movement modules that define input, default state, and simulation logic. The toolkit handles player lifecycle, runs modules each simulation step, and replicates movement state through root-part attributes.

## Installation

Add the package with [Wally](https://wally.run/):

```toml
ServerAuthToolkit = "cameronnh/serverauthtoolkit@0.1.2"
```

## Quick start

Require the toolkit on both the server and client, register your modules, then start it:

```lua
local ServerAuthToolkit = require(ReplicatedStorage.ServerAuthToolkit)

ServerAuthToolkit:RegisterDefinition({
	Name = "Jump",
	Priority = 1,
	Actions = {
		{
			Name = "Jump",
			Type = Enum.InputActionType.Bool,
			Bindings = {
				Keyboard = {
					KeyCode = Enum.KeyCode.Space,
				},
				Gamepad = {
					KeyCode = Enum.KeyCode.ButtonA,
				},
			},
			ApplyInput = function(state: ServerAuthToolkit.MovementState, inputState: boolean)
				state.IsJumping = inputState
			end,
		},
	},
	NeededStates = {
		IsJumping = false,
		OnGround = false,
	},
	Disable = {
		"JumpAction",
	},
	Process = function(state, deltaTime)
		-- Jump logic
	end,
})

ServerAuthToolkit:Start()
```

Call `Start` once per process after registering modules and animations.

## Features

- Movement modules with priority-ordered simulation
- Input Actions integration and movement state replication
- Client camera hooks for pre-simulation and post-camera effects
- Built-in animation helpers and flat look-direction utilities
