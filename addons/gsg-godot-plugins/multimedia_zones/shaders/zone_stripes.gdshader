shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

uniform vec4 stripe_color : source_color = vec4(1.0, 0.5, 0.0, 0.3);
uniform float stripe_width : hint_range(0.1, 5.0) = 0.5;
uniform float stripe_spacing : hint_range(0.1, 5.0) = 2.0;
uniform float scroll_speed : hint_range(0.0, 2.0) = 0.2;
uniform float stripe_angle : hint_range(-90.0, 90.0) = 45.0;

void fragment() {
	// Use model space position for consistent stripe size
	vec3 pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	
	// Convert angle to radians
	float angle_rad = radians(stripe_angle);
	
	// Create rotation matrix for diagonal stripes
	float cos_a = cos(angle_rad);
	float sin_a = sin(angle_rad);
	
	// Apply rotation to world position (using XZ plane)
	vec2 rotated_pos;
	rotated_pos.x = pos.x * cos_a - pos.z * sin_a;
	rotated_pos.y = pos.x * sin_a + pos.z * cos_a;
	
	// Add time-based scrolling
	float scroll_offset = TIME * scroll_speed;
	float coord = rotated_pos.x + scroll_offset;
	
	// Create stripe pattern (in world units)
	float pattern = mod(coord, stripe_spacing);
	float stripe = step(pattern, stripe_width);
	
	// Apply stripe color with opacity
	ALBEDO = stripe_color.rgb;
	ALPHA = stripe * stripe_color.a;
}
