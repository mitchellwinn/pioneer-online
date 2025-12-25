extends StateMeleeAttack
class_name StateMeleeSlash3

## Third slash of the 3-hit combo - the finisher
## Overhead slam - more damage, longer recovery

func _init():
	super._init()
	combo_index = 2
	next_state_name = ""  # Last in combo
	
	# Timing - bigger wind up, longer recovery
	wind_up_time = 0.1
	active_time = 0.2
	recovery_time = 0.35
	cancel_window_start = 0.45  # Can cancel late into dodge/other
	cancel_window_end = 0.6
	
	# Movement - big lunge
	step_distance = 1.0
	
	# Animation
	animation_name = "melee_slash_3"
	animation_speed = 1.4
	
	# Higher priority - harder to interrupt the finisher
	priority = 15
