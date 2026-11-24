extends CharacterBody3D

# ==============================================================================
# JOGO DE TERROR COOPERATIVO - SCRIPT DO JOGADOR (PRIMEIRA PESSOA)
# ==============================================================================

const SoundBank = preload("res://scripts/sound_bank.gd")

# Velocidades de locomoção
const WALK_SPEED: float = 3.5
const SPRINT_SPEED: float = 6.0
const SPECTATOR_SPEED: float = 7.0
const ACCELERATION: float = 10.0
const GRAVITY: float = 18.0

# Sensibilidade do mouse e limite vertical do olhar
@export var mouse_sensitivity: float = 0.003
var pitch_limit: float = deg_to_rad(89.0)

# Vidas e Identificação
@export var player_name: String = "Jogador"
@export var max_lives: int = 3
@export var lives: int = 3:
	set(val):
		lives = val
		_update_lives_ui()

# Frases do Jumpscare
@export var jumpscare_phrases: Array[String] = [
	"[nome]... você não devia ter vindo.",
	"Achei você, [nome].",
	"Fica comigo, [nome].",
	"Eu já cavei o seu lugar, [nome].",
	"Por que você corre, [nome]?",
	"Ninguém vai te ouvir, [nome].",
	"Você faz companhia, [nome].",
	"Mais um pra minha coleção, [nome].",
	"[nome]. [nome]. [nome]."
]

# Referências aos nós filhos
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/Flashlight
@onready var detector: Node3D = $Head/Detector
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer
@onready var scream_audio_player: AudioStreamPlayer3D = $ScreamAudioPlayer
@onready var hud: CanvasLayer = $HUD
@onready var lives_container: HBoxContainer = $HUD/MarginContainer/LivesContainer
@onready var jumpscare_control: Control = $HUD/JumpscareControl
@onready var game_over_control: Control = $HUD/GameOverControl

# Variáveis para tremor de câmera (camera shake)
var _shake_timer: float = 0.0
var _shake_intensity: float = 0.0

# Estado de espectador (quando vidas <= 0)
var is_dead: bool = false
var _spectator_target_index: int = 0
var _last_jumpscare_phrase_idx: int = -1

func _enter_tree() -> void:
	var peer_id: int = name.to_int()
	if peer_id <= 0:
		peer_id = 1
	
	set_multiplayer_authority(peer_id)
	
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(peer_id)

func _ready() -> void:
	add_to_group("players")
	_setup_default_inputs()
	
	if is_multiplayer_authority():
		camera.current = true
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		
		if has_node("Head/Detector"):
			detector.set_active(false)
		
		if hud:
			hud.visible = true
			_update_lives_ui()
	else:
		camera.current = false
		set_physics_process(false)
		set_process_unhandled_input(false)
		
		if has_node("Head/Detector"):
			detector.visible = false
			detector.set_process(false)
		
		if hud:
			hud.visible = false

# ==============================================================================
# ENTRADAS DE USUÁRIO (MOUSE E TECLAS RÁPIDAS)
# ==============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return

	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clamp(head.rotation.x, -pitch_limit, pitch_limit)
		get_viewport().set_input_as_handled()
		return

	# Modo Espectador: clique esquerdo alterna entre os outros jogadores vivos
	if is_dead and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_cycle_spectator_target()
		get_viewport().set_input_as_handled()
		return

	if not is_dead:
		if event.is_action_pressed("toggle_flashlight"):
			toggle_flashlight()
			get_viewport().set_input_as_handled()
			return

		if event.is_action_pressed("toggle_detector"):
			if has_node("Head/Detector"):
				detector.toggle_active()
			get_viewport().set_input_as_handled()
			return

# ==============================================================================
# FÍSICA E MOVIMENTAÇÃO
# ==============================================================================
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	if _shake_timer > 0.0:
		_shake_timer -= delta
		camera.h_offset = randf_range(-_shake_intensity, _shake_intensity)
		camera.v_offset = randf_range(-_shake_intensity, _shake_intensity)
	else:
		camera.h_offset = 0.0
		camera.v_offset = 0.0

	# MODO ESPECTADOR: Câmera livre / seguindo outro jogador
	if is_dead:
		_physics_process_spectator(delta)
		return

	# Gravidade
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	var current_speed: float = WALK_SPEED
	if Input.is_action_pressed("sprint"):
		current_speed = SPRINT_SPEED

	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction != Vector3.ZERO:
		velocity.x = lerp(velocity.x, direction.x * current_speed, ACCELERATION * delta)
		velocity.z = lerp(velocity.z, direction.z * current_speed, ACCELERATION * delta)
	else:
		velocity.x = lerp(velocity.x, 0.0, ACCELERATION * delta)
		velocity.z = lerp(velocity.z, 0.0, ACCELERATION * delta)

	move_and_slide()

func _physics_process_spectator(delta: float) -> void:
	# Câmera livre no modo espectador com WASD
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_basis = camera.global_transform.basis
	var fly_dir: Vector3 = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if fly_dir != Vector3.ZERO:
		global_position += fly_dir * SPECTATOR_SPEED * delta
	velocity = Vector3.ZERO

func _cycle_spectator_target() -> void:
	var alive_players: Array[Node] = []
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and p != self and not p.get("is_dead"):
			alive_players.append(p)
	if alive_players.is_empty():
		return
	_spectator_target_index = (_spectator_target_index + 1) % alive_players.size()
	var target = alive_players[_spectator_target_index]
	global_position = target.global_position + Vector3(0, 1.6, 0)

# ==============================================================================
# SINCRONIZAÇÃO DE NOME E LANTERNA
# ==============================================================================
@rpc("call_local", "reliable")
func set_player_name(p_name: String) -> void:
	player_name = p_name
	print("[JOGADOR] Nome sincronizado para: ", player_name)

func toggle_flashlight() -> void:
	set_flashlight_state.rpc(not flashlight.visible)

@rpc("call_local", "reliable")
func set_flashlight_state(is_on: bool) -> void:
	flashlight.visible = is_on

# ==============================================================================
# SISTEMA DE CAPTURA, VIDAS E JUMPSCARE
# ==============================================================================

# Chamado pelo Servidor quando o fantasma pega este jogador
func server_handle_caught() -> void:
	if not multiplayer.is_server() or is_dead:
		return

	lives -= 1
	sync_lives.rpc(lives)

	# 1. Envia RPC de jumpscare para o jogador pego
	# 2. Toca som de grito distante para os outros
	rpc_play_distant_scream.rpc(global_position)
	rpc_trigger_jumpscare.rpc_id(name.to_int(), lives)

	# O teleporte ou morte é agendado após o jumpscare (~2.6 segundos)
	await get_tree().create_timer(2.6).timeout
	if not is_inside_tree():
		return

	if lives >= 2:
		# Vida 1 perdida (restam 2): teleporta para ponto de captured_spots
		_server_teleport_to_captured_spot()
	elif lives == 1:
		# Vida 2 perdida (resta 1): teleporta para cela na cripta
		_server_teleport_to_cell_spot()
	else:
		# Vida 3 perdida (0 vidas): morre e vira espectador
		_server_set_player_dead()

func _server_teleport_to_captured_spot() -> void:
	var spots = get_tree().get_nodes_in_group("captured_spots")
	var target_pos: Vector3 = Vector3(0, 0.5, 0)
	if not spots.is_empty():
		var chosen = spots.pick_random() as Node3D
		target_pos = chosen.global_position
	else:
		target_pos = Vector3(randf_range(-15, 15), 0.5, randf_range(-10, 10))
	rpc_teleport.rpc(target_pos)

func _server_teleport_to_cell_spot() -> void:
	# TODO: cela fechada com grade e chave na cripta em tarefas futuras
	var cell_spot = get_tree().get_first_node_in_group("cell_spot")
	var target_pos: Vector3 = Vector3(-19.5, 0.5, -24.5)
	if cell_spot and cell_spot is Node3D:
		target_pos = cell_spot.global_position
	rpc_teleport.rpc(target_pos)

func _server_set_player_dead() -> void:
	is_dead = true
	rpc_become_spectator.rpc()

	# Checa se todos os jogadores morreram -> FIM DE JOGO
	var all_dead: bool = true
	var players = get_tree().get_nodes_in_group("players")
	for p in players:
		if is_instance_valid(p) and not p.get("is_dead"):
			all_dead = false
			break

	if all_dead:
		print("[MULTIPLAYER] TODOS OS JOGADORES MORRERAM! FIM DE JOGO!")
		rpc_show_game_over.rpc()

@rpc("call_local", "reliable")
func sync_lives(new_lives: int) -> void:
	lives = new_lives

@rpc("call_local", "reliable")
func rpc_play_distant_scream(at_pos: Vector3) -> void:
	# Se for o jogador pego, o grito toca diretamente no jumpscare com volume alto
	if is_multiplayer_authority() and not multiplayer.is_server():
		return
	if scream_audio_player:
		scream_audio_player.global_position = at_pos
		scream_audio_player.stream = SoundBank.get_sound("grito")
		scream_audio_player.pitch_scale = randf_range(0.9, 1.1)
		scream_audio_player.play()

@rpc("call_local", "reliable")
func rpc_trigger_jumpscare(remaining_lives: int) -> void:
	if not is_multiplayer_authority():
		return

	# Sorteia frase sem repetir a anterior
	var phrase_indices: Array[int] = []
	for i in range(jumpscare_phrases.size()):
		if i != _last_jumpscare_phrase_idx:
			phrase_indices.append(i)
	var chosen_idx: int = phrase_indices.pick_random()
	_last_jumpscare_phrase_idx = chosen_idx

	var chosen_phrase = jumpscare_phrases[chosen_idx].replace("[nome]", player_name)

	# Executa animação procedural do Jumpscare
	_play_jumpscare_sequence(chosen_phrase, remaining_lives)

func _play_jumpscare_sequence(phrase_text: String, _remaining_lives: int) -> void:
	if not jumpscare_control:
		return

	var black_rect = jumpscare_control.get_node_or_null("BlackRect") as ColorRect
	var monster_face = jumpscare_control.get_node_or_null("MonsterFace") as Control
	var phrase_label = jumpscare_control.get_node_or_null("PhraseLabel") as Label

	jumpscare_control.visible = true
	if monster_face:
		monster_face.visible = false
	if phrase_label:
		phrase_label.text = phrase_text
		phrase_label.visible = false
	if black_rect:
		black_rect.color = Color(0, 0, 0, 1)

	# 1. Tela preta por 0.4 s
	await get_tree().create_timer(0.4).timeout
	if not is_inside_tree():
		return

	# Toca o grito aterrorizante local
	if scream_audio_player:
		scream_audio_player.stream = SoundBank.get_sound("grito")
		scream_audio_player.pitch_scale = randf_range(0.95, 1.05)
		scream_audio_player.play()

	# 2. Rosto grande + frase + tremor por ~2.2 s
	if monster_face:
		monster_face.visible = true
	if phrase_label:
		phrase_label.visible = true

	var elapsed: float = 0.0
	var duration: float = 2.2
	while elapsed < duration:
		var delta_t = get_process_delta_time()
		elapsed += delta_t
		if monster_face:
			monster_face.position = Vector2(randf_range(-15, 15), randf_range(-15, 15))
		await get_tree().process_frame

	# 3. Fade para preto
	if monster_face:
		monster_face.visible = false
	if phrase_label:
		phrase_label.visible = false

	var tween = create_tween()
	if black_rect:
		black_rect.color = Color(0, 0, 0, 1)
		tween.tween_property(black_rect, "color:a", 0.0, 0.8)
	await tween.finished
	jumpscare_control.visible = false

@rpc("call_local", "reliable")
func rpc_become_spectator() -> void:
	is_dead = true
	remove_from_group("players") # Fantasma não persegue mais
	if collision_shape:
		collision_shape.disabled = true
	if mesh:
		mesh.visible = false
	if flashlight:
		flashlight.visible = false
	if has_node("Head/Detector"):
		detector.visible = false
		detector.set_active(false)
	if is_multiplayer_authority():
		_update_lives_ui()

@rpc("call_local", "reliable")
func rpc_show_game_over() -> void:
	if game_over_control:
		game_over_control.visible = true

@rpc("call_local", "reliable")
func rpc_teleport(target_position: Vector3) -> void:
	global_position = target_position
	velocity = Vector3.ZERO

# ==============================================================================
# UI DE VIDAS NO CANTO DA TELA
# ==============================================================================
func _update_lives_ui() -> void:
	if not lives_container or not is_multiplayer_authority():
		return
	var icons = lives_container.get_children()
	for i in range(icons.size()):
		if i < lives:
			icons[i].modulate = Color(0.9, 0.15, 0.15, 1.0) # Vivo
		else:
			icons[i].modulate = Color(0.2, 0.2, 0.2, 0.4)   # Perdido

# ==============================================================================
# CONFIGURAÇÃO AUTOMÁTICA DE INPUTS (FALLBACK DE SEGURANÇA)
# ==============================================================================
func _setup_default_inputs() -> void:
	_add_action_key("move_forward", KEY_W)
	_add_action_key("move_back", KEY_S)
	_add_action_key("move_left", KEY_A)
	_add_action_key("move_right", KEY_D)
	_add_action_key("sprint", KEY_SHIFT)
	_add_action_key("toggle_flashlight", KEY_F)
	_add_action_key("toggle_detector", KEY_Q)

func _add_action_key(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
		var ev: InputEventKey = InputEventKey.new()
		ev.physical_keycode = keycode
		InputMap.action_add_event(action, ev)

func shake_camera(duration: float, intensity: float = 0.25) -> void:
	if not is_multiplayer_authority():
		return
	_shake_timer = duration
	_shake_intensity = intensity
