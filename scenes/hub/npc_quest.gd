extends ActionNPC
class_name NPCQuest

## NPCQuest - Lean extension for quest-giving NPCs

signal quest_accepted(quest_id: String)
signal quest_completed(quest_id: String)
signal quest_abandoned(quest_id: String)

#region Configuration
@export_group("NPC Type")
@export var npc_type: String = "quest"

@export_group("Quests")
@export var offered_quests: Array[String] = []
#endregion

func _ready():
	super._ready()

func get_npc_type() -> String:
	return npc_type
	
	if interaction_prompt == "Press E to talk":
		interaction_prompt = "Press E to talk"

#region Override ActionNPC
func on_dialogue_event(event_type: String, params: Dictionary):
	match event_type:
		"accept_quest":
			_accept_quest(params.get("quest_id", ""))
		"complete_quest":
			_complete_quest(params.get("quest_id", ""))
		"abandon_quest":
			_abandon_quest(params.get("quest_id", ""))
#endregion

#region Quest Operations
func _accept_quest(quest_id: String):
	if quest_id in offered_quests:
		quest_accepted.emit(quest_id)
		# TODO: Add to player's active quests

func _complete_quest(quest_id: String):
	quest_completed.emit(quest_id)
	# TODO: Give rewards, update flags

func _abandon_quest(quest_id: String):
	quest_abandoned.emit(quest_id)
	# TODO: Remove from active quests
#endregion
