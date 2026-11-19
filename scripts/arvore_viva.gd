extends Node3D

# ==============================================================================
# SCRIPT DE ÁRVORE VIVA (SUSSURROS, BALANÇO E OLHOS VERMELHOS EMISSIVOS)
# ==============================================================================

const SoundBank = preload("res://scripts/sound_bank.gd")

@export var max_detection_distance: float = 30.0
@export var detection_angle_deg: float = 50.0
@export var scare_close_distance: float = 12.0
@export var scare_direct_angle_deg: float = 15.0

@onready var canopy: Node3D = $Canopy
@onready var eyes: Node3D = $Canopy/Eyes
@onready var audio_player: AudioStreamPlayer3D = $AudioStreamPlayer3D

var _is_eyes_active: bool = false
var _is_armed: bool = false
var _initial_canopy_rot: Vector3 = Vector3.ZERO

func _ready() -> void:
	add_to_group("arvores_vivas")
	if canopy:
		_initial_canopy_rot = canopy.rotation
	if eyes:
		eyes.visible = false

# 1. Balança de leve a copa da árvore com Tween
func sway() -> void:
	if not canopy:
		return
	var tween = create_tween()
	var sway_angle = deg_to_rad(randf_range(1.8, 3.8))
	if randf() > 0.5:
		sway_angle = -sway_angle

	tween.tween_property(canopy, "rotation:z", _initial_canopy_rot.z + sway_angle, 0.45).set_trans(Tween.TRANS_SINE)
	tween.tween_property(canopy, "rotation:z", _initial_canopy_rot.z - (sway_angle * 0.5), 0.55).set_trans(Tween.TRANS_SINE)
	tween.tween_property(canopy, "rotation:z", _initial_canopy_rot.z, 0.45).set_trans(Tween.TRANS_SINE)

# 2. Toca sussurro espacial 3D em volume baixo, tom e duração variados
func play_whisper() -> void:
	if not audio_player:
		return
	audio_player.stream = SoundBank.get_sound("sussurro")
	audio_player.pitch_scale = randf_range(0.85, 1.22)
	audio_player.volume_db = randf_range(-9.0, -4.5)
	audio_player.play()

# 3. Deixa a árvore armada por 6 segundos aguardando o jogador olhar na sua direção
func arm(duration: float = 6.0) -> void:
	if _is_armed or _is_eyes_active:
		return
	_is_armed = true
	_run_arm_loop(duration)

func _run_arm_loop(duration: float) -> void:
	var elapsed: float = 0.0
	var step: float = 0.06

	while elapsed < duration and _is_armed and is_inside_tree():
		await get_tree().create_timer(step).timeout
		elapsed += step

		var cam = get_viewport().get_camera_3d()
		if not cam:
			continue

		var to_tree: Vector3 = global_position - cam.global_position
		var dist: float = to_tree.length()

		if dist <= max_detection_distance:
			var cam_forward: Vector3 = -cam.global_transform.basis.z
			var angle_deg: float = rad_to_deg(cam_forward.angle_to(to_tree.normalized()))

			# Se o jogador olhar para a árvore armada (< 50 graus)
			if angle_deg <= detection_angle_deg:
				_is_armed = false
				_manifest_eyes(cam)
				return

	_is_armed = false

# 4. Manifesta os olhos diretamente (caso sem sussurro)
func show_eyes_directly() -> void:
	if _is_eyes_active:
		return
	var cam = get_viewport().get_camera_3d()
	if cam:
		_manifest_eyes(cam)

func _manifest_eyes(cam: Camera3D) -> void:
	if _is_eyes_active or not eyes:
		return
	_is_eyes_active = true

	# Varia a altura dos olhos na copa ou entre os galhos
	eyes.position.y = randf_range(2.0, 4.4)
	eyes.visible = true

	# Aponta os olhos para a câmera do jogador
	eyes.look_at(cam.global_position, Vector3.UP)

	# Duração base de 1 a 2 segundos
	var duration: float = randf_range(1.1, 2.0)
	var elapsed: float = 0.0
	var step: float = 0.05

	while elapsed < duration and is_inside_tree():
		await get_tree().create_timer(step).timeout
		elapsed += step

		var current_cam = get_viewport().get_camera_3d()
		if not current_cam:
			break

		var to_tree: Vector3 = global_position - current_cam.global_position
		var dist: float = to_tree.length()
		var cam_forward: Vector3 = -current_cam.global_transform.basis.z
		var angle_deg: float = rad_to_deg(cam_forward.angle_to(to_tree.normalized()))

		# Se o jogador chegar perto (< 12 m) E encarar a árvore (< 15 graus) -> somem na hora assustados!
		if dist < scare_close_distance and angle_deg < scare_direct_angle_deg:
			break

	eyes.visible = false
	_is_eyes_active = false
