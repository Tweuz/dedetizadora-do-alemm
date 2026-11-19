extends Node3D

# ==============================================================================
# SCRIPT DE ÁRVORE VIVA (EFEITO PARANORMAL DE FOLHAGEM E OLHOS VERMELHOS)
# ==============================================================================

const SoundBank = preload("res://scripts/sound_bank.gd")

@export var min_interval: float = 10.0
@export var max_interval: float = 25.0
@export var eyes_chance: float = 0.3
@export var max_detection_distance: float = 30.0
@export var detection_angle_deg: float = 35.0
@export var direct_look_angle_deg: float = 10.0

@onready var canopy: Node3D = $Canopy
@onready var eyes: Node3D = $Canopy/Eyes
@onready var audio_player: AudioStreamPlayer3D = $AudioStreamPlayer3D

var _is_eyes_active: bool = false
var _initial_canopy_rot: Vector3 = Vector3.ZERO

func _ready() -> void:
	add_to_group("arvores_vivas")
	_initial_canopy_rot = canopy.rotation
	eyes.visible = false
	
	# Associa o som sintetizado de folhagem
	audio_player.stream = SoundBank.get_sound("folhagem")
	
	# Inicia o ciclo de vida e agitação da árvore
	_start_activity_loop()

func _start_activity_loop() -> void:
	while is_inside_tree():
		var wait_time: float = randf_range(min_interval, max_interval)
		await get_tree().create_timer(wait_time).timeout
		if not is_inside_tree():
			return
			
		_trigger_tree_movement()

func _trigger_tree_movement() -> void:
	# 1. Balança de leve a copa da árvore com Tween
	var tween = create_tween()
	var sway_angle = deg_to_rad(randf_range(1.5, 3.5))
	if randf() > 0.5:
		sway_angle = -sway_angle
		
	tween.tween_property(canopy, "rotation:z", _initial_canopy_rot.z + sway_angle, 0.4).set_trans(Tween.TRANS_SINE)
	tween.tween_property(canopy, "rotation:z", _initial_canopy_rot.z - (sway_angle * 0.6), 0.5).set_trans(Tween.TRANS_SINE)
	tween.tween_property(canopy, "rotation:z", _initial_canopy_rot.z, 0.4).set_trans(Tween.TRANS_SINE)

	# 2. Toca som de folhagem 3D
	if audio_player:
		audio_player.pitch_scale = randf_range(0.9, 1.15)
		audio_player.play()

	# 3. Chance de 30% de manifestar os olhos vermelhos na copa (exclusivo e local de cada jogador)
	if randf() <= eyes_chance:
		_check_and_show_eyes()

func _check_and_show_eyes() -> void:
	if _is_eyes_active:
		return

	var cam: Camera3D = get_viewport().get_camera_3d()
	if not cam:
		return

	var to_tree: Vector3 = global_position - cam.global_position
	var dist: float = to_tree.length()

	# Distância deve ser menor que 30 m
	if dist > max_detection_distance:
		return

	var cam_forward: Vector3 = -cam.global_transform.basis.z
	var angle_rad: float = cam_forward.angle_to(to_tree.normalized())
	var angle_deg: float = rad_to_deg(angle_rad)

	# Só ativa se o jogador estiver olhando na direção geral da árvore (< 35 graus)
	if angle_deg <= detection_angle_deg:
		_run_eyes_sequence(cam)

func _run_eyes_sequence(cam: Camera3D) -> void:
	_is_eyes_active = true
	eyes.visible = true
	
	# Vira os olhos em direção à câmera
	eyes.look_at(cam.global_position, Vector3.UP)

	# Monitora a visão do jogador por até 1.8 segundos:
	# Se o jogador olhar diretamente (visão central < 10 graus) ou desviar demais, os olhos somem instantaneamente!
	var elapsed: float = 0.0
	var check_step: float = 0.05
	var duration: float = randf_range(1.2, 1.8)

	while elapsed < duration and is_inside_tree():
		await get_tree().create_timer(check_step).timeout
		elapsed += check_step

		var current_cam = get_viewport().get_camera_3d()
		if not current_cam:
			break

		var to_tree = global_position - current_cam.global_position
		var cam_forward = -current_cam.global_transform.basis.z
		var current_angle = rad_to_deg(cam_forward.angle_to(to_tree.normalized()))

		# Olhou direto para a árvore (tentou encarar) -> olhos somem assustadoramente
		if current_angle < direct_look_angle_deg:
			break
		# Virou de costas completamente -> somem
		if current_angle > 45.0:
			break

	eyes.visible = false
	_is_eyes_active = false
