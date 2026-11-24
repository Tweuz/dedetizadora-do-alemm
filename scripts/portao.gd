extends Node3D

# ==============================================================================
# SCRIPT DO PORTÃO DO CEMITÉRIO (ARTICULADO, SOM DE RANGIDO, PANCADA E SHAKE)
# ==============================================================================

signal gate_slammed

const SoundBank = preload("res://scripts/sound_bank.gd")

@export var approach_distance: float = 6.0
@export var open_duration: float = 3.5
@export var slam_duration: float = 0.4
@export var open_angle_deg: float = 85.0
@export var inside_wait_delay: float = 1.5

@onready var hinge_left: Node3D = $HingeLeft
@onready var hinge_right: Node3D = $HingeRight
@onready var col_left: CollisionShape3D = $HingeLeft/StaticBody3D/CollisionShape3D
@onready var col_right: CollisionShape3D = $HingeRight/StaticBody3D/CollisionShape3D
@onready var audio_player: AudioStreamPlayer3D = $AudioStreamPlayer3D
@onready var inside_area: Area3D = $InsideArea

var is_opened: bool = false
var is_locked: bool = false
var _is_closing_sequence: bool = false
var _entered_players: Dictionary = {}

func _ready() -> void:
	# Portão inicia fechado com colisões ativas
	hinge_left.rotation.y = 0.0
	hinge_right.rotation.y = 0.0
	col_left.disabled = false
	col_right.disabled = false

	# Conecta a detecção de entrada da Area3D logo atrás do portão
	if inside_area:
		inside_area.body_entered.connect(_on_inside_area_body_entered)

func _on_inside_area_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body.is_in_group("players"):
		_entered_players[body] = true

func _physics_process(_delta: float) -> void:
	# Somente o servidor avalia distâncias e coordena a abertura/fechamento por RPC
	if not multiplayer.is_server() or is_locked or _is_closing_sequence:
		return

	var players = get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return

	# FASE 1: Se o portão estiver fechado, verifica se TODOS os jogadores estão a menos de 6 m do lado de fora
	if not is_opened:
		var all_at_gate: bool = true
		for p in players:
			if not is_instance_valid(p):
				continue
			var dist = p.global_position.distance_to(global_position)
			# Deve estar a menos de approach_distance e do lado de fora (Z maior ou igual à posição do portão)
			if dist > approach_distance or p.global_position.z < (global_position.z - 0.5):
				all_at_gate = false
				break

		if all_at_gate:
			rpc_open_gate.rpc()
		return

	# FASE 2: Portão aberto -> verifica se TODOS os jogadores já passaram para o lado de dentro
	if is_opened and not _is_closing_sequence:
		var all_inside: bool = true
		for p in players:
			if not is_instance_valid(p):
				continue
			# Considera dentro se passou pela Area3D ou se sua coordenada Z já está dentro do cemitério
			var inside_by_pos = p.global_position.z < (global_position.z - 1.5)
			var inside_by_area = _entered_players.get(p, false)
			if not (inside_by_pos or inside_by_area):
				all_inside = false
				break

		if all_inside:
			_is_closing_sequence = true
			_server_close_sequence()

func _server_close_sequence() -> void:
	# Aguarda 1.5 s após todos entrarem antes de bater o portão
	await get_tree().create_timer(inside_wait_delay).timeout
	rpc_slam_gate.rpc()

# ==============================================================================
# SINAIS E SINCRONIZAÇÃO RPC DO PORTÃO
# ==============================================================================

@rpc("call_local", "reliable")
func rpc_open_gate() -> void:
	is_opened = true
	print("[PORTÃO] Todos os jogadores se aproximaram. O portão está abrindo...")

	# Toca o rangido longo e metálico
	if audio_player:
		audio_player.stream = SoundBank.get_sound("rangido")
		audio_player.pitch_scale = randf_range(0.95, 1.05)
		audio_player.play()

	# Desativa as colisões de bloqueio durante e após a abertura
	col_left.disabled = true
	col_right.disabled = true

	# Gira as duas folhas do portão em 3,5 segundos
	var target_rad = deg_to_rad(open_angle_deg)
	var tween = create_tween().set_parallel(true)
	tween.tween_property(hinge_left, "rotation:y", -target_rad, open_duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(hinge_right, "rotation:y", target_rad, open_duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

@rpc("call_local", "reliable")
func rpc_slam_gate() -> void:
	is_opened = false
	is_locked = true
	print("[PORTÃO] O portão bateu com força e foi trancado para sempre!")

	# Fecha as duas folhas em 0,4 segundos em alta velocidade
	var tween = create_tween().set_parallel(true)
	tween.tween_property(hinge_left, "rotation:y", 0.0, slam_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(hinge_right, "rotation:y", 0.0, slam_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	await tween.finished

	# 1. Som de impacto violento
	if audio_player:
		audio_player.stream = SoundBank.get_sound("pancada")
		audio_player.pitch_scale = randf_range(0.9, 1.05)
		audio_player.play()

	# Emite sinal da batida do portão (inicia o relógio do fantasma no servidor e clientes)
	gate_slammed.emit()

	# 2. Bloqueia a colisão definitivamente
	col_left.disabled = false
	col_right.disabled = false

	# 3. Treme a câmera do jogador local por 0.6 s
	var players = get_tree().get_nodes_in_group("players")
	for p in players:
		if is_instance_valid(p) and p.is_multiplayer_authority() and p.has_method("shake_camera"):
			p.shake_camera(0.6, 0.35)

	# 4. Faz as luzes e postes próximos piscarem com o choque da pancada
	_flicker_nearby_lights()

func _flicker_nearby_lights() -> void:
	var lights = get_tree().get_nodes_in_group("street_lights")
	var nearby: Array[Node] = []
	for l in lights:
		if l is Node3D and l.global_position.distance_to(global_position) <= 22.0:
			nearby.append(l)

	if nearby.is_empty():
		return

	# Piscar rápido com intervalos curtos
	for step in [0.06, 0.1, 0.08, 0.12]:
		for node in nearby:
			if is_instance_valid(node) and node.has_method("set_light_enabled"):
				node.set_light_enabled(false)
		await get_tree().create_timer(step).timeout
		for node in nearby:
			if is_instance_valid(node) and node.has_method("set_light_enabled"):
				node.set_light_enabled(true)
		await get_tree().create_timer(step).timeout
