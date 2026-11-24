extends CharacterBody3D

# ==============================================================================
# SCRIPT DO FANTASMA (IA COMPLETA DE 3 FASES E ESTADOS - APENAS NO SERVIDOR)
# ==============================================================================

signal player_caught(jogador: CharacterBody3D)

enum Phase {
	CALM = 0,     # Fase 0: Invisível, sem colisão, postes distantes piscam raramente
	PRESENCE = 1, # Fase 1: Aparece e apenas patrulha, apaga postes
	ACTIVE = 2    # Fase 2: Patrulha, persegue e busca jogadores
}

enum State {
	PATROL = 0, # Patrulha entre pontos
	CHASE = 1,  # Perseguição direta ao jogador avistado ou ouvido
	SEARCH = 2  # Procura no último local visto
}

# --- PROPRIEDADES EXPORTADAS (CONFIGURAÇÃO E BALANCEAMENTO) ---

# Fases e Tempos Globais
@export_group("Fases de Atividade")
@export var phase_0_duration: float = 200.0   # Duração da fase calma (segundos)
@export var phase_1_duration: float = 120.0   # Duração da fase de presença antes de virar ativa
@export var phase_0_flicker_min: float = 40.0 # Intervalo mín para poste distante piscar na fase 0
@export var phase_0_flicker_max: float = 70.0 # Intervalo máx para poste distante piscar na fase 0

# Spawn do Fantasma
@export_group("Spawn da Presença")
@export var min_spawn_dist_from_players: float = 25.0 # Distância mínima de qualquer jogador ao surgir
@export var min_spawn_dist_from_gate: float = 12.0    # Distância mínima do portão sul ao surgir

# Velocidades de Locomoção
@export_group("Velocidades")
@export var patrol_speed: float = 2.0  # Velocidade lenta de patrulha (~2.0 m/s)
@export var chase_speed: float = 3.2   # Velocidade de perseguição (~3.2 m/s)
@export var search_speed: float = 2.0  # Velocidade ao ir pro último local visto (~2.0 m/s)
@export var rotation_speed: float = 4.0 # Velocidade angular de rotação suave

# Detecção e Percepção
@export_group("Percepção")
@export var fov_angle_deg: float = 70.0        # Cone de visão total (graus)
@export var max_view_distance: float = 18.0    # Alcance máximo de visão (metros)
@export var hearing_distance_sprint: float = 12.0 # Alcance para ouvir jogador correndo com Shift
@export var eye_height_offset: float = 1.95    # Altura dos olhos para checagem de Raycast
@export var catch_distance: float = 1.2        # Distância para capturar o jogador

# Busca e Cooldown
@export_group("Busca e Cooldown")
@export var lose_sight_time: float = 3.0    # Tempo sem ver antes de mudar de perseguição para busca
@export var search_spin_duration: float = 6.0 # Duração girando e procurando no último ponto visto
@export var chase_cooldown_time: float = 40.0 # Pausa pós-busca sem perseguir ninguém (apenas patrulha)
@export var caught_cooldown_time: float = 30.0 # Pausa após capturar alguém sem perseguir ninguém (~30 s)

# Apagão dos Postes
@export_group("Apagão de Luzes")
@export var light_blackout_radius: float = 8.0 # Raio ao redor para apagar postes (~8m)
@export var light_flicker_time: float = 1.0     # Duração do piscar irregular antes de apagar (~1s)
@export var light_off_time: float = 8.0         # Tempo que a luz permanece apagada (~8s)
@export var patrol_blackout_check_delay: float = 4.0 # Intervalo entre checagens de postes na patrulha

# Detecção de Travamento
@export_group("Detecção de Travamento")
@export var stuck_time_threshold: float = 3.0 # Segundos sem se mover para considerar travado
@export var stuck_dist_threshold: float = 0.3 # Deslocamento mínimo esperado em metros

# --- VARIÁVEIS SINCRONIZADAS ---
@export var current_phase: int = Phase.CALM:
	set(val):
		current_phase = val
		_apply_appearance_visibility()

@export var current_state: int = State.PATROL
@export var _phase_0_timer: float = 0.0
@export var _phase_1_timer: float = 0.0
@export var _chase_cooldown_timer: float = 0.0

# --- NÓS FILHOS ---
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var eyes_node: Node3D = $Eyes
@onready var aura_light: OmniLight3D = $GhostAuraLight
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer

# --- ESTADO INTERNO DA IA (SERVIDOR) ---
var _gate_clock_started: bool = false
var _phase_0_flicker_timer: float = 0.0

var _current_target_player: CharacterBody3D = null
var _last_seen_player_pos: Vector3 = Vector3.ZERO
var _lose_sight_timer: float = 0.0
var _search_spin_timer: float = 0.0
var _blackout_check_timer: float = 0.0

# Variáveis para verificação de travamento
var _stuck_timer: float = 0.0
var _last_stuck_check_pos: Vector3 = Vector3.ZERO

var _patrol_points: Array[Node] = []
var _current_patrol_marker: Marker3D = null
var _is_waiting_at_point: bool = false
var _blackout_active_posts: Dictionary = {} # Para evitar acionar o mesmo poste repetidamente

func _enter_tree() -> void:
	# O Host (servidor - ID 1) é sempre a autoridade máxima do fantasma
	set_multiplayer_authority(1)
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(1)

func _ready() -> void:
	# Grupo global para identificação pelo detector e mecânicas
	add_to_group("ghost")

	# Inicialmente na Fase 0 (Calma)
	_apply_appearance_visibility()

	# Apenas o servidor executa lógica, detecção, fases e física da IA
	if not multiplayer.is_server():
		set_physics_process(false)
		return

	# Conecta com o portão do cemitério para iniciar o relógio quando a pancada ocorrer
	_connect_to_gate()

	# Conecta com a área da capela caso já exista na árvore
	_connect_to_chapel_area()

	# Prepara temporizador aleatório da Fase 0
	_phase_0_flicker_timer = randf_range(phase_0_flicker_min, phase_0_flicker_max)

func _apply_appearance_visibility() -> void:
	# Na Fase 0, o fantasma é invisível e sem colisão física
	var is_visible_in_game = (current_phase != Phase.CALM)
	visible = is_visible_in_game
	if collision_shape:
		collision_shape.disabled = not is_visible_in_game
	if aura_light:
		aura_light.visible = is_visible_in_game
	if eyes_node:
		eyes_node.visible = is_visible_in_game

# ==============================================================================
# CONEXÃO COM EVENTOS DO MAPA (PORTÃO E CAPELA)
# ==============================================================================

func _connect_to_gate() -> void:
	# Procura o nó do portão no cemitério
	var gate = get_tree().get_first_node_in_group("portao")
	if not gate:
		gate = get_node_or_null("/root/Main/Cemiterio/Portao")
	if not gate:
		gate = get_tree().current_scene.find_child("Portao", true, false)

	if gate:
		if gate.has_signal("gate_slammed") and not gate.gate_slammed.is_connected(_on_gate_slammed):
			gate.gate_slammed.connect(_on_gate_slammed)
			print("[FANTASMA] Conectado com sucesso ao sinal gate_slammed do Portão.")
	else:
		print("[FANTASMA] Portão não encontrado de imediato; aguardando detecção posterior...")

func _connect_to_chapel_area() -> void:
	var chapel_area = get_tree().get_first_node_in_group("chapel_entrance")
	if not chapel_area:
		chapel_area = get_tree().current_scene.find_child("ChapelEntranceArea", true, false)
	
	if chapel_area and chapel_area is Area3D:
		if not chapel_area.body_entered.is_connected(_on_chapel_area_body_entered):
			chapel_area.body_entered.connect(_on_chapel_area_body_entered)
			print("[FANTASMA] Conectado à Area3D da Capela.")

func _on_gate_slammed() -> void:
	if not multiplayer.is_server():
		return
	_gate_clock_started = true
	_phase_0_timer = phase_0_duration
	print("[FANTASMA] Portão fechou! Relógio da Fase 0 (Calma) iniciado: %.1f s." % phase_0_duration)

func _on_chapel_area_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	# Se um jogador entrar na capela durante a Fase 0, avança imediatamente para a Fase 1!
	if current_phase == Phase.CALM and body.is_in_group("players"):
		print("[FANTASMA] Jogador %s adentrou a Capela! Despertando Presença imediatamente!" % body.name)
		_start_phase_1()

# ==============================================================================
# TRANSIÇÕES DE FASE
# ==============================================================================

func _start_phase_1() -> void:
	current_phase = Phase.PRESENCE
	current_state = State.PATROL
	_phase_1_timer = phase_1_duration
	_apply_appearance_visibility()

	# Spawna num ponto de patrulha a >= 25 m de qualquer jogador e longe do portão
	_spawn_at_safe_patrol_point()
	_pick_next_patrol_point()
	print("[FANTASMA] FASE 1 INICIADA (Presença). O fantasma surge na posição %v!" % global_position)

func _start_phase_2() -> void:
	current_phase = Phase.ACTIVE
	print("[FANTASMA] FASE 2 INICIADA (Ativa). O fantasma agora persegue jogadores!")

# ==============================================================================
# LOOP PRINCIPAL DA FÍSICA E IA (APENAS SERVIDOR)
# ==============================================================================

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	# Fallback de conexão se o portão não estava pronto no _ready
	if not _gate_clock_started:
		_check_gate_status_fallback()

	# Atualização dos temporizadores de fase
	_update_phase_timers(delta)

	# Se estiver na Fase 0 (Calma), o fantasma não tem movimentação nem tomada de decisão
	if current_phase == Phase.CALM:
		_process_phase_0(delta)
		return

	# Reduz cooldown de perseguição (após perder o jogador na busca)
	if _chase_cooldown_timer > 0.0:
		_chase_cooldown_timer -= delta

	# Checagem de travamento (se mudou menos de 0,3m em 3s durante deslocamento)
	_check_stuck(delta)

	# Checagem contínua de apagão de postes próximos por onde passa
	_process_light_blackout(delta)

	# Máquina de estados
	match current_state:
		State.PATROL:
			_state_patrol_process(delta)
		State.CHASE:
			_state_chase_process(delta)
		State.SEARCH:
			_state_search_process(delta)

func _check_gate_status_fallback() -> void:
	var gate = get_tree().get_first_node_in_group("portao")
	if not gate:
		gate = get_node_or_null("/root/Main/Cemiterio/Portao")
	if not gate:
		gate = get_tree().current_scene.find_child("Portao", true, false)

	if gate:
		if gate.has_signal("gate_slammed") and not gate.gate_slammed.is_connected(_on_gate_slammed):
			gate.gate_slammed.connect(_on_gate_slammed)
		# Se o portão já foi trancado antes da conexão
		if gate.get("is_locked") == true:
			_on_gate_slammed()

func _update_phase_timers(delta: float) -> void:
	if not _gate_clock_started:
		return

	if current_phase == Phase.CALM:
		_phase_0_timer -= delta
		if _phase_0_timer <= 0.0:
			print("[FANTASMA] Tempo da Fase 0 esgotado.")
			_start_phase_1()
	elif current_phase == Phase.PRESENCE:
		_phase_1_timer -= delta
		if _phase_1_timer <= 0.0:
			print("[FANTASMA] Tempo da Fase 1 esgotado.")
			_start_phase_2()

# --- FASE 0: COMPORTAMENTO SUTIL ---
func _process_phase_0(delta: float) -> void:
	if not _gate_clock_started:
		return

	_phase_0_flicker_timer -= delta
	if _phase_0_flicker_timer <= 0.0:
		_phase_0_flicker_timer = randf_range(phase_0_flicker_min, phase_0_flicker_max)
		_flicker_random_distant_lamp()

func _flicker_random_distant_lamp() -> void:
	var posts = get_tree().get_nodes_in_group("street_lights")
	var players = get_tree().get_nodes_in_group("players")
	var valid_posts: Array[Node] = []

	for p in posts:
		if not (p is Node3D):
			continue
		# Apenas postes dentro do cemitério
		if p.global_position.z > 35.0:
			continue

		# Deve estar distante de todos os jogadores (> 20 m)
		var is_far: bool = true
		for pl in players:
			if is_instance_valid(pl) and pl.global_position.distance_to(p.global_position) < 20.0:
				is_far = false
				break
		if is_far:
			valid_posts.append(p)

	if valid_posts.is_empty():
		return

	var chosen_post = valid_posts.pick_random()
	print("[FANTASMA FASE 0] Poste distante piscando sutilmente em %v..." % chosen_post.global_position)
	_flicker_post_briefly.rpc(chosen_post.get_path())

@rpc("call_local", "reliable")
func _flicker_post_briefly(post_path: NodePath) -> void:
	var node = get_node_or_null(post_path)
	if not node:
		return
	for delay in [0.1, 0.08, 0.15, 0.06, 0.12]:
		if node.has_method("set_light_enabled"):
			node.set_light_enabled(false)
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(node):
			return
		if node.has_method("set_light_enabled"):
			node.set_light_enabled(true)
		await get_tree().create_timer(delay).timeout

# ==============================================================================
# ESTADO 1: PATRULHA
# ==============================================================================

func _state_patrol_process(delta: float) -> void:
	# Na Fase 2 (Ativa), verifica continuamente se vê ou ouve algum jogador
	if current_phase == Phase.ACTIVE and _chase_cooldown_timer <= 0.0:
		var target = _detect_target_player()
		if target:
			_enter_chase(target)
			return

	if _is_waiting_at_point:
		return

	# Chegou ao ponto de patrulha atual?
	var dist = global_position.distance_to(nav_agent.target_position)
	if nav_agent.is_navigation_finished() or dist <= 0.8:
		velocity = Vector3.ZERO
		_is_waiting_at_point = true
		await get_tree().create_timer(randf_range(2.0, 4.0)).timeout
		if is_inside_tree() and multiplayer.is_server() and current_state == State.PATROL:
			_pick_next_patrol_point()
		return

	_move_along_path(patrol_speed, delta)

func _pick_next_patrol_point() -> void:
	_ensure_patrol_points()
	if _patrol_points.is_empty():
		return

	var candidates = _patrol_points.duplicate()
	if _current_patrol_marker and candidates.size() > 1:
		candidates.erase(_current_patrol_marker)
	candidates.shuffle()

	# Procura o primeiro candidato que seja comprovadamente alcançável
	for c in candidates:
		if c is Marker3D and _is_target_reachable(c.global_position):
			_current_patrol_marker = c
			nav_agent.target_position = c.global_position
			_is_waiting_at_point = false
			return

	# Fallback caso a checagem rigorosa não encontre
	_current_patrol_marker = candidates.pick_random() as Marker3D
	if _current_patrol_marker:
		nav_agent.target_position = _current_patrol_marker.global_position
		_is_waiting_at_point = false

func _pick_distant_patrol_point() -> void:
	_ensure_patrol_points()
	if _patrol_points.is_empty():
		return

	# Ordena os pontos por distância decrescente e escolhe o mais distante alcançável
	var sorted_points = _patrol_points.duplicate()
	sorted_points.sort_custom(func(a: Node, b: Node) -> bool:
		if not (a is Node3D) or not (b is Node3D):
			return false
		return global_position.distance_to(a.global_position) > global_position.distance_to(b.global_position)
	)

	for pt in sorted_points:
		if pt is Marker3D and _is_target_reachable(pt.global_position):
			_current_patrol_marker = pt
			nav_agent.target_position = pt.global_position
			_is_waiting_at_point = false
			return

	_pick_next_patrol_point()

func _ensure_patrol_points() -> void:
	if _patrol_points.is_empty():
		_patrol_points = get_tree().get_nodes_in_group("patrol_points")
		if _patrol_points.is_empty():
			_patrol_points = get_tree().get_nodes_in_group("ghost_rooms")
		if _patrol_points.is_empty():
			_patrol_points = get_tree().get_nodes_in_group("item_spawn")

func _is_target_reachable(target_pos: Vector3) -> bool:
	if not nav_agent:
		return true
	var map = nav_agent.get_navigation_map()
	if not map.is_valid():
		return true
	var path = NavigationServer3D.map_get_path(map, global_position, target_pos, true)
	if path.is_empty():
		return false
	# Se o caminho calculado termina razoavelmente próximo do alvo (< 2.5m)
	var end_point = path[path.size() - 1]
	return end_point.distance_to(target_pos) <= 2.5

func _check_stuck(delta: float) -> void:
	# Só verifica se estiver se deslocando ativamente
	if _is_waiting_at_point:
		_stuck_timer = 0.0
		_last_stuck_check_pos = global_position
		return

	_stuck_timer += delta
	if _stuck_timer >= stuck_time_threshold:
		var moved_dist = global_position.distance_to(_last_stuck_check_pos)
		if moved_dist < stuck_dist_threshold:
			print("[FANTASMA] travado, trocando de ponto")
			_stuck_timer = 0.0
			_last_stuck_check_pos = global_position
			if current_state == State.CHASE:
				_enter_search()
			else:
				current_state = State.PATROL
				_pick_next_patrol_point()
		else:
			_stuck_timer = 0.0
			_last_stuck_check_pos = global_position

func _is_player_in_safe_spot(player: CharacterBody3D) -> bool:
	# Se o jogador capturado estiver no CellSpot ou em um captured_spot, o fantasma não deve tentar ir até lá
	var cell_spot = get_tree().get_first_node_in_group("cell_spot")
	if cell_spot and cell_spot is Node3D:
		if player.global_position.distance_to(cell_spot.global_position) < 3.5:
			return true

	var cap_spots = get_tree().get_nodes_in_group("captured_spots")
	for sp in cap_spots:
		if sp is Node3D and player.global_position.distance_to(sp.global_position) < 3.5:
			return true

	return false

# ==============================================================================
# ESTADO 2: PERSEGUIÇÃO
# ==============================================================================

func _enter_chase(player: CharacterBody3D) -> void:
	current_state = State.CHASE
	_current_target_player = player
	_last_seen_player_pos = player.global_position
	_lose_sight_timer = 0.0
	print("[FANTASMA] PERSEGUIÇÃO INICIADA contra o jogador %s!" % player.name)

func _state_chase_process(delta: float) -> void:
	if not is_instance_valid(_current_target_player):
		_enter_search()
		return

	var dist_to_player = global_position.distance_to(_current_target_player.global_position)

	# Capturou o jogador?
	if dist_to_player <= catch_distance:
		velocity = Vector3.ZERO
		player_caught.emit(_current_target_player)
		print("[FANTASMA] PEGOU O JOGADOR %s!" % _current_target_player.name)
		
		# Trata vidas, jumpscare e teleporte no jogador
		if _current_target_player.has_method("server_handle_caught"):
			_current_target_player.server_handle_caught()

		# Após pegar, o fantasma entra em pausa de 30 s e se afasta para um ponto longe
		_chase_cooldown_timer = caught_cooldown_time
		current_state = State.PATROL
		_pick_distant_patrol_point()
		return

	# Checa se ainda tem linha de visão direta
	var can_see = _has_line_of_sight(_current_target_player)
	if can_see:
		_last_seen_player_pos = _current_target_player.global_position
		_lose_sight_timer = 0.0
	else:
		_lose_sight_timer += delta
		if _lose_sight_timer >= lose_sight_time:
			print("[FANTASMA] Perdeu o jogador de vista por %.1f s. Mudando para Busca!" % lose_sight_time)
			_enter_search()
			return

	# Move-se na direção do jogador em velocidade de perseguição
	nav_agent.target_position = _current_target_player.global_position
	_move_along_path(chase_speed, delta)

# ==============================================================================
# ESTADO 3: BUSCA
# ==============================================================================

func _enter_search() -> void:
	current_state = State.SEARCH
	_current_target_player = null
	_search_spin_timer = 0.0
	nav_agent.target_position = _last_seen_player_pos
	print("[FANTASMA] Indo até a última posição avistada: %v" % _last_seen_player_pos)

func _state_search_process(delta: float) -> void:
	# Durante a busca, se avistar novamente algum jogador, retoma perseguição imediatamente!
	var new_target = _detect_target_player()
	if new_target:
		_enter_chase(new_target)
		return

	var dist = global_position.distance_to(_last_seen_player_pos)
	# Ainda indo em direção ao último local
	if dist > 1.0 and not nav_agent.is_navigation_finished() and _search_spin_timer <= 0.0:
		_move_along_path(search_speed, delta)
		return

	# Chegou ao último local: fica girando e procurando por ~6 segundos
	velocity = Vector3.ZERO
	_search_spin_timer += delta
	rotation.y += 2.5 * delta # Gira procurando ao redor

	if _search_spin_timer >= search_spin_duration:
		print("[FANTASMA] Busca encerrada sem sucesso. Entrando em pausa de perseguição (%.1f s)." % chase_cooldown_time)
		_chase_cooldown_timer = chase_cooldown_time
		current_state = State.PATROL
		_pick_next_patrol_point()

# ==============================================================================
# SISTEMA DE PERCEPÇÃO (VISÃO POR CONE + RAYCAST E AUDIÇÃO DE SPRINT)
# ==============================================================================

func _detect_target_player() -> CharacterBody3D:
	var players = get_tree().get_nodes_in_group("players")
	var closest_player: CharacterBody3D = null
	var min_distance: float = INF

	for p in players:
		if not is_instance_valid(p) or not (p is CharacterBody3D):
			continue
		if p.get("is_dead") == true:
			continue
		# Não persegue se o jogador estiver no CellSpot ou em um captured_spot
		if _is_player_in_safe_spot(p):
			continue

		var dist = global_position.distance_to(p.global_position)

		# 1. Checagem de Audição: jogador correndo (Shift pressionado ou velocidade de sprint) a < 12m
		var is_sprinting: bool = false
		if p.velocity.length() > 4.5: # Walk é 3.5, sprint é 6.0
			is_sprinting = true

		if is_sprinting and dist <= hearing_distance_sprint:
			if dist < min_distance:
				min_distance = dist
				closest_player = p
			continue

		# 2. Checagem de Visão: dentro do cone de visão até 18 m sem obstáculos
		if dist <= max_view_distance:
			var to_player = (p.global_position - global_position).normalized()
			to_player.y = 0.0
			var forward = -transform.basis.z.normalized()
			forward.y = 0.0
			var angle_deg = rad_to_deg(forward.angle_to(to_player))

			# Dentro do cone de visão (~70 graus total = ~35 graus para cada lado)
			if angle_deg <= (fov_angle_deg * 0.5):
				if _has_line_of_sight(p):
					if dist < min_distance:
						min_distance = dist
						closest_player = p

	return closest_player

func _has_line_of_sight(player: CharacterBody3D) -> bool:
	var space_state = get_world_3d().direct_space_state
	var origin = global_position + Vector3(0, eye_height_offset, 0)
	var target = player.global_position + Vector3(0, 1.5, 0) # Altura do tronco/cabeça

	var query = PhysicsRayQueryParameters3D.create(origin, target)
	query.collision_mask = 1 # Colisão contra paredes, muros, lápides (Camada 1)
	query.exclude = [self.get_rid()]

	var result = space_state.intersect_ray(query)
	# Se colidir com algo no caminho, bloqueou a visão
	if result.is_empty():
		return true

	# Se colidir com o próprio corpo do jogador ou nada antes dele, há visão direta
	if result.collider == player:
		return true

	return false

# ==============================================================================
# MOVIMENTAÇÃO E NAVEGAÇÃO
# ==============================================================================

func _move_along_path(speed: float, delta: float) -> void:
	var next_pos: Vector3 = nav_agent.get_next_path_position()

	# Fallback se o agente já estiver muito próximo da próxima amostra
	if next_pos.distance_to(global_position) < 0.1:
		next_pos = nav_agent.target_position

	var dir = (next_pos - global_position)
	dir.y = 0.0

	if dir.length_squared() > 0.01:
		var dir_norm = dir.normalized()
		var target_yaw = atan2(-dir_norm.x, -dir_norm.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, rotation_speed * delta)
		velocity.x = dir_norm.x * speed
		velocity.z = dir_norm.z * speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	move_and_slide()

# ==============================================================================
# APAGÃO DINÂMICO DE POSTES POR ONDE PASSA
# ==============================================================================

func _process_light_blackout(delta: float) -> void:
	_blackout_check_timer -= delta
	if _blackout_check_timer > 0.0:
		return
	_blackout_check_timer = 0.5 # Checa a cada meio segundo

	var posts = get_tree().get_nodes_in_group("street_lights")
	for node in posts:
		if not (node is Node3D):
			continue
		# Apenas postes dentro do cemitério
		if node.global_position.z > 35.0:
			continue

		var dist = global_position.distance_to(node.global_position)
		if dist <= light_blackout_radius:
			var node_id = node.get_instance_id()
			if not _blackout_active_posts.has(node_id):
				_blackout_active_posts[node_id] = true
				_trigger_single_blackout.rpc(node.get_path())

@rpc("call_local", "reliable")
func _trigger_single_blackout(post_path: NodePath) -> void:
	var post = get_node_or_null(post_path)
	if not post:
		return

	# 1. Pisca irregular por ~1 s
	var flicker_delays: Array[float] = [0.1, 0.08, 0.14, 0.06, 0.12, 0.1, 0.12]
	var cur_state: bool = false
	for d in flicker_delays:
		cur_state = not cur_state
		_set_post_light(post, cur_state)
		await get_tree().create_timer(d).timeout
		if not is_instance_valid(post):
			return

	# 2. Apaga por ~8 s
	_set_post_light(post, false)
	await get_tree().create_timer(light_off_time).timeout
	if not is_instance_valid(post):
		return

	# 3. Volta a acender
	_set_post_light(post, true)

	# Libera para futuros apagões após mais alguns segundos
	await get_tree().create_timer(5.0).timeout
	if multiplayer.is_server():
		_blackout_active_posts.erase(post.get_instance_id())

func _set_post_light(post: Node, enabled: bool) -> void:
	if not is_instance_valid(post):
		return
	if post.has_method("set_light_enabled"):
		post.set_light_enabled(enabled)
	elif post.has_node("OmniLight3D"):
		post.get_node("OmniLight3D").visible = enabled

# ==============================================================================
# SPAWN SEGURO DO FANTASMA
# ==============================================================================

func _spawn_at_safe_patrol_point() -> void:
	_ensure_patrol_points()
	var players = get_tree().get_nodes_in_group("players")
	var best_point: Vector3 = Vector3(0, 0.5, -20.0) # Fallback perto da capela
	var max_min_player_dist: float = -1.0

	for pt in _patrol_points:
		if not (pt is Node3D):
			continue
		var pos = pt.global_position

		# Longe do portão sul (Z = 35)
		if abs(pos.z - 35.0) < min_spawn_dist_from_gate:
			continue

		# Calcula distância pro jogador mais próximo
		var min_p_dist: float = INF
		for pl in players:
			if is_instance_valid(pl):
				var d = pos.distance_to(pl.global_position)
				if d < min_p_dist:
					min_p_dist = d

		if min_p_dist >= min_spawn_dist_from_players:
			best_point = pos
			break
		elif min_p_dist > max_min_player_dist:
			max_min_player_dist = min_p_dist
			best_point = pos

	global_position = best_point + Vector3(0, 0.2, 0)
