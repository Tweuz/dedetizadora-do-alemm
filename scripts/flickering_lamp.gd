extends "res://scripts/lamp_post.gd"

# ==============================================================================
# POSTE DE ILUMINAÇÃO DEFEITUOSO (PISCA DE FORMA IRREGULAR O TEMPO TODO)
# ==============================================================================

@export var min_flicker_delay: float = 0.04
@export var max_flicker_delay: float = 0.32
@export var darkness_chance: float = 0.38

func _ready() -> void:
	super._ready()
	_run_flicker_loop()

func _run_flicker_loop() -> void:
	while is_inside_tree():
		var delay: float = randf_range(min_flicker_delay, max_flicker_delay)
		await get_tree().create_timer(delay).timeout
		if not is_inside_tree():
			return
		
		# Alterna o estado com piscares curtos e falhas
		var is_lit: bool = randf() > darkness_chance
		set_light_enabled(is_lit)
