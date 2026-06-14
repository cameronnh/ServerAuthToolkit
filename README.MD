# ServerAuthToolkit

Server-authoritative movement toolkit for Roblox experiences using [Input Actions](https://create.roblox.com/docs/input/input-actions) and client-side prediction.

Register movement modules that define input, default state, and simulation logic. The toolkit handles player lifecycle, runs modules each simulation step, and replicates movement state through root-part attributes.

## Installation

Add the package with [Wally](https://wally.run/):

```toml
ServerAuthToolkit = "cameronnh/serverauthtoolkit@0.1.1"
```

## Quick start

Require the toolkit on both the server and client, register your modules, then start it:

```lua
local ServerAuthToolkit = require(ReplicatedStorage.ServerAuthToolkit)

ServerAuthToolkit:RegisterDefinition({
	Name = "Movement",
	Priority = 1,
	Actions = { /* ... */ },
	NeededStates = { Speed = 16 },
	Process = function(state, deltaTime)
		-- movement logic
	end,
})

ServerAuthToolkit:Start()
```

Call `Start` once per process after registering modules and animations.

## Documentation

Browse the full API reference for types, methods, and usage details:

**[API Reference →](/api/ServerAuthToolkit)**

## Features

- Movement modules with priority-ordered simulation
- Input Actions integration and movement state replication
- Client camera hooks for pre-simulation and post-camera effects
- Built-in animation helpers and flat look-direction utilities
