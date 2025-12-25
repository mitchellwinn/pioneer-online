#Michael is just accepting that XML is easier to human-read
#He ain't do any of the agential coding that was Mitch
#If a comment has punctuation that shit was not me
extends Node

signal dialogue_started
signal dialogue_finished

var next: String

var text_speed: float = 0.05
var speed_mult: float = 1.0

var is_open: bool = false
var dialogues: Dictionary # every dialogue tree loaded from XML
var current_tree: Dictionary # the current dialogue tree in action.
var current_tree_name: String = "" # name of the current dialogue tree
var current_line_id: String = "" # current line ID being displayed  
var current_npc: Node = null # Reference to the NPC currently in dialogue
var current_speaker: String = "" # Current speaker name for prepending to dialogue
var choice: String

var confirm_pressed: bool = false  # Flag for unhandled input
var bbcode_regex: RegEx

# Helper function to get the correct dialogue label based on context
func _get_dialogue_label() -> RichTextLabel:
	# Check if we're in battle - use battle's dialogue label
	if BattleManager and BattleManager.in_battle and BattleManager.dialogue_label:
		return BattleManager.dialogue_label
	
	# Check if we're in overworld - use dialogue window from MenuManager
	var dialogue_window = MenuManager.get_menu_window("dialogue")
	if dialogue_window:
		if dialogue_window.has_method("get_message_label"):
			var message_label = dialogue_window.get_message_label()
			if message_label:
				return message_label
			else:
				print("[DIALOGUE] WARNING: dialogue window exists but message_label is null")
	
	# Fallback to GameManager (for backwards compatibility)
	if GameManager.dialogue_label and is_instance_valid(GameManager.dialogue_label):
		return GameManager.dialogue_label
	
	print("[DIALOGUE] WARNING: No valid dialogue label found!")
	return null

func convert_xml(filepath: String) -> Dictionary:
	var parser = XMLParser.new()
	
	var starters: Dictionary
	var lines: Dictionary
	
	var current_starter: String
	var current_line: String
	var current_condition: String
	var is_reading_starter: bool
	var is_reading: bool
	
	# print("XML conversion has begun for: " + filepath)
	parser.open(filepath)
	while parser.read() != ERR_FILE_EOF:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			#Read each line of dialogue and associated data
			if parser.get_node_name() == "starter":
				is_reading_starter = true
				current_starter = parser.get_named_attribute_value_safe("id")
				starters[current_starter] = {"all_true": parser.get_named_attribute_value_safe("all_true")}
				starters[current_starter]["conditions"] = {}
			if parser.get_node_name() == "line":
				current_line = parser.get_named_attribute_value_safe("id")
				lines[current_line] = {"next": parser.get_named_attribute_value_safe("next")}
				is_reading = true
				lines[current_line]["choices"] = [] # Changed to array for indexed choices
				lines[current_line]["cond_next"] = {}
			else:
				is_reading = false
			if parser.get_node_name() == "choice":
				var choice_data = {
					"text": parser.get_named_attribute_value_safe("text"),
					"next": parser.get_named_attribute_value_safe("next")
				}
				lines[current_line]["choices"].append(choice_data)
			if parser.get_node_name() == "conditional_next":
				current_condition = parser.get_named_attribute_value_safe("id")
				lines[current_line]["cond_next"][current_condition] = {"all_true": parser.get_named_attribute_value_safe("all_true")}
				lines[current_line]["cond_next"][current_condition]["conditions"] = {}
			if parser.get_node_name() == "condition":
				if is_reading_starter:
					starters[current_starter]["conditions"][parser.get_named_attribute_value_safe("key")] = {"value": parser.get_named_attribute_value_safe("value"), "operator": parser.get_named_attribute_value_safe("operator")} # attach a condition to a starter
				elif current_condition != "":
					lines[current_line]["cond_next"][current_condition]["conditions"][parser.get_named_attribute_value_safe("key")] = {"value": parser.get_named_attribute_value_safe("value"), "operator": parser.get_named_attribute_value_safe("operator")} # attach a condition to a condtional next
		if parser.get_node_type() == XMLParser.NODE_TEXT and is_reading:
			lines[current_line]["text"] = parser.get_node_data().strip_edges()
			is_reading = false
		if parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "starter":
				is_reading_starter = false
	return {"starters": starters, "lines": lines}

func override_xml(dict_name: String, filepath: String):
	var parser = XMLParser.new()
	
	var current_line: String = ""
	var choice: String
	var old_text: String
	
	# print("XML overwrite has begun for: " + filepath)
	# print("Dict name: " + dict_name + ", Has dict: " + str(dialogues.has(dict_name)))
	parser.open(filepath)
	while parser.read() != ERR_FILE_EOF:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			if parser.get_node_name() == "line":
				current_line = parser.get_named_attribute_value_safe("id")
			elif parser.get_node_name() == "choice":
				var choice_index = int(parser.get_named_attribute_value_safe("index"))
				var override_text = parser.get_named_attribute_value_safe("text")
				
				# Override the choice text at the specified index
				if choice_index >= 0 and choice_index < dialogues[dict_name]["lines"][current_line]["choices"].size():
					dialogues[dict_name]["lines"][current_line]["choices"][choice_index]["text"] = override_text
					# print("Override: Replaced choice at index " + str(choice_index) + " with text: " + override_text)
		if parser.get_node_type() == XMLParser.NODE_TEXT:
			# print("Override: Found NODE_TEXT, current_line = " + str(current_line))
			if current_line != "" and dialogues.has(dict_name) and dialogues[dict_name].has("lines") and dialogues[dict_name]["lines"].has(current_line):
				if dialogues[dict_name]["lines"][current_line].has("text"):
					old_text = dialogues[dict_name]["lines"][current_line]["text"]
					# print("Override: current_line = " + current_line + ", old_text = " + old_text)
					var new_text_raw = parser.get_node_data().strip_edges()
					# print("Override: new_text_raw = " + new_text_raw)
					
					# Parse English: track event positions and extract text
					var english_parts = old_text.split("`")
					var english_events_with_pos: Array = []  # [{event: "...", pos: "before"|"mid"|"after"}]
					var english_text = ""
					var found_text = false
					
					for i in range(english_parts.size()):
						if i % 2 == 0:
							# Text segment - strip whitespace
							var text_part = english_parts[i].strip_edges()
							if text_part != "":
								english_text += text_part
								found_text = true
						else:
							# Event segment
							var pos = "after"  # Default
							if not found_text:
								pos = "before"
							elif i < english_parts.size() - 1:  # Not the last segment
								# Check if there's more text after this event
								var has_text_after = false
								for j in range(i + 1, english_parts.size(), 2):
									if english_parts[j].strip_edges() != "":
										has_text_after = true
										break
								if has_text_after:
									pos = "mid"
							english_events_with_pos.append({"event": english_parts[i], "pos": pos})
					
					# Parse translation: extract events and text
					var translation_parts = new_text_raw.split("`")
					var translation_events: Array = []
					var translation_text = ""
					
					for i in range(translation_parts.size()):
						if i % 2 == 0:
							# Text segment - strip whitespace
							var text_part = translation_parts[i].strip_edges()
							if text_part != "":
								translation_text += text_part
						else:
							# Event segment
							translation_events.append(translation_parts[i])
					
					# print("Override: english_events_with_pos = " + str(english_events_with_pos))
					# print("Override: translation_events = " + str(translation_events))
					# print("Override: translation_text = " + translation_text)
					
					# Find missing events from English
					var missing_before: Array = []
					var missing_mid: Array = []
					var missing_after: Array = []
					
					for item in english_events_with_pos:
						if not translation_events.has(item["event"]):
							# Event is missing from translation
							if item["pos"] == "before":
								missing_before.append(item["event"])
							elif item["pos"] == "mid":
								missing_mid.append(item["event"])
							else:  # "after"
								missing_after.append(item["event"])
					
					# print("Override: missing_before = " + str(missing_before))
					# print("Override: missing_mid = " + str(missing_mid))
					# print("Override: missing_after = " + str(missing_after))
					
					# Reconstruct: if translation already has the text with its events, use it as-is
					# Otherwise build from scratch
					var final_text = ""
					
					if translation_text.strip_edges() == "" and translation_events.size() == 0:
						# Translation is completely empty, use English structure
						final_text = old_text
					else:
						# Use translation text/events and append missing events
						# Add missing "before" events
						for event in missing_before:
							final_text += "`" + event + "`"
						
						# Rebuild translation content WITHOUT whitespace between events
						for i in range(translation_parts.size()):
							if i % 2 == 0:
								# Text segment
								var text_part = translation_parts[i].strip_edges()
								if text_part != "":
									final_text += text_part
							else:
								# Event segment
								final_text += "`" + translation_parts[i] + "`"
						
						# Add missing "mid" events before "after" events
						for event in missing_mid:
							final_text += "`" + event + "`"
						
						# Add missing "after" events
						for event in missing_after:
							final_text += "`" + event + "`"
					
					# print("Override: final_text = " + final_text)
					dialogues[dict_name]["lines"][current_line]["text"] = final_text
				else:
					print("Override: WARNING - line " + current_line + " has no text key!")
			else:
				print("Override: WARNING - validation failed for current_line " + str(current_line))

func initiate_dialogue(name: String):
	# Always start a fresh dialogue, even if something left is_open = true.
	# Events are responsible for sequencing; we only ever run one tree at a time.
	is_open = true
	current_tree_name = name
	
	
	# Don't open dialogue window yet - wait until we have text to display
	# This prevents blank windows from appearing for event-only dialogue lines
	
	# Emit dialogue started signal
	emit_signal("dialogue_started")
	
	# Clear speaker at the start of dialogue
	var dialogue_window = MenuManager.get_menu_window("dialogue")
	if dialogue_window and dialogue_window.has_method("clear_speaker"):
		dialogue_window.clear_speaker()
	if GameManager.main_dialogue_box and GameManager.main_dialogue_box.has_method("clear_speaker"):
		GameManager.main_dialogue_box.clear_speaker()
	
	if dialogues.has(name):
		current_tree = dialogues[name]
		read_line(iterate_conditionals(current_tree["starters"]))
	else:
		print("Null dialogue: ", name)
		is_open = false
		current_tree_name = ""
		# Close dialogue window if we opened it
		if dialogue_window:
			dialogue_window.close_window()

func iterate_conditionals(starters: Dictionary, default: String = "") -> String:
	var all_true: bool
	var passed: bool
	var truth: bool
	
	for starter in starters:
		all_true = starters[starter]["all_true"] == "true"
		if all_true:
			passed = true # true until one is false
		else:
			passed = false # false until any are true
		if starters[starter]["conditions"].is_empty():
			# print(str(starter) + " has no conditions. Passing anyways.")
			return starter # for "default" choices
		else:
			for condition in starters[starter]["conditions"]:
				# Check for special condition types
				var condition_value
				if condition == "party_size":
					condition_value = GameManager.party.size()
				elif DataManager.conditional_flags.has(condition):
					condition_value = DataManager.conditional_flags[condition]
				else:
					truth = false
					continue
				
				if condition_value != null:
					match starters[starter]["conditions"][condition]["operator"]:
						"":
							truth = str(condition_value) == starters[starter]["conditions"][condition]["value"]
						">":
							truth = float(condition_value) > float(starters[starter]["conditions"][condition]["value"])
						"<":
							truth = float(condition_value) < float(starters[starter]["conditions"][condition]["value"])
						">=":
							truth = float(condition_value) >= float(starters[starter]["conditions"][condition]["value"])
						"<=":
							truth = float(condition_value) <= float(starters[starter]["conditions"][condition]["value"])
				else:
					truth = false
				if truth and !all_true:
					passed = true
				elif !truth and all_true:
					passed = false
		# print("Dialogue conditionals iterated for " + str(starter))
		if passed:
			# print("Conditionals passed.")
			return starter
	return default

func read_line(ID: String, label: RichTextLabel = null):
	current_line_id = ID
	if ID == "":
		# print("[DIALOGUE] Ending dialogue - setting is_open to false")
		is_open = false
		current_tree_name = ""
		current_line_id = ""
		current_npc = null # Clear NPC reference
		current_speaker = "" # Clear speaker
		
		# Clear speaker when dialogue ends
		var dialogue_window = MenuManager.get_menu_window("dialogue")
		if dialogue_window and dialogue_window.has_method("clear_speaker"):
			dialogue_window.clear_speaker()
		if GameManager.main_dialogue_box and GameManager.main_dialogue_box.has_method("clear_speaker"):
			GameManager.main_dialogue_box.clear_speaker()
		
		# Close dialogue window if not in battle
		if not (BattleManager and BattleManager.in_battle):
			if dialogue_window:
				# print("[DIALOGUE] Closing dialogue window")
				dialogue_window.close_window()
				# print("[DIALOGUE] Window is_open after close: ", dialogue_window.is_open if "is_open" in dialogue_window else "N/A")
		
		# Check if any other windows are still open
		var active_window = MenuManager.get_active_window()
		# print("[DIALOGUE] Active window after dialogue end: ", active_window.menu_name if active_window and "menu_name" in active_window else "none")
		
		
		# print("[DIALOGUE] Got empty dialogue ID. Emitting dialogue_finished signal")
		# Emit dialogue finished signal
		emit_signal("dialogue_finished")
		# print("[DIALOGUE] DialogueManager.is_open is now: ", is_open)
		return
	# print("Reading from dialogue ID " + str(ID))
	
	# Safety check: verify line exists and has required keys
	if not current_tree.has("lines") or not current_tree["lines"].has(ID):
		push_error("[DIALOGUE] Line ID '" + ID + "' not found in dialogue tree '" + current_tree_name + "'")
		is_open = false
		current_tree_name = ""
		current_line_id = ""
		return
	
	var line_data = current_tree["lines"][ID]
	if not line_data.has("text"):
		push_error("[DIALOGUE] Line ID '" + ID + "' in tree '" + current_tree_name + "' is missing 'text' key. Line data: " + str(line_data))
		is_open = false
		current_tree_name = ""
		current_line_id = ""
		return
	
	var raw_text = line_data["text"]
	# print("Raw dialogue: " + raw_text)
	next = line_data["next"]
	
	# Only open dialogue window and play sound if this line has visible text
	var has_visible_text = _has_visible_text(raw_text)
	if has_visible_text:
		# Open dialogue window if not in battle and not already open
		if not (BattleManager and BattleManager.in_battle):
			var dialogue_window = MenuManager.get_menu_window("dialogue")
			if not dialogue_window or not dialogue_window.is_open:
				await MenuManager.open_window("dialogue")
		
		# Play dialogue confirm sound when starting a new line with text
		if SoundManager:
			SoundManager.play_sound("res://sounds/menu/dialogue_confirm.wav")
	
	# NOW get the label after the window has been opened (only if there's visible text)
	if has_visible_text:
		if label == null:
			label = _get_dialogue_label()
		
		# Safety check: stop if label becomes invalid (scene changed, etc)
		if not is_instance_valid(label):
			print("Label invalid before parse_text, aborting")
			is_open = false
			current_tree_name = ""
			current_line_id = ""
			current_npc = null
			return
		
		var box = _get_dialogue_box_for(label)
		if box:
			box.visible = true
	
	var should_wait = await parse_text(raw_text, label)
	if should_wait:
		await wait_for_confirm()
		
	
	# Safety check: if dialogue was force-stopped (e.g., during scene load), bail out
	if not is_open or current_line_id == "" or current_tree_name == "":
		# print("[DIALOGUE] Dialogue was stopped, aborting read_line")
		return
	
	# Re-fetch label after await in case window state changed (e.g., submenu opened)
	if has_visible_text:
		label = _get_dialogue_label()
	
	# Safety check before continuing to next line
	if has_visible_text and not is_instance_valid(label):
		print("Label became invalid during dialogue, ending dialogue")
		is_open = false
		current_tree_name = ""
		current_line_id = ""
		current_npc = null
		return
	
	# Handle conditional_next and choices for both visible and non-visible text
	if current_tree["lines"][ID]["choices"].size() == 0:
		if current_tree["lines"][ID]["cond_next"].is_empty():
			# No choices and no conditional_next
			if has_visible_text:
				read_line(next)
			# else: no visible text and no routing, don't auto-advance (events handled it)
		else:
			# Has conditional_next, process it regardless of visible text
			read_line(iterate_conditionals(current_tree["lines"][ID]["cond_next"], current_tree["lines"][ID]["next"]))
	else:
		# Has choices, always process them
		choice = await populate_choices(current_tree["lines"][ID]["choices"])
		read_line(choice)

func _has_visible_text(input: String) -> bool:
	"""Check if a dialogue line has any visible text (after stripping events)"""
	var split_text = input.split("`")
	var working_text = ""
	for i in range(0, split_text.size()):
		if i % 2 == 0:  # Text parts (not events)
			working_text += split_text[i].strip_edges()
	return working_text != ""

func _get_visible_length(text: String) -> int:
	var clear_text = bbcode_regex.sub(text, "", true)
	return clear_text.length()

func _get_punctuation_pause(text: String, char_index: int) -> float:
	"""Check if the character at char_index is punctuation and return pause multiplier.
	Returns 0 for no pause, or a multiplier for how long to pause (in multiples of text_speed).
	"""
	# Get the visible text without BBCode
	var clear_text = bbcode_regex.sub(text, "", true)
	
	if char_index >= clear_text.length():
		return 0.0
	
	var current_char = clear_text[char_index]
	
	# Check if this is a period that's part of an ellipsis
	if current_char == ".":
		# Look ahead to see if there are more periods
		var is_ellipsis = false
		if char_index + 1 < clear_text.length() and clear_text[char_index + 1] == ".":
			is_ellipsis = true
		# Look behind to see if we were in an ellipsis
		elif char_index > 0 and clear_text[char_index - 1] == ".":
			is_ellipsis = true
		
		if is_ellipsis:
			# Check if this is the last period in the sequence
			var is_last = (char_index + 1 >= clear_text.length() or clear_text[char_index + 1] != ".")
			if is_last:
				return 3.0  # Pause after the final dot in ellipsis
			else:
				return 0.0  # No extra pause for dots in the middle of ellipsis
		else:
			# Single period - end of sentence
			return 8.0
	
	# Other punctuation
	match current_char:
		"!":
			return 8.0
		"?":
			return 8.0
		",":
			return 3.0
		":":
			return 4.0
		";":
			return 4.0
		"—":  # Em-dash
			return 6.0
		"-":
			return 1.5
	
	return 0.0

func parse_text(input: String, label: RichTextLabel, instant_print: bool = false):
	# Clear any active tooltip when regular dialogue starts
	if tooltip_active:
		clear_tooltip()
	
	# Check if we have visible text - if not, we can process without a label
	var has_visible_text_check = _has_visible_text(input)
	
	# Safety check: stop if label becomes invalid (scene changed, etc)
	# BUT allow processing if there's no visible text (events only)
	if has_visible_text_check and not is_instance_valid(label):
		print("Label invalid at start of parse_text, aborting")
		return false
	
	speed_mult = 1
	# Split by % to find subs
	var split_text = input.split("%")
	
	#do substitutions first
	for i in range(0, split_text.size()):
		if i % 2 == 1:
			var processed = await EventManager.process_events(split_text[i])
			if processed == null:
				processed = ""
			elif typeof(processed) != TYPE_STRING:
				processed = str(processed)
			split_text[i] = processed

	var full_text = "".join(split_text)
	
	# Convert -- to em-dash before processing
	full_text = full_text.replace("--", "—")
	
	var working_text: String
	var code_pos: Array[int]
	var code_str: Array[String]
	var nametag: String = ""  # Store nametag separately
	var nametag_length: int = 0  # Track BBCode length of nametag
	
	#now record the indices of all the commands (split by `)
	split_text = full_text.split("`")
	
	for i in range(0, split_text.size()):
		if i % 2 == 1:
			# Check if this is a Speaker event - process it early to insert the name tag
			var event_name = split_text[i].split("|")[0]
			if event_name == "Speaker":
				# Process Speaker event immediately and insert its return value
				var speaker_tag = await EventManager.process_events(split_text[i])
				if speaker_tag != null and typeof(speaker_tag) == TYPE_STRING:
					nametag = speaker_tag
					nametag_length = speaker_tag.length()
					working_text += speaker_tag
			else:
				# Other events: record for later execution
				code_pos.append(_get_visible_length(working_text))
				code_str.append(split_text[i])
		else:
			working_text += split_text[i].strip_edges()
			
	full_text = working_text
	
	# Add oscillating down arrow indicator at the end if there's visible text
	if full_text.strip_edges() != "":
		full_text += " [wave amp=20 freq=5][font_size=12]▼[/font_size][/wave]"
	
	# Center text ONLY when using battle's direct dialogue label (quick_read), NOT dialogue window
	if BattleManager and BattleManager.in_battle and label == BattleManager.dialogue_label:
		full_text = "[center]" + full_text + "[/center]"
	
	# Check if line has no visible text (only events)
	var has_text = working_text.strip_edges() != ""
	
	if has_text:
		# Safety check before accessing label (only needed when we have text)
		if not is_instance_valid(label):
			print("Label became invalid before setting text, aborting")
			return false
		
		# Reset visible characters to avoid a one-frame flash of full text when advancing lines
		label.visible_characters = 0
		label.text = full_text
		
		# Show dialogue box when there's text
		var box3 = _get_dialogue_box_for(label)
		if box3:
			box3.visible = true
	else:
		# No text, just events
		instant_print = true
		# Hide dialogue box when there's no text (only if label exists)
		if is_instance_valid(label):
			var box2 = _get_dialogue_box_for(label)
			if box2:
				box2.visible = false
	
	if instant_print:
		# print("[PARSE_TEXT] instant_print path - has_text: " + str(has_text))
		if is_instance_valid(label):
			label.visible_characters = -1 # Show all
			# print("[PARSE_TEXT] Set visible_characters to -1")
		for event in code_str:
			await EventManager.process_events(event)
		if not has_text:
			# print("[PARSE_TEXT] No text, returning false (won't wait for input)")
			return false # Don't wait for input
		# print("[PARSE_TEXT] Has text, waiting 0.1s then returning true")
		await get_tree().create_timer(0.1).timeout
		return true
	else:
		# Use visible_characters to reveal text character by character
		if not is_instance_valid(label):
			return
		
		# Calculate the visible character count for the nametag
		# We need to count how many actual visible characters (not BBCode) are in the nametag
		var nametag_visible_chars = 0
		if nametag != "":
			nametag_visible_chars = _get_visible_length(nametag)
		
		# Execute all events at position 0 (before any text) BEFORE starting typewriter
		var code_idx: int = 0
		while code_idx < code_pos.size() and code_pos[code_idx] == 0:
			await EventManager.process_events(code_str[code_idx])
			code_idx += 1
		
		# Start typewriter after the nametag
		label.visible_characters = nametag_visible_chars
		var total_chars = label.get_total_character_count()
		
		for char_index in range(nametag_visible_chars, total_chars + 1):
			# Check if player wants to instantly complete the text
			if Input.is_action_pressed("back"):
				# Show all text instantly without sounds
				label.visible_characters = -1
				# Execute any remaining events
				while code_idx < code_str.size():
					await EventManager.process_events(code_str[code_idx])
					code_idx += 1
				break
			
			# Safety check: stop if label becomes invalid (scene changed, etc)
			if not is_instance_valid(label):
				return
			label.visible_characters = char_index
			#check if it's time to execute an event
			if !code_str.is_empty() and code_idx < code_pos.size():
				if char_index == code_pos[code_idx]:
					while char_index == code_pos[code_idx]: # in case there are multiple consecutive events--took too long to debug this lmao
						# print("running event: " + code_str[code_idx])
						await (EventManager.process_events(code_str[code_idx]))
						code_idx += 1
						if code_idx >= code_pos.size(): # prevent bounds obnoxiousness
							break
			# Play sound for visible characters
			if char_index < total_chars:
				# Check if we have a speaker with voice settings
				var voice_settings = {}
				
				# Check dialogue_window (MenuManager-based)
				if MenuManager:
					var dialogue_window = MenuManager.get_menu_window("dialogue")
					if dialogue_window and dialogue_window.has_method("get_voice_settings"):
						voice_settings = dialogue_window.get_voice_settings()
				# Fallback to main dialogue box (legacy)
				if voice_settings.is_empty() and GameManager.main_dialogue_box and GameManager.main_dialogue_box.has_method("get_current_speaker_voice"):
					voice_settings = GameManager.main_dialogue_box.get_current_speaker_voice()
				
				if voice_settings.is_empty():
					# No speaker set, use default text sound
					if char_index == 0:
						pass # print("[VOICE DEBUG] First char - using default sound (no speaker)")
					SoundManager.play_sound("res://sounds/text1.wav")
				else:
					# Use character voice with pitch variation
					var voice_file = voice_settings.get("voice", "basic.wav")
					var base_pitch = voice_settings.get("voice_base_pitch", 1.0)
					var pitch_range = voice_settings.get("voice_pitch_range", 0.2)
					
					# Calculate randomized pitch
					var random_pitch = base_pitch + randf_range(-pitch_range / 2.0, pitch_range / 2.0)
					
					# Find available player from SoundManager's pool
					var player = SoundManager.get_available_voice_player()
					if player:
						var voice_path = "res://sounds/voices/" + voice_file
						var voice_stream = load(voice_path)
						if voice_stream:
							player.stream = voice_stream
							player.pitch_scale = random_pitch
							player.play()
			
			# Normal delay between characters
			await get_tree().create_timer(text_speed / speed_mult).timeout
			
			# Check for punctuation-based pausing AFTER the character is displayed
			# We check the character we just displayed (char_index - 1)
			if char_index > nametag_visible_chars:
				var pause_multiplier = _get_punctuation_pause(label.text, char_index - 1)
				if pause_multiplier > 0:
					await get_tree().create_timer((text_speed * pause_multiplier) / speed_mult).timeout
	
	return true # Wait for input after normal text printing

func wait_for_confirm():
	# Reset the flag and wait for unhandled input to set it
	# print("[INPUT DEBUG] wait_for_confirm() called - resetting confirm_pressed")
	confirm_pressed = false
	var frame_count = 0
	while not confirm_pressed:
		await get_tree().process_frame
		frame_count += 1
		# if frame_count % 60 == 0:  # Print every 60 frames
			# print("[INPUT DEBUG] Still waiting for confirm... is_open: ", is_open)
	# print("[INPUT DEBUG] wait_for_confirm() detected confirm_pressed, continuing")

func populate_choices(choices: Array) -> String:
	# Extract text and next values from choice array
	var choice_texts = []
	var choice_next_ids = []
	for choice in choices:
		choice_texts.append(choice["text"])
		choice_next_ids.append(choice["next"])
	
	# Use the new MenuManager choices window for both battle and overworld
	await MenuManager.open_window("dialogue_choices")
	var choices_window = MenuManager.get_menu_window("dialogue_choices")
	if not choices_window:
		print("[DIALOGUE] ERROR: Could not get dialogue_choices window")
		return ""
	
	var result = await choices_window.populate_choices(choice_texts, choice_next_ids)
	choices_window.close_window()
	return result

# Track the currently displayed text for language switching
var quick_read_label: RichTextLabel = null
var quick_read_json_parent: String = ""  # e.g. "enemy_troops" or "battle"
var quick_read_json_subkey: String = ""  # e.g. "treacherous_troop_boss" or empty
var quick_read_json_key: String = ""     # e.g. "entrance" or "battle_start"

# Tooltip state tracking
var tooltip_active: bool = false
var tooltip_label: RichTextLabel = null

func _find_dialogue_box_for(label: RichTextLabel) -> Node:
	# Walk up the tree to find the DialogueBox root container if possible
	var node: Node = label
	while node:
		# Prefer a node explicitly named DialogueBox/dialogue_box (case/underscore insensitive)
		var sanitized := node.name.to_lower().replace("_", "")
		if sanitized == "dialoguebox":
			return node
		# Fallback: NinePatchRect backdrop inside the box
		if node is NinePatchRect:
			return node
		node = node.get_parent()
	return null

func _get_dialogue_box_for(label: RichTextLabel) -> Node:
	# Prefer explicit exported property if present on the label's script
	var box: Node = null
	var props = label.get_property_list()
	for p in props:
		if p.has("name") and p.get("name") == "dialogue_box":
			box = label.get("dialogue_box")
			break
	if box == null:
		box = _find_dialogue_box_for(label)
	return box

func quick_read(text: String, label: RichTextLabel = GameManager.dialogue_label, json_parent: String = "", json_subkey: String = "", json_key: String = ""):
	# print("[QUICK_READ] Starting - text: '" + text.substr(0, 50) + "...'")
	# print("[QUICK_READ] is_open before: " + str(is_open) + ", confirm_pressed: " + str(confirm_pressed))
	is_open = true
	quick_read_label = label
	quick_read_json_parent = json_parent
	quick_read_json_subkey = json_subkey
	quick_read_json_key = json_key
	
	# Play dialogue confirm sound when starting quick read
	if SoundManager:
		SoundManager.play_sound("res://sounds/menu/dialogue_confirm.wav")
	
	var box = _get_dialogue_box_for(label)
	if box:
		box.visible = true
	# print("[QUICK_READ] About to call parse_text")
	await parse_text(text, label, true)
	# print("[QUICK_READ] parse_text completed, about to wait_for_confirm")
	await wait_for_confirm()
	# print("[QUICK_READ] wait_for_confirm completed")
	
	# Don't close dialogue if shop is active
	if not (GameManager.shop_window and GameManager.shop_window.active):
		is_open = false
	
	quick_read_label = null
	quick_read_json_parent = ""
	quick_read_json_subkey = ""
	quick_read_json_key = ""
	if box and is_instance_valid(box):
		box.visible = false

func quick_swap(text: String, label: RichTextLabel):
	"""Swap displayed text without waiting for input - used for language changes"""
	# print("[DIALOGUE] quick_swap called with text: " + text)
	if !label or !is_instance_valid(label):
		return
	
	# Use parse_text's core logic to format the text
	speed_mult = 1
	var split_text = text.split("%")
	
	# Do substitutions
	for i in range(0, split_text.size()):
		if i % 2 == 1:
			var processed = await EventManager.process_events(split_text[i])
			if processed == null:
				processed = ""
			elif typeof(processed) != TYPE_STRING:
				processed = str(processed)
			split_text[i] = processed
	
	var full_text = "".join(split_text)
	
	var working_text: String = ""
	var code_str: Array[String]
	
	# Record indices of commands (split by `) and remove them
	split_text = full_text.split("`")
	for i in range(0, split_text.size()):
		if i % 2 == 1:
			code_str.append(split_text[i])
		else:
			working_text += split_text[i].strip_edges()
	
	full_text = working_text
	
	# Center text ONLY when using battle's direct dialogue label, NOT dialogue window
	if BattleManager and BattleManager.in_battle and label == BattleManager.dialogue_label:
		full_text = "[center]" + full_text + "[/center]"
	
	label.text = full_text
	label.visible_characters = -1  # Show all immediately


func _unhandled_input(event):
	# Debug: Log all confirm presses
	if event.is_action_pressed("confirm") and not event.is_echo():
		pass # print("[INPUT DEBUG] Confirm pressed - is_open: ", is_open, ", confirm_pressed: ", confirm_pressed)
	
	# Only handle confirm when dialogue is open (only on press, not echo)
	if is_open and event.is_action_pressed("confirm") and not event.is_echo():
		# print("[INPUT DEBUG] Setting confirm_pressed to true")
		confirm_pressed = true
		get_viewport().set_input_as_handled()

func _ready() -> void:
	bbcode_regex = RegEx.new()
	bbcode_regex.compile("\\[.+?\\]")
	
	# print("DialogueManager _ready() called")
	begin_conversion()
	# print("DialogueManager _ready() finished")

func reload_current_dialogue():
	if !is_open:
		return
	
	# Battle quick_read
	if quick_read_json_parent != "" and quick_read_json_key != "":
		var dict = DataManager.get(quick_read_json_parent)
		if dict:
			# If there's a subkey, navigate one level deeper
			if quick_read_json_subkey != "" and dict.has(quick_read_json_subkey):
				dict = dict[quick_read_json_subkey]
			
			if dict.has(quick_read_json_key):
				quick_swap(dict[quick_read_json_key], quick_read_label)
	
	# Overworld XML
	if current_tree_name != "" and current_line_id != "" and dialogues.has(current_tree_name):
		current_tree = dialogues[current_tree_name]
		if current_tree.has("lines") and current_tree["lines"].has(current_line_id):
			var line_data = current_tree["lines"][current_line_id]
			var new_text = line_data.get("text", "")
			if new_text != "":
				quick_swap(new_text, GameManager.dialogue_label)
			
			# Reload choices if they exist
			if line_data.has("choices") and line_data["choices"].size() > 0:
				var choice_buttons = GameManager.main_dialogue_box.choice_buttons
				for i in range(min(line_data["choices"].size(), choice_buttons.size())):
					if choice_buttons[i].visible:
						choice_buttons[i].text = line_data["choices"][i]["text"]


func begin_conversion():
	print("!!! BEGIN_CONVERSION STARTING !!!")
	var xml_data_dir = "res://scripts/xml_data"
	
	# Use DataParser's parallelized loader
	# It handles loading English first, then overriding with the selected language
	dialogues = DataParser.dialogue_xml_dir_to_dict(xml_data_dir, GameManager.game_language)
	
	print(GameManager.game_language + " dialogue loaded. Total dialogues: " + str(dialogues.size()))

func test_conversion():
	print("Beginning XML conversion.")
	dialogues["lucy_rest"] = convert_xml("res://scripts/xml_data/english/lucy_rest.xml") # TODO: iterate over every file
	print("Dialogue as dictionary: " + str(dialogues))

func tool_tip(text: String, label: RichTextLabel = null):
	"""Display a tooltip message that doesn't require button press to dismiss.
	Tooltip will automatically clear when:
	- Battle phase changes
	- Regular dialogue starts printing
	- Explain is pressed again (toggles off)
	"""
	# Get label if not provided
	if label == null:
		if BattleManager and BattleManager.in_battle and BattleManager.dialogue_label:
			label = BattleManager.dialogue_label
		else:
			label = _get_dialogue_label()
	
	if not is_instance_valid(label):
		print("[TOOLTIP] No valid label found")
		return
	
	# Set tooltip state
	tooltip_active = true
	tooltip_label = label
	
	# Process text (strip events and format)
	var split_text = text.split("`")
	var working_text = ""
	for i in range(0, split_text.size()):
		if i % 2 == 0:  # Text parts (not events)
			working_text += split_text[i].strip_edges()
	
	# Display the text immediately (no typewriter effect, no arrow indicator)
	label.text = working_text
	label.visible_characters = -1  # Show all
	label.modulate.a = 1.0  # Ensure full opacity
	
	# Show dialogue box
	var box = _get_dialogue_box_for(label)
	if box:
		box.visible = true
		box.modulate.a = 1.0  # Ensure full opacity

func clear_tooltip():
	"""Clear the active tooltip"""
	if not tooltip_active:
		return
	
	tooltip_active = false
	
	if is_instance_valid(tooltip_label):
		tooltip_label.text = ""
		var box = _get_dialogue_box_for(tooltip_label)
		if box:
			box.visible = false
	
	tooltip_label = null

func is_tooltip_active() -> bool:
	"""Check if a tooltip is currently being displayed"""
	return tooltip_active

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
