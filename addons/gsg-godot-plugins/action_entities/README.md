# Action Entities Plugin

Server-authoritative 3D entity system for modern action games. Features skeletal mesh support, state machine-based gameplay, networked combat, and AI behaviors.

## Features

- **ActionEntity** - Base CharacterBody3D with 3D mesh + AnimationTree support
- **ActionPlayer** - Player input handling, camera-relative movement, aiming
- **ActionNPC** - AI behaviors with navigation, detection, and combat
- **State Machine** - Flexible state system for movement, combat, and abilities
- **Combat Component** - Health, shields, damage, abilities with cooldowns
- **Network Identity** - Multiplayer sync with interpolation and authority

## Installation

1. Copy `action_entities` to your project's `addons/` folder
2. Enable **Action Entities** in **Project → Project Settings → Plugins**

## Quick Start

### Creating a Player

```gdscript
# Player scene structure:
# ActionPlayer (CharacterBody3D)
#   ├── MeshRoot (Node3D)
#   │   └── YourCharacterModel
#   ├── CollisionShape3D
#   ├── StateManager (EntityStateManager)
#   │   ├── Idle (StateIdle)
#   │   ├── Moving (StateMoving)
#   │   ├── Jumping (StateJumping)
#   │   ├── Dodging (StateDodging)
#   │   └── Dead (StateDead)
#   ├── Combat (CombatComponent)
#   └── NetworkIdentity
```

### Creating an NPC

```gdscript
var npc = ActionNPC.new()
npc.behavior_type = "aggressive"
npc.detection_range = 15.0
npc.attack_range = 2.0
add_child(npc)
```

## State Machine

States control entity behavior. Each state defines:
- `on_enter()` / `on_exit()` - Transition callbacks
- `on_physics_process()` - Per-frame logic
- `allows_movement` / `allows_rotation` - Input permissions
- `can_be_interrupted` / `priority` - Transition rules

### Built-in States

| State | Description |
|-------|-------------|
| `StateIdle` | Standing still, awaiting input |
| `StateMoving` | Walking/running movement |
| `StateJumping` | Airborne with air control |
| `StateDodging` | Dodge roll with i-frames |
| `StateAttackBase` | Base for combat attacks |
| `StateStunned` | Staggered/incapacitated |
| `StateDead` | Death state |

### Custom States

```gdscript
extends EntityState
class_name StateMyAbility

func on_enter(previous_state: EntityState = null):
    entity.play_animation("my_ability")

func on_physics_process(delta: float):
    # Ability logic here
    if ability_complete:
        complete()  # Return to default state
```

### Ability Combos

Chain states together for complex abilities:

```gdscript
# Simple combo
state_manager.start_combo(["attack_1", "attack_2", "attack_3"])

# Or queue states manually
state_manager.queue_state("attack_2")
state_manager.queue_state("finisher")
state_manager.change_state("attack_1")
```

## Combat Component

```gdscript
# Taking damage (server-validated in multiplayer)
entity.take_damage(25.0, attacker, "fire")

# Healing
entity.heal(50.0)

# Abilities with cooldowns
combat.register_ability("fireball", {
    "cooldown": 5.0,
    "damage": 30.0,
    "range": 20.0
})

if combat.can_use_ability("fireball"):
    combat.use_ability("fireball")
```

## Input Actions

The plugin registers these input actions (override in Project Settings):

| Action | Default Binding |
|--------|-----------------|
| `move_forward/backward/left/right` | WASD / Left Stick |
| `camera_rotate_*` | Right Stick |
| `sprint` | Shift / L3 |
| `jump` | Space / A |
| `dodge` | Ctrl / B |
| `attack_primary` | LMB / RB |
| `attack_secondary` | RMB / LB |
| `ability_1-4` | 1-4 / D-Pad |

## Network Integration

Entities are server-authoritative by default:

```gdscript
# NetworkIdentity handles sync automatically
# Position, rotation, velocity interpolated on clients
# Damage validated on server before applying
```

## AI Behaviors

| Behavior | Description |
|----------|-------------|
| `idle` | Stand in place |
| `patrol` | Move between patrol points |
| `guard` | Return to position, attack intruders |
| `aggressive` | Hunt and attack targets |

```gdscript
npc.behavior_type = "patrol"
npc.patrol_points = [$Point1, $Point2, $Point3]
npc.detection_range = 20.0
```

## License

Provided as-is for use in any project.

