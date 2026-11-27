extends CharacterBody3D

# ==============================================================================
# JOGO DE TERROR COOPERATIVO - SCRIPT DO JOGADOR (PRIMEIRA PESSOA)
# ==============================================================================

const SoundBank = preload("res://scripts/sound_bank.gd")
const ItemPickupScene = preload("res://scenes/item_pickup.tscn")

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
@export var lives: int = 3

# Inventário
@export var inventory_slots: int = 4
# Array de dicionários: {"id": String, "name": String, "count": int}
var inventory: Array[Dictionary] = []
var selected_slot_index: int = 0

# Configurações de Jumpscare por Nível de Captura (Captura 1, 2 e 3)
@export_group("Jumpscare Escalável")
@export var jumpscare_durations: Array[float] = [2.2, 2.6, 3.2]
@export var jumpscare_pitches: Array[float] = [1.0, 0.85, 0.70]
@export var jumpscare_volumes_db: Array[float] = [0.0, 4.0, 7.5] # Volume calibrado para não clipar o bus Master
@export var jumpscare_shake_multipliers: Array[float] = [1.0, 1.5, 2.0]

# Barulho que o fantasma pode ouvir
@export_group("Barulho")
@export var run_noise_radius: float = 20.0     # Alcance do barulho de correr
@export var run_noise_interval: float = 0.4    # De quanto em quanto tempo avisa enquanto corre
@export var item_noise_radius: float = 12.0    # Alcance do barulho de pegar/soltar item

# Item na mão
@export_group("Item na Mão")
@export var held_offset: Vector3 = Vector3(0.35, -0.3, -0.6)
@export var held_bob_amount: float = 0.01

# Depuração
@export_group("Depuração")
@export var debug_overlay_enabled: bool = true

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
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var flashlight: SpotLight3D = $Head/Flashlight
@onready var detector: Node3D = $Head/Detector
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer
@onready var scream_audio_player: AudioStreamPlayer3D = $ScreamAudioPlayer

# Referências de HUD
@onready var hud: CanvasLayer = $HUD
@onready var interact_prompt_label: Label = $HUD/InteractPromptLabel
@onready var inventory_slots_vbox: VBoxContainer = $HUD/InventoryMargin/InventoryVBox/InventorySlotsVBox
@onready var inventory_status_label: Label = $HUD/InventoryMargin/InventoryVBox/InventoryStatusLabel
@onready var debug_panel: PanelContainer = $HUD/DebugPanel
@onready var debug_label: Label = $HUD/DebugPanel/Margin/DebugLabel
@onready var jumpscare_control: Control = $HUD/JumpscareControl
@onready var game_over_control: Control = $HUD/GameOverControl

# Variáveis internas
var _shake_timer: float = 0.0
var _shake_intensity: float = 0.0
var is_dead: bool = false
var _spectator_target_index: int = 0
var _last_jumpscare_phrase_idx: int = -1
var _debug_timer: float = 0.0
var _current_target_item: Node = null
var _status_clear_timer: float = 0.0
var _noise_timer: float = 0.0
var held_pivot: Node3D = null
var held_mesh: MeshInstance3D = null
var _bob_time: float = 0.0

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
		
		_setup_held_item()

		if hud:
			hud.visible = true
			_update_inventory_ui()
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
# ENTRADAS DE USUÁRIO (MOUSE, TECLAS RÁPIDAS, INTERAÇÃO, F3)
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

	# Tecla F3: Liga/Desliga Painel de Depuração
	if event.is_action_pressed("debug_overlay") and debug_overlay_enabled:
		if debug_panel:
			debug_panel.visible = not debug_panel.visible
		get_viewport().set_input_as_handled()
		return

	# Modo Espectador
	if is_dead and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_cycle_spectator_target()
		get_viewport().set_input_as_handled()
		return

	if not is_dead:
		# Tecla E: Interagir / Pegar Item
		if event.is_action_pressed("interact"):
			_try_interact()
			get_viewport().set_input_as_handled()
			return

		# Tecla G: Soltar Item
		if event.is_action_pressed("drop_item"):
			_try_drop_item()
			get_viewport().set_input_as_handled()
			return

		# Seleção de Slots (1 a 4)
		if event.is_action_pressed("slot_1"):
			_select_slot(0)
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("slot_2"):
			_select_slot(1)
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("slot_3"):
			_select_slot(2)
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("slot_4"):
			_select_slot(3)
			get_viewport().set_input_as_handled()
			return

		# Rodinha do Mouse para alternar slots
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_select_slot((selected_slot_index - 1 + inventory_slots) % inventory_slots)
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_select_slot((selected_slot_index + 1) % inventory_slots)
				get_viewport().set_input_as_handled()
				return

		# Tecla F: Lanterna
		if event.is_action_pressed("toggle_flashlight"):
			toggle_flashlight()
			get_viewport().set_input_as_handled()
			return

		# Tecla Q: Detector
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

	# Mensagem temporária de status (ex: "Inventário cheio")
	if _status_clear_timer > 0.0:
		_status_clear_timer -= delta
		if _status_clear_timer <= 0.0 and inventory_status_label:
			inventory_status_label.visible = false

	# Atualização do Painel de Depuração a cada 0,25 s
	if debug_panel and debug_panel.visible:
		_debug_timer -= delta
		if _debug_timer <= 0.0:
			_debug_timer = 0.25
			_update_debug_overlay()

	if is_dead:
		_physics_process_spectator(delta)
		return

	# Checagem contínua de interação para itens à frente
	_update_interact_ray()

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

	_process_run_noise(delta)
	_update_held_bob(delta)

func _physics_process_spectator(delta: float) -> void:
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
# SISTEMA DE INTERAÇÃO E INVENTÁRIO (4 SLOTS)
# ==============================================================================

func _update_interact_ray() -> void:
	if not interact_ray or not interact_prompt_label:
		return

	if interact_ray.is_colliding():
		var col = interact_ray.get_collider()
		var item_node: Node = null
		if col:
			if col.is_in_group("items"):
				item_node = col
			elif col.get_parent() and col.get_parent().is_in_group("items"):
				item_node = col.get_parent()

		if item_node and is_instance_valid(item_node):
			_current_target_item = item_node
			var item_name = item_node.get("display_name")
			if not item_name:
				item_name = "Item"
			interact_prompt_label.text = "[E] Pegar " + str(item_name)
			interact_prompt_label.visible = true
			return

	_current_target_item = null
	interact_prompt_label.visible = false

func _try_interact() -> void:
	if _current_target_item and is_instance_valid(_current_target_item):
		# Solicita pegar o item
		if _current_target_item.has_method("interact_pickup"):
			_current_target_item.interact_pickup(self)

# Executado no servidor para validar adição de item
func server_try_add_item(item_id: String, item_name: String, item_color: Color = Color(0.6, 0.6, 0.6)) -> bool:
	if not multiplayer.is_server():
		return false

	# Caso de balas: empilha se já existir
	if item_id == "bala":
		for slot in inventory:
			if slot["id"] == "bala":
				slot["count"] += 1
				rpc_sync_inventory.rpc(inventory)
				_server_make_noise(global_position, item_noise_radius)
				return true

	# Checa se há espaço livre
	if inventory.size() >= inventory_slots:
		rpc_notify_inventory_full.rpc_id(name.to_int())
		return false

	inventory.append({
		"id": item_id,
		"name": item_name,
		"count": 1,
		"color": item_color
	})
	rpc_sync_inventory.rpc(inventory)
	_server_make_noise(global_position, item_noise_radius)
	return true

@rpc("any_peer", "call_local", "reliable")
func rpc_notify_inventory_full() -> void:
	if not is_multiplayer_authority():
		return
	if inventory_status_label:
		inventory_status_label.text = "Inventário cheio"
		inventory_status_label.visible = true
		_status_clear_timer = 1.5

@rpc("any_peer", "call_local", "reliable")
func rpc_sync_inventory(new_inventory: Array) -> void:
	if multiplayer.get_remote_sender_id() not in [0, 1]:
		return
	var copia: Array = new_inventory.duplicate(true)
	inventory.clear()
	for item in copia:
		inventory.append(item)
	_update_inventory_ui()   
	
func _select_slot(index: int) -> void:
	selected_slot_index = clamp(index, 0, inventory_slots - 1)
	_update_inventory_ui()

func _update_inventory_ui() -> void:
	if not inventory_slots_vbox or not is_multiplayer_authority():
		return

	_update_held_item()

	# Limpa labels anteriores
	for child in inventory_slots_vbox.get_children():
		child.queue_free()

	for i in range(inventory_slots):
		var lbl = Label.new()
		var slot_text = "%d: " % (i + 1)

		if i < inventory.size():
			var it = inventory[i]
			if it["id"] == "bala" and it["count"] > 1:
				slot_text += "%s x%d" % [it["name"], it["count"]]
			else:
				slot_text += "%s" % it["name"]
		else:
			slot_text += "(Vazio)"

		lbl.text = slot_text
		lbl.add_theme_font_size_override("font_size", 13)

		if i == selected_slot_index:
			lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2, 1.0)) # Destaque amarelo
			lbl.text = "► " + lbl.text
		else:
			lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.8))

		inventory_slots_vbox.add_child(lbl)

func _try_drop_item() -> void:
	if selected_slot_index < inventory.size():
		var drop_pos = global_position + (-transform.basis.z * 1.2) + Vector3(0, 0.3, 0)
		rpc_id(1, "server_request_drop_item", selected_slot_index, drop_pos)

@rpc("any_peer", "call_local", "reliable")
func server_request_drop_item(slot_idx: int, drop_pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	if slot_idx < 0 or slot_idx >= inventory.size():
		return

	var item_data = inventory[slot_idx]
	var item_id = item_data["id"]
	var item_name = item_data["name"]

	# Se for bala com contador > 1, decrementa apenas 1
	if item_id == "bala" and item_data["count"] > 1:
		item_data["count"] -= 1
	else:
		inventory.remove_at(slot_idx)

	rpc_sync_inventory.rpc(inventory)
	_server_make_noise(drop_pos, item_noise_radius)

	# Spawna o item de volta no chão
	var nm = get_tree().current_scene
	if nm and nm.has_method("spawn_item_in_world"):
		nm.spawn_item_in_world(item_id, item_name, drop_pos)

# ==============================================================================
# BARULHO (O FANTASMA OUVE) E ITEM NA MÃO
# ==============================================================================

# Corre fazendo barulho: o dono avisa o servidor, que avisa o fantasma
func _process_run_noise(delta: float) -> void:
	var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()
	if Input.is_action_pressed("sprint") and horizontal_speed > 4.5:
		_noise_timer -= delta
		if _noise_timer <= 0.0:
			_noise_timer = run_noise_interval
			if multiplayer.is_server():
				_server_make_noise(global_position, run_noise_radius)
			else:
				server_report_noise.rpc_id(1, global_position)
	else:
		_noise_timer = 0.0

@rpc("any_peer", "call_remote", "reliable")
func server_report_noise(pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	# Só aceita aviso vindo do próprio dono deste jogador
	if multiplayer.get_remote_sender_id() != name.to_int():
		return
	_server_make_noise(pos, run_noise_radius)

func _server_make_noise(pos: Vector3, radius: float) -> void:
	if not multiplayer.is_server():
		return
	for g in get_tree().get_nodes_in_group("ghost"):
		if is_instance_valid(g) and g.has_method("hear_noise"):
			g.hear_noise(pos, radius)

# Item na mão: bloco colorido na frente da câmera (provisório, até ter modelos)
func _setup_held_item() -> void:
	held_pivot = Node3D.new()
	held_pivot.name = "HeldItem"
	held_pivot.position = held_offset
	held_pivot.visible = false
	camera.add_child(held_pivot)

	held_mesh = MeshInstance3D.new()
	held_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	held_pivot.add_child(held_mesh)

func _update_held_item() -> void:
	if not held_pivot or not held_mesh:
		return
	if selected_slot_index >= inventory.size():
		held_pivot.visible = false
		return

	var it: Dictionary = inventory[selected_slot_index]
	var col: Color = it.get("color", Color(0.6, 0.6, 0.6))

	if it["id"] == "bala":
		var cil := CylinderMesh.new()
		cil.top_radius = 0.04
		cil.bottom_radius = 0.04
		cil.height = 0.18
		held_mesh.mesh = cil
	else:
		var box := BoxMesh.new()
		box.size = Vector3(0.15, 0.15, 0.25)
		held_mesh.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.5
	held_mesh.material_override = mat
	held_pivot.visible = true

# Balanço leve ao andar (só visual)
func _update_held_bob(delta: float) -> void:
	if not held_pivot or not held_pivot.visible:
		return
	var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()
	if horizontal_speed > 0.5 and is_on_floor():
		_bob_time += delta * horizontal_speed * 2.0
		held_pivot.position = held_offset + Vector3(
			cos(_bob_time * 0.5) * held_bob_amount * 0.5,
			sin(_bob_time) * held_bob_amount,
			0.0)
	else:
		held_pivot.position = held_pivot.position.lerp(held_offset, 8.0 * delta)

# ==============================================================================
# PAINEL DE DEPURAÇÃO [F3]
# ==============================================================================

func _update_debug_overlay() -> void:
	if not debug_label:
		return

	var ghost = get_tree().get_first_node_in_group("ghost") as Node3D
	var nm = get_tree().current_scene

	# 1. Tempo desde o portão
	var gate_time_str = "Portão ainda não bateu"
	if nm and nm.get("gate_slammed_time") != null and nm.gate_slammed_time > 0.0:
		var elapsed = (Time.get_ticks_msec() / 1000.0) - nm.gate_slammed_time
		var m = int(elapsed / 60.0)
		var s = int(elapsed) % 60
		gate_time_str = "%02d:%02d" % [m, s]

	# 2. Fase e próximo tempo do fantasma
	var phase_str = "N/A"
	var phase_rem_str = "N/A"
	var ghost_state_str = "N/A"
	var ghost_dist_str = "Invisível / Desconhecido"

	if ghost and is_instance_valid(ghost):
		var p_num = ghost.get("current_phase")
		if p_num != null:
			phase_str = str(p_num)
			if p_num == 0:
				phase_rem_str = "%.1fs" % ghost.get("_phase_0_timer")
			elif p_num == 1:
				phase_rem_str = "%.1fs" % ghost.get("_phase_1_timer")
			else:
				phase_rem_str = "Ativa (Fim)"

		var s_num = ghost.get("current_state")
		if p_num == 0 or not ghost.visible:
			ghost_state_str = "Invisível"
		else:
			if ghost.get("_chase_cooldown_timer") != null and ghost.get("_chase_cooldown_timer") > 0.0:
				ghost_state_str = "Pausa (%.1fs)" % ghost.get("_chase_cooldown_timer")
			elif s_num == 0:
				ghost_state_str = "Patrulha"
			elif s_num == 1:
				ghost_state_str = "Perseguição"
			elif s_num == 2:
				ghost_state_str = "Busca"
			elif s_num == 3:
				ghost_state_str = "Desconfiado"

		if ghost.visible:
			ghost_dist_str = "%.1f m" % global_position.distance_to(ghost.global_position)

	# 3. Vidas de cada jogador
	var players_info = ""
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p):
			var pname = p.get("player_name")
			var plives = p.get("lives")
			players_info += "  • %s: %d vidas\n" % [pname, plives]

	# 4. Item spawn mais próximo
	var nearest_spawn_name = "Nenhum"
	var min_s_dist = INF
	for sp in get_tree().get_nodes_in_group("item_spawn"):
		if sp is Node3D:
			var d = global_position.distance_to(sp.global_position)
			if d < min_s_dist:
				min_s_dist = d
				nearest_spawn_name = "%s (%.1fm)" % [sp.name, d]

	var ghost_extra: String = ""
	if ghost and is_instance_valid(ghost) and multiplayer.is_server():
		var dt = ghost.get("debug_text")
		if dt != null and dt != "":
			ghost_extra = "--- Fantasma (IA) ---\n%s\n" % dt

	debug_label.text = (
		"=== DEPURAÇÃO [F3] ===\n" +
		"Tempo Portão: %s\n" % gate_time_str +
		"Fantasma Fase: %s (Restam %s)\n" % [phase_str, phase_rem_str] +
		"Fantasma Estado: %s\n" % ghost_state_str +
		"Distância Fantasma: %s\n" % ghost_dist_str +
		ghost_extra +
		"Vidas dos Jogadores:\n%s" % players_info +
		"Ponto Item mais próximo: %s" % nearest_spawn_name
	)

# ==============================================================================
# SINCRONIZAÇÃO DE NOME E LANTERNA
# ==============================================================================
@rpc("call_local", "reliable")
func set_player_name(p_name: String) -> void:
	player_name = p_name

func toggle_flashlight() -> void:
	set_flashlight_state.rpc(not flashlight.visible)

@rpc("call_local", "reliable")
func set_flashlight_state(is_on: bool) -> void:
	flashlight.visible = is_on

# ==============================================================================
# SISTEMA DE CAPTURA, VIDAS E JUMPSCARE ESCALÁVEL
# ==============================================================================

func server_handle_caught() -> void:
	if not multiplayer.is_server() or is_dead:
		return

	var capture_index = max_lives - lives # 0 para captura 1, 1 para captura 2, 2 para captura 3
	lives -= 1
	sync_lives.rpc(lives)

	rpc_play_distant_scream.rpc(global_position)
	rpc_trigger_jumpscare.rpc_id(name.to_int(), capture_index)

	# Duração baseada na captura
	var wait_time = 2.4
	if capture_index >= 0 and capture_index < jumpscare_durations.size():
		wait_time = jumpscare_durations[capture_index] + 0.4

	await get_tree().create_timer(wait_time).timeout
	if not is_inside_tree():
		return

	if lives >= 2:
		_server_teleport_to_captured_spot()
	elif lives == 1:
		_server_teleport_to_cell_spot()
	else:
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

	var all_dead: bool = true
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and not p.get("is_dead"):
			all_dead = false
			break

	if all_dead:
		print("[MULTIPLAYER] TODOS OS JOGADORES MORRERAM! FIM DE JOGO!")
		rpc_show_game_over.rpc()

@rpc("any_peer", "call_local", "reliable")
func sync_lives(new_lives: int) -> void:
	lives = new_lives

@rpc("any_peer", "call_local", "reliable")
func rpc_play_distant_scream(at_pos: Vector3) -> void:
	if is_multiplayer_authority() and not multiplayer.is_server():
		return
	if scream_audio_player:
		scream_audio_player.global_position = at_pos
		scream_audio_player.stream = SoundBank.get_sound("grito")
		scream_audio_player.pitch_scale = randf_range(0.9, 1.1)
		scream_audio_player.volume_db = 0.0
		scream_audio_player.play()

@rpc("any_peer", "call_local", "reliable")
func rpc_trigger_jumpscare(capture_index: int) -> void:
	if not is_multiplayer_authority():
		return

	var phrase_indices: Array[int] = []
	for i in range(jumpscare_phrases.size()):
		if i != _last_jumpscare_phrase_idx:
			phrase_indices.append(i)
	var chosen_idx: int = phrase_indices.pick_random()
	_last_jumpscare_phrase_idx = chosen_idx

	var chosen_phrase = jumpscare_phrases[chosen_idx].replace("[nome]", player_name)
	_play_jumpscare_sequence(chosen_phrase, capture_index)

func _play_jumpscare_sequence(phrase_text: String, capture_idx: int) -> void:
	if not jumpscare_control:
		return

	var idx = clamp(capture_idx, 0, 2)
	var duration = jumpscare_durations[idx]
	var p_pitch = jumpscare_pitches[idx]
	var p_vol = jumpscare_volumes_db[idx]
	var shake_mult = jumpscare_shake_multipliers[idx]

	var black_rect = jumpscare_control.get_node_or_null("BlackRect") as ColorRect
	var white_flash = jumpscare_control.get_node_or_null("WhiteFlashRect") as ColorRect
	var monster_face = jumpscare_control.get_node_or_null("MonsterFace") as Control
	var phrase_label = jumpscare_control.get_node_or_null("PhraseLabel") as Label

	jumpscare_control.visible = true
	if monster_face:
		monster_face.visible = false
	if phrase_label:
		phrase_label.text = phrase_text
		phrase_label.visible = false
	if white_flash:
		white_flash.visible = false
	if black_rect:
		black_rect.color = Color(0, 0, 0, 1)

	# 1. Tela preta por 0.4 s
	await get_tree().create_timer(0.4).timeout
	if not is_inside_tree():
		return

	# Flash branco rápido na Captura 3 antes do rosto
	if idx == 2 and white_flash:
		white_flash.visible = true
		await get_tree().create_timer(0.08).timeout
		white_flash.visible = false

	# Toca o grito escalado
	if scream_audio_player:
		scream_audio_player.stream = SoundBank.get_sound("grito")
		scream_audio_player.pitch_scale = p_pitch
		scream_audio_player.volume_db = p_vol
		scream_audio_player.play()

	# 2. Rosto grande + frase + tremor
	if monster_face:
		monster_face.visible = true
	if phrase_label:
		phrase_label.visible = true

	var elapsed: float = 0.0
	var base_shake: float = 14.0 * shake_mult

	while elapsed < duration:
		var delta_t = get_process_delta_time()
		elapsed += delta_t
		if monster_face:
			monster_face.position = Vector2(randf_range(-base_shake, base_shake), randf_range(-base_shake, base_shake))
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

@rpc("any_peer", "call_local", "reliable")
func rpc_become_spectator() -> void:
	is_dead = true
	remove_from_group("players")
	if collision_shape:
		collision_shape.disabled = true
	if mesh:
		mesh.visible = false
	if flashlight:
		flashlight.visible = false
	if has_node("Head/Detector"):
		detector.visible = false
		detector.set_active(false)

@rpc("any_peer", "call_local", "reliable")
func rpc_show_game_over() -> void:
	if game_over_control:
		game_over_control.visible = true

@rpc("any_peer", "call_local", "reliable")
func rpc_teleport(target_position: Vector3) -> void:
	global_position = target_position
	velocity = Vector3.ZERO

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
	_add_action_key("interact", KEY_E)
	_add_action_key("drop_item", KEY_G)
	_add_action_key("debug_overlay", KEY_F3)
	_add_action_key("slot_1", KEY_1)
	_add_action_key("slot_2", KEY_2)
	_add_action_key("slot_3", KEY_3)
	_add_action_key("slot_4", KEY_4)

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
