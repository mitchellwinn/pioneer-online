extends Node
class_name LoadoutComponent

## LoadoutComponent - Equipment/weapon system for players and humanoid NPCs
## Attached to ActionEntity, handles weapons, armor, and consumables
## Non-humanoid entities ignore this component

#region Signals
signal loadout_changed()
signal weapon_equipped(slot: String, weapon_id: String)
signal weapon_unequipped(slot: String)
signal armor_changed(slot: String, armor_id: String)
signal item_used(item_id: String)
signal loadout_dropped(items: Array)
#endregion

#region Configuration
@export var is_enabled: bool = true  # Set false for non-humanoid NPCs
@export var default_loadout_id: String = ""  # Database reference for NPCs
#endregion

#region Loadout Structure
# Weapon slots
var primary_weapon: Dictionary = {}    # {id, data, ammo, etc.}
var secondary_weapon: Dictionary = {}
var sidearm: Dictionary = {}

# Armor slots
var head_armor: Dictionary = {}
var body_armor: Dictionary = {}
var legs_armor: Dictionary = {}

# Equipment slots (grenades, consumables, tools)
var equipment_slots: Array[Dictionary] = [{}, {}, {}, {}]  # 4 slots

# Backpack/inventory (what gets dropped on death)
var inventory: Array[Dictionary] = []
var max_inventory_slots: int = 20

# Currency carried (also at risk)
var carried_currency: int = 0
#endregion

#region Runtime
var owner_entity: Node = null
var current_weapon_slot: String = "primary"  # Which weapon is active
#endregion

func _ready():
	owner_entity = get_parent()
	
	if not is_enabled:
		return
	
	# Load default loadout for NPCs
	if default_loadout_id and not default_loadout_id.is_empty():
		_load_default_loadout()

#region Loadout Management
func _load_default_loadout():
	# Load from database or data file
	if has_node("/root/DatabaseManager"):
		var loadout_data = _get_loadout_from_database(default_loadout_id)
		if not loadout_data.is_empty():
			apply_loadout(loadout_data)

func _get_loadout_from_database(loadout_id: String) -> Dictionary:
	# This would query the loadouts table
	# For now, return empty - implement based on your database schema
	return {}

func apply_loadout(loadout_data: Dictionary):
	if loadout_data.has("primary_weapon"):
		equip_weapon("primary", loadout_data.primary_weapon)
	if loadout_data.has("secondary_weapon"):
		equip_weapon("secondary", loadout_data.secondary_weapon)
	if loadout_data.has("sidearm"):
		equip_weapon("sidearm", loadout_data.sidearm)
	
	if loadout_data.has("head_armor"):
		equip_armor("head", loadout_data.head_armor)
	if loadout_data.has("body_armor"):
		equip_armor("body", loadout_data.body_armor)
	if loadout_data.has("legs_armor"):
		equip_armor("legs", loadout_data.legs_armor)
	
	if loadout_data.has("equipment"):
		for i in range(min(loadout_data.equipment.size(), equipment_slots.size())):
			equipment_slots[i] = loadout_data.equipment[i]
	
	if loadout_data.has("inventory"):
		inventory = loadout_data.inventory.duplicate()
	
	if loadout_data.has("currency"):
		carried_currency = loadout_data.currency
	
	loadout_changed.emit()

func get_loadout_data() -> Dictionary:
	return {
		"primary_weapon": primary_weapon,
		"secondary_weapon": secondary_weapon,
		"sidearm": sidearm,
		"head_armor": head_armor,
		"body_armor": body_armor,
		"legs_armor": legs_armor,
		"equipment": equipment_slots,
		"inventory": inventory,
		"currency": carried_currency
	}
#endregion

#region Weapons
func equip_weapon(slot: String, weapon_data: Dictionary):
	match slot:
		"primary":
			primary_weapon = weapon_data
		"secondary":
			secondary_weapon = weapon_data
		"sidearm":
			sidearm = weapon_data
	
	weapon_equipped.emit(slot, weapon_data.get("id", ""))
	loadout_changed.emit()

func unequip_weapon(slot: String) -> Dictionary:
	var removed = {}
	
	match slot:
		"primary":
			removed = primary_weapon
			primary_weapon = {}
		"secondary":
			removed = secondary_weapon
			secondary_weapon = {}
		"sidearm":
			removed = sidearm
			sidearm = {}
	
	weapon_unequipped.emit(slot)
	loadout_changed.emit()
	return removed

func get_current_weapon() -> Dictionary:
	match current_weapon_slot:
		"primary":
			return primary_weapon
		"secondary":
			return secondary_weapon
		"sidearm":
			return sidearm
	return {}

func switch_weapon(slot: String):
	if slot in ["primary", "secondary", "sidearm"]:
		current_weapon_slot = slot

func has_weapon(slot: String) -> bool:
	match slot:
		"primary":
			return not primary_weapon.is_empty()
		"secondary":
			return not secondary_weapon.is_empty()
		"sidearm":
			return not sidearm.is_empty()
	return false
#endregion

#region Armor
func equip_armor(slot: String, armor_data: Dictionary):
	match slot:
		"head":
			head_armor = armor_data
		"body":
			body_armor = armor_data
		"legs":
			legs_armor = armor_data
	
	armor_changed.emit(slot, armor_data.get("id", ""))
	loadout_changed.emit()

func get_total_armor() -> float:
	var total = 0.0
	total += head_armor.get("armor_value", 0.0)
	total += body_armor.get("armor_value", 0.0)
	total += legs_armor.get("armor_value", 0.0)
	return total

func apply_armor_reduction(damage: float) -> float:
	# Simple percentage reduction based on armor
	var armor = get_total_armor()
	var reduction = armor / (armor + 100.0)  # Diminishing returns formula
	return damage * (1.0 - reduction)
#endregion

#region Equipment/Consumables
func use_equipment(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= equipment_slots.size():
		return false
	
	var item = equipment_slots[slot_index]
	if item.is_empty():
		return false
	
	# Execute item effect
	_execute_item_effect(item)
	
	# Consume if consumable
	if item.get("consumable", true):
		var count = item.get("count", 1) - 1
		if count <= 0:
			equipment_slots[slot_index] = {}
		else:
			equipment_slots[slot_index].count = count
	
	item_used.emit(item.get("id", ""))
	loadout_changed.emit()
	return true

func _execute_item_effect(item: Dictionary):
	var effect_type = item.get("effect_type", "")
	var effect_value = item.get("effect_value", 0)
	
	match effect_type:
		"heal":
			if owner_entity and owner_entity.has_method("heal"):
				owner_entity.heal(effect_value)
		"grenade":
			# Spawn grenade projectile
			pass
		"buff":
			# Apply temporary buff
			pass
#endregion

#region Inventory
func add_to_inventory(item: Dictionary) -> bool:
	if inventory.size() >= max_inventory_slots:
		return false
	
	# Stack if stackable
	if item.get("stackable", false):
		for inv_item in inventory:
			if inv_item.get("id") == item.get("id"):
				inv_item.count = inv_item.get("count", 1) + item.get("count", 1)
				loadout_changed.emit()
				return true
	
	inventory.append(item)
	loadout_changed.emit()
	return true

func remove_from_inventory(index: int) -> Dictionary:
	if index < 0 or index >= inventory.size():
		return {}
	
	var item = inventory[index]
	inventory.remove_at(index)
	loadout_changed.emit()
	return item
#endregion

#region Death/Extraction - Core Risk System
func on_death() -> Array:
	## Called when entity dies - returns all items to drop
	## This is the "lose your loadout" mechanic
	
	if not is_enabled:
		return []
	
	var dropped_items: Array = []
	
	# Drop all weapons
	if not primary_weapon.is_empty():
		dropped_items.append({"type": "weapon", "slot": "primary", "data": primary_weapon})
		primary_weapon = {}
	if not secondary_weapon.is_empty():
		dropped_items.append({"type": "weapon", "slot": "secondary", "data": secondary_weapon})
		secondary_weapon = {}
	if not sidearm.is_empty():
		dropped_items.append({"type": "weapon", "slot": "sidearm", "data": sidearm})
		sidearm = {}
	
	# Drop armor
	if not head_armor.is_empty():
		dropped_items.append({"type": "armor", "slot": "head", "data": head_armor})
		head_armor = {}
	if not body_armor.is_empty():
		dropped_items.append({"type": "armor", "slot": "body", "data": body_armor})
		body_armor = {}
	if not legs_armor.is_empty():
		dropped_items.append({"type": "armor", "slot": "legs", "data": legs_armor})
		legs_armor = {}
	
	# Drop equipment
	for i in range(equipment_slots.size()):
		if not equipment_slots[i].is_empty():
			dropped_items.append({"type": "equipment", "slot": i, "data": equipment_slots[i]})
			equipment_slots[i] = {}
	
	# Drop inventory
	for item in inventory:
		dropped_items.append({"type": "inventory", "data": item})
	inventory.clear()
	
	# Drop currency
	if carried_currency > 0:
		dropped_items.append({"type": "currency", "amount": carried_currency})
		carried_currency = 0
	
	loadout_dropped.emit(dropped_items)
	loadout_changed.emit()
	
	return dropped_items

func on_extraction() -> Dictionary:
	## Called on successful extraction - items are saved to stash
	## Returns the loadout data to save
	
	return get_loadout_data()
#endregion

