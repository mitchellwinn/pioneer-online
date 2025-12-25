extends StateMeleeAttack
class_name StateMeleeSlash2

## Second slash of the 3-hit combo
## Horizontal sweep from left to right

func _init():
	super._init()
	combo_index = 1
	next_state_name = "melee_slash_3"
	
	# Timing - faster than first
	wind_up_time = 0.06
	active_time = 0.15
	recovery_time = 0.12
	cancel_window_start = 0.15
	cancel_window_end = 0.30
	
	# Movement - slightly less
	step_distance = 0.5
	
	# Animation
	animation_name = "melee_slash_2"
	animation_speed = 1.6
