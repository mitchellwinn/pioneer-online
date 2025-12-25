extends StateMeleeAttack
class_name StateMeleeSlash1

## First slash of the 3-hit combo
## Horizontal sweep from right to left

func _init():
	super._init()
	combo_index = 0
	next_state_name = "melee_slash_2"
	
	# Timing
	wind_up_time = 0.08
	active_time = 0.17
	recovery_time = 0.15
	cancel_window_start = 0.2
	cancel_window_end = 0.35
	
	# Movement
	step_distance = 0.6
	
	# Animation
	animation_name = "melee_slash_1"
	animation_speed = 1.5
