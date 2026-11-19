extends CharacterBody3D

# ==============================================================================
# SCRIPT DO FANTASMA (IA CONTROLADA EXCLUSIVAMENTE PELO SERVIDOR)
# ==============================================================================

# Velocidade de locomoção e flutuação do fantasma
const MOVE_SPEED: float = 2.0

# Referências
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer

# Dados do cômodo/setor favorito e patrulha
var favorite_room: Marker3D = null
var favorite_room_position: Vector3 = Vector3.ZERO
var current_target_position: Vector3 = Vector3.ZERO
var is_waiting: bool = false

func _enter_tree() -> void:
	# O Host (servidor - ID 1) é sempre a autoridade do fantasma
	set_multiplayer_authority(1)
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(1)

func _ready() -> void:
	# Adiciona ao grupo global para o detector localizá-lo com facilidade
	add_to_group("ghost")

	# Clientes não executam física nem tomada de decisões de IA.
	# A posição e a rotação são recebidas do servidor via MultiplayerSynchronizer.
	if not multiplayer.is_server():
		set_physics_process(false)
		return

	# No Servidor: aguarda a sincronização do NavigationServer antes de buscar caminhos
	await get_tree().physics_frame
	
	_choose_favorite_room()
	_pick_next_patrol_point()
	_start_light_flicker_loop()

# ==============================================================================
# IA E NAVEGAÇÃO (APENAS SERVIDOR)
# ==============================================================================

# Escolhe aleatoriamente um dos Marker3D no grupo "ghost_rooms"
func _choose_favorite_room() -> void:
	var rooms = get_tree().get_nodes_in_group("ghost_rooms")
	if not rooms.is_empty():
		favorite_room = rooms.pick_random() as Marker3D
		favorite_room_position = favorite_room.global_position
		# Teleporta inicialmente o fantasma para o setor favorito
		global_position = favorite_room_position + Vector3(0, 0.5, 0)
		print("[FANTASMA] Setor favorito do cemitério escolhido: %s na posição %v" % [favorite_room.name, favorite_room_position])
	else:
		favorite_room_position = global_position
		print("[FANTASMA] Nenhum marcador no grupo 'ghost_rooms' encontrado. Usando posição inicial.")

# Seleciona um ponto aleatório ao redor do setor favorito para vagar
func _pick_next_patrol_point() -> void:
	# Chance de 20% de trocar de setor no cemitério para perambular entre as áreas (portão, capela, cripta, etc.)
	if randf() < 0.2:
		var rooms = get_tree().get_nodes_in_group("ghost_rooms")
		if not rooms.is_empty():
			favorite_room = rooms.pick_random() as Marker3D
			favorite_room_position = favorite_room.global_position
			print("[FANTASMA] O fantasma mudou de setor e agora vaga em direção a: ", favorite_room.name)

	var angle: float = randf() * TAU
	var radius: float = randf_range(1.5, 5.5)
	var offset: Vector3 = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	
	current_target_position = favorite_room_position + offset
	nav_agent.target_position = current_target_position
	is_waiting = false

func _physics_process(delta: float) -> void:
	# Apenas o servidor executa o deslocamento
	if not multiplayer.is_server():
		return

	if is_waiting:
		return

	# Verifica se chegou ao destino
	var dist_to_target: float = global_position.distance_to(current_target_position)
	if nav_agent.is_navigation_finished() or dist_to_target <= 0.8:
		velocity = Vector3.ZERO
		is_waiting = true
		# Espera alguns segundos no local antes de ir para o próximo ponto
		await get_tree().create_timer(randf_range(2.0, 4.5)).timeout
		if is_inside_tree() and multiplayer.is_server():
			_pick_next_patrol_point()
		return

	# Obtém o próximo ponto calculado pelo NavigationAgent3D
	var next_path_pos: Vector3 = nav_agent.get_next_path_position()
	
	# Fallback de segurança: caso a malha de navegação ainda não tenha sido assada no editor
	if next_path_pos.distance_to(global_position) < 0.1:
		next_path_pos = current_target_position

	var move_dir: Vector3 = (next_path_pos - global_position)
	move_dir.y = 0.0

	if move_dir.length_squared() > 0.01:
		var dir_normalized = move_dir.normalized()
		# Rotação suave em direção ao movimento
		var target_yaw = atan2(-dir_normalized.x, -dir_normalized.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, 3.5 * delta)
		
		velocity.x = dir_normalized.x * MOVE_SPEED
		velocity.z = dir_normalized.z * MOVE_SPEED
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	move_and_slide()

# ==============================================================================
# EVENTO DE APAGÃO E PISCAR DOS POSTES (RPC SINCRONIZADO)
# ==============================================================================

func _start_light_flicker_loop() -> void:
	while is_inside_tree() and multiplayer.is_server():
		var interval: float = randf_range(20.0, 40.0)
		await get_tree().create_timer(interval).timeout
		
		if not is_inside_tree() or not multiplayer.is_server():
			return
			
		# O fantasma apaga os postes dentro de um raio de 12 metros a partir de sua posição atual
		trigger_light_blackout.rpc(global_position, 12.0)

@rpc("call_local", "reliable")
func trigger_light_blackout(ghost_pos: Vector3, radius: float = 12.0) -> void:
	var posts = get_tree().get_nodes_in_group("street_lights")
	# Compatibilidade caso ainda haja nós no grupo room_lights
	if posts.is_empty():
		posts = get_tree().get_nodes_in_group("room_lights")

	var target_lights: Array[Node] = []

	# Seleciona os postes de iluminação dentro do raio do fantasma
	for node in posts:
		if node is Node3D:
			if node.global_position.distance_to(ghost_pos) <= radius:
				target_lights.append(node)

	# Fallback: caso nenhum poste esteja no raio imediato, afeta o poste mais próximo
	if target_lights.is_empty() and not posts.is_empty():
		var nearest_post: Node = null
		var min_dist: float = INF
		for node in posts:
			if node is Node3D:
				var dist: float = node.global_position.distance_to(ghost_pos)
				if dist < min_dist:
					min_dist = dist
					nearest_post = node
		if nearest_post:
			target_lights.append(nearest_post)

	if target_lights.is_empty():
		return

	print("[FANTASMA] Postes de luz próximos começam a piscar de forma irregular...")

	# 1. Antes de apagar, as luzes piscam de forma irregular por 1,5 s
	var flicker_delays: Array[float] = [0.14, 0.08, 0.20, 0.06, 0.18, 0.10, 0.22, 0.12, 0.18, 0.12, 0.10]
	var current_state: bool = false
	for delay in flicker_delays:
		current_state = not current_state
		_set_nodes_light_state(target_lights, current_state)
		await get_tree().create_timer(delay).timeout
		if not is_inside_tree():
			return

	# 2. Depois ficam apagadas 5 s
	_set_nodes_light_state(target_lights, false)
	print("[FANTASMA] Postes apagados no escuro total!")

	await get_tree().create_timer(5.0).timeout
	if not is_inside_tree():
		return

	# 3. E reacendem
	_set_nodes_light_state(target_lights, true)
	print("[FANTASMA] Postes voltaram a acender.")

# Altera o estado da luz e da lâmpada de uma lista de postes ou luzes
func _set_nodes_light_state(nodes: Array[Node], enabled: bool) -> void:
	for node in nodes:
		if not is_instance_valid(node):
			continue
		if node.has_method("set_light_enabled"):
			node.set_light_enabled(enabled)
		elif node is Light3D:
			node.visible = enabled
		elif node.has_node("OmniLight3D"):
			node.get_node("OmniLight3D").visible = enabled
