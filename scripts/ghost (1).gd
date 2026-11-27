extends CharacterBody3D

# ==============================================================================
# SCRIPT DO FANTASMA (IA COMPLETA DE 3 FASES E ESTADOS - APENAS NO SERVIDOR)
# ==============================================================================

signal player_caught(jogador: CharacterBody3D)

enum Phase {
	CALM = 0,     # Antes do portão bater: invisível, sem colisão
	PRESENCE = 1, # Vigia: parado e visível perto da luz que pisca (da capela). Não ataca.
	ACTIVE = 2    # Caçada: começa quando alguém o provoca (item de puzzle). Patrulha, persegue, busca
}

enum State {
	PATROL = 0, # Patrulha entre pontos
	CHASE = 1,  # Perseguição direta ao jogador avistado ou ouvido
	SEARCH = 2, # Procura no último local visto
	SUSPICIOUS = 3 # Ouviu um barulho: para, vira pra olhar e decide se persegue
}

# --- PROPRIEDADES EXPORTADAS (CONFIGURAÇÃO E BALANCEAMENTO) ---

# Vigia (fantasma parado perto da luz piscando)
@export_group("Vigia")
@export var vigil_offset: Vector3 = Vector3(1.8, 0.2, 0.0) # Onde fica em relação ao poste (se não houver marcador ghost_vigil)
@export var vigil_flicker_interval: float = 3.5  # De quanto em quanto tempo a luz dele pisca
@export var vigil_look_distance: float = 14.0    # Ele vira a cabeça devagar pra quem chega perto
@export var vigil_look_speed: float = 1.5

# Provocação (o que o faz virar caçador)
@export_group("Provocação")
@export var provoke_item_ids: Array[String] = ["livro", "chave_subsolo", "chave_cripta"]
@export var provoke_on_pentagram_pieces: bool = true # Qualquer item_pentagrama* também provoca
@export var auto_provoke_after: float = 0.0      # Segundos após o portão (0 = desligado, só por ação)
@export var rage_duration: float = 25.0          # Tempo furioso logo após ser provocado
@export var rage_speed_multiplier: float = 1.6   # Velocidade extra enquanto furioso

# Caçada (movimentação)
@export_group("Caçada")
@export var hunt_wait_min: float = 0.5           # Pausa curta nos pontos
@export var hunt_wait_max: float = 1.5
@export var hunt_player_bias: float = 0.6        # Chance de ir pra perto de um jogador em vez de ponto aleatório

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
@export var fov_angle_deg: float = 90.0        # Cone de visão total (graus)
@export var max_view_distance: float = 20.0    # Alcance máximo de visão (metros)
@export var eye_height_offset: float = 1.95    # Altura dos olhos para checagem de Raycast
@export var target_chest_height: float = 1.2   # Altura do peito do jogador (1º raycast)
@export var target_head_height: float = 1.6    # Altura da cabeça do jogador (2º raycast)
@export var suspicion_time: float = 3.0        # Tempo parado olhando na direção do barulho
@export var suspicion_turn_speed: float = 3.0  # Velocidade de giro até o barulho
@export var wait_scan_angle_deg: float = 60.0  # Quanto ele gira pra cada lado nos pontos de espera
@export var wait_scan_speed: float = 1.2       # Velocidade do giro nos pontos de espera
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
var _item_signal_connected: bool = false
var _vigil_lamp: Node3D = null
var _vigil_flicker_timer: float = 0.0
var _vigil_elapsed: float = 0.0
var _rage_timer: float = 0.0
var _recent_markers: Array = []

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
var _wait_timer: float = 0.0
var _scan_time: float = 0.0
var _scan_base_yaw: float = 0.0

# Audição / desconfiança
var _suspicion_timer: float = 0.0
var _last_noise_pos: Vector3 = Vector3.ZERO
var _last_noise_msec: int = -1

# Texto de depuração (F3) - preenchido só no servidor
var debug_text: String = ""
var _debug_text_timer: float = 0.0
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

	# Conecta com os eventos de item (para saber quando alguém o provoca)
	_connect_to_item_events()

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

func _connect_to_item_events() -> bool:
	if _item_signal_connected:
		return true
	var nm = get_tree().current_scene
	if nm and nm.has_signal("item_picked_up"):
		if not nm.item_picked_up.is_connected(_on_item_picked_up):
			nm.item_picked_up.connect(_on_item_picked_up)
		_item_signal_connected = true
		print("[FANTASMA] Conectado aos eventos de item.")
		return true
	return false

func _on_item_picked_up(jogador: Node, item_id: String) -> void:
	if not multiplayer.is_server():
		return
	var provoca: bool = provoke_item_ids.has(item_id)
	if provoke_on_pentagram_pieces and item_id.begins_with("item_pentagrama"):
		provoca = true
	if provoca:
		provoke(jogador, "pegou " + item_id)

func _on_gate_slammed() -> void:
	if not multiplayer.is_server():
		return
	if _gate_clock_started:
		return
	_gate_clock_started = true
	print("[FANTASMA] Portão fechou! O fantasma aparece e fica de vigia.")
	_start_vigil()


# ==============================================================================
# TRANSIÇÕES DE FASE
# ==============================================================================

func _start_vigil() -> void:
	current_phase = Phase.PRESENCE
	current_state = State.PATROL
	_vigil_elapsed = 0.0
	_apply_appearance_visibility()

	global_position = _vigil_position()
	rotation.y = PI # Olhando pro sul (lado do portão)
	velocity = Vector3.ZERO
	_vigil_flicker_timer = 1.0
	print("[FANTASMA] VIGIA: parado em %v, perto da luz que pisca." % global_position)

func _vigil_position() -> Vector3:
	# 1) Marcador manual: coloque um Marker3D no grupo "ghost_vigil" onde quiser
	var marker = get_tree().get_first_node_in_group("ghost_vigil")
	if marker is Node3D:
		_vigil_lamp = _nearest_street_light(marker.global_position)
		return marker.global_position + Vector3(0, 0.2, 0)

	# 2) Padrão: ao lado do poste mais próximo da entrada da capela
	var ref: Vector3 = Vector3(0, 0.0, -20.0)
	var chapel = get_tree().get_first_node_in_group("chapel_entrance")
	if chapel is Node3D:
		ref = chapel.global_position
	_vigil_lamp = _nearest_street_light(ref)
	if _vigil_lamp:
		return _vigil_lamp.global_position + vigil_offset
	return Vector3(ref.x, 0.2, ref.z)

func _nearest_street_light(pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group("street_lights"):
		if n is Node3D:
			var d = pos.distance_to(n.global_position)
			if d < best_d:
				best_d = d
				best = n
	return best

# Parado e visível: a luz perto dele pisca, ele só vira a cabeça pra quem chega perto
func _process_vigil(delta: float) -> void:
	velocity = Vector3.ZERO

	_vigil_flicker_timer -= delta
	if _vigil_flicker_timer <= 0.0:
		_vigil_flicker_timer = vigil_flicker_interval + randf_range(-1.0, 1.5)
		if _vigil_lamp and is_instance_valid(_vigil_lamp):
			_flicker_post_briefly.rpc(_vigil_lamp.get_path())

	var closest: Node3D = null
	var min_d: float = vigil_look_distance
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and p is Node3D and p.get("is_dead") != true:
			var d = global_position.distance_to(p.global_position)
			if d < min_d:
				min_d = d
				closest = p
	if closest:
		var dir = closest.global_position - global_position
		dir.y = 0.0
		if dir.length_squared() > 0.01:
			rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), vigil_look_speed * delta)

	if auto_provoke_after > 0.0:
		_vigil_elapsed += delta
		if _vigil_elapsed >= auto_provoke_after:
			provoke(null, "tempo")

# Chamado quando alguém faz algo que o irrita (pegar item de puzzle, abrir a 1ª porta, etc.)
# Pode ser chamado de qualquer script: ghost.provoke(jogador, "abriu a porta")
func provoke(player: Node, reason: String = "") -> void:
	if not multiplayer.is_server():
		return
	if current_phase != Phase.PRESENCE:
		return # Só provoca quem ainda está de vigia

	current_phase = Phase.ACTIVE
	_rage_timer = rage_duration
	_chase_cooldown_timer = 0.0
	_is_waiting_at_point = false
	_recent_markers.clear()
	print("[FANTASMA] PROVOCADO (%s)! Vai atrás de vocês." % reason)

	# Vai direto até onde o culpado está
	if player is Node3D and is_instance_valid(player):
		_last_seen_player_pos = player.global_position
	else:
		var alvo = _random_alive_player()
		_last_seen_player_pos = alvo.global_position if alvo else global_position
	_enter_search()

func _random_alive_player() -> CharacterBody3D:
	var vivos: Array = []
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and p is CharacterBody3D and p.get("is_dead") != true:
			vivos.append(p)
	if vivos.is_empty():
		return null
	return vivos.pick_random()

func _rage_mult() -> float:
	return rage_speed_multiplier if _rage_timer > 0.0 else 1.0


# ==============================================================================
# LOOP PRINCIPAL DA FÍSICA E IA (APENAS SERVIDOR)
# ==============================================================================

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	# Fallback de conexão se o portão não estava pronto no _ready
	if not _gate_clock_started:
		_check_gate_status_fallback()
	if not _item_signal_connected:
		_connect_to_item_events()

	# Antes do portão bater o fantasma não faz nada
	if current_phase == Phase.CALM:
		return

	if _rage_timer > 0.0:
		_rage_timer -= delta

	# Vigia: parado perto da luz piscando, esperando alguém provocá-lo
	if current_phase == Phase.PRESENCE:
		_process_vigil(delta)
		_update_debug_text(delta)
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
		State.SUSPICIOUS:
			_state_suspicious_process(delta)

	_update_debug_text(delta)

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


# --- FASE 0: COMPORTAMENTO SUTIL ---


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
	# Na Fase 2 (Ativa), verifica continuamente se VÊ algum jogador
	if current_phase == Phase.ACTIVE and _chase_cooldown_timer <= 0.0:
		var target = _detect_target_player()
		if target:
			_enter_chase(target)
			return

	if _is_waiting_at_point:
		# Parado no ponto: gira devagar de um lado pro outro olhando ao redor
		velocity = Vector3.ZERO
		_scan_time += delta
		rotation.y = _scan_base_yaw + sin(_scan_time * wait_scan_speed) * deg_to_rad(wait_scan_angle_deg)
		_wait_timer -= delta
		if _wait_timer <= 0.0:
			_is_waiting_at_point = false
			_pick_next_patrol_point()
		return

	# Chegou ao ponto de patrulha atual?
	var dist = global_position.distance_to(nav_agent.target_position)
	if nav_agent.is_navigation_finished() or dist <= 0.8:
		velocity = Vector3.ZERO
		_is_waiting_at_point = true
		_wait_timer = randf_range(hunt_wait_min, hunt_wait_max)
		_scan_time = 0.0
		_scan_base_yaw = rotation.y
		return

	_move_along_path(patrol_speed * _rage_mult(), delta)

func _pick_next_patrol_point() -> void:
	_ensure_patrol_points()
	if _patrol_points.is_empty():
		return

	var candidates: Array = _patrol_points.duplicate()
	# Evita voltar pros últimos pontos visitados (ele não fica rodando no mesmo canto)
	for r in _recent_markers:
		if candidates.size() > 1:
			candidates.erase(r)
	if _current_patrol_marker and candidates.size() > 1:
		candidates.erase(_current_patrol_marker)
	candidates.shuffle()

	# Caçada: muitas vezes vai pra perto de um jogador vivo
	if current_phase == Phase.ACTIVE and randf() < hunt_player_bias:
		var vitima = _random_alive_player()
		if vitima:
			var vpos: Vector3 = vitima.global_position
			candidates.sort_custom(func(a, b) -> bool:
				return (a as Node3D).global_position.distance_to(vpos) < (b as Node3D).global_position.distance_to(vpos)
			)

	# Procura o primeiro candidato que seja comprovadamente alcançável
	for c in candidates:
		if c is Marker3D and _is_target_reachable(c.global_position):
			_set_patrol_marker(c)
			return

	# Fallback caso a checagem rigorosa não encontre
	var fallback = candidates.pick_random() as Marker3D
	if fallback:
		_set_patrol_marker(fallback)

func _set_patrol_marker(m: Marker3D) -> void:
	_current_patrol_marker = m
	nav_agent.target_position = m.global_position
	_is_waiting_at_point = false
	_recent_markers.append(m)
	if _recent_markers.size() > 3:
		_recent_markers.pop_front()

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
	var parado_de_proposito: bool = (current_state == State.SUSPICIOUS) \
		or (current_state == State.SEARCH and _search_spin_timer > 0.0)
	if _is_waiting_at_point or parado_de_proposito:
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
	# A cela é sempre protegida (o jogador preso lá fica seguro)
	var cell_spot = get_tree().get_first_node_in_group("cell_spot")
	if cell_spot and cell_spot is Node3D:
		if player.global_position.distance_to(cell_spot.global_position) < 3.5:
			return true

	# O local de jogador caído só protege enquanto o fantasma está em pausa
	# pós-captura. Depois disso ele pode pegar o jogador de novo.
	if _chase_cooldown_timer > 0.0:
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
	_move_along_path(chase_speed * _rage_mult(), delta)

# ==============================================================================
# ESTADO 4: DESCONFIANÇA (OUVIU UM BARULHO)
# ==============================================================================

# Chamado no servidor por quem faz barulho (corrida, item, etc.)
func hear_noise(pos: Vector3, radius: float) -> void:
	if not multiplayer.is_server():
		return
	if current_phase != Phase.ACTIVE:
		return
	# Já perseguindo ou procurando: ignora, ele já está atento
	if current_state == State.CHASE or current_state == State.SEARCH:
		return
	if _chase_cooldown_timer > 0.0:
		return
	if global_position.distance_to(pos) > radius:
		return

	_last_noise_pos = pos
	_last_noise_msec = Time.get_ticks_msec()
	_suspicion_timer = suspicion_time # barulho repetido reinicia o tempo
	if current_state != State.SUSPICIOUS:
		current_state = State.SUSPICIOUS
		velocity = Vector3.ZERO
		print("[FANTASMA] Ouviu um barulho em %v. Desconfiado!" % pos)

func _state_suspicious_process(delta: float) -> void:
	velocity = Vector3.ZERO

	# Vira devagar na direção do barulho
	var dir = _last_noise_pos - global_position
	dir.y = 0.0
	if dir.length_squared() > 0.01:
		var target_yaw = atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, suspicion_turn_speed * delta)

	# Enquanto olha, a visão normal continua valendo
	var target = _detect_target_player()
	if target:
		_enter_chase(target)
		return

	_suspicion_timer -= delta
	if _suspicion_timer <= 0.0:
		print("[FANTASMA] Não achou ninguém. Voltando à patrulha.")
		current_state = State.PATROL
		# Retoma o caminho atual (não escolhe ponto novo)
		if _is_waiting_at_point:
			_scan_base_yaw = rotation.y
			_scan_time = 0.0

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
		_move_along_path(search_speed * _rage_mult(), delta)
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
# SISTEMA DE PERCEPÇÃO (VISÃO POR CONE + RAYCAST; AUDIÇÃO VIA hear_noise)
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
		# Não persegue se o jogador estiver protegido (cela, ou caído em pausa)
		if _is_player_in_safe_spot(p):
			continue

		if _vision_reason(p) == "enxerga":
			var dist = global_position.distance_to(p.global_position)
			if dist < min_distance:
				min_distance = dist
				closest_player = p

	return closest_player

# Devolve o motivo de ver ou não ver o jogador (usado na visão e no painel F3)
func _vision_reason(p: CharacterBody3D) -> String:
	var dist = global_position.distance_to(p.global_position)
	if dist > max_view_distance:
		return "longe demais"

	var to_player = p.global_position - global_position
	to_player.y = 0.0
	var forward = -transform.basis.z
	forward.y = 0.0
	if to_player.length_squared() > 0.0001 and forward.length_squared() > 0.0001:
		var angle_deg = rad_to_deg(forward.normalized().angle_to(to_player.normalized()))
		if angle_deg > (fov_angle_deg * 0.5):
			return "fora do cone"

	return _line_of_sight_reason(p)

func _has_line_of_sight(player: CharacterBody3D) -> bool:
	return _line_of_sight_reason(player) == "enxerga"

# Dois raycasts (peito e cabeça): basta um chegar até o jogador
func _line_of_sight_reason(player: CharacterBody3D) -> String:
	var space_state = get_world_3d().direct_space_state
	var origin = global_position + Vector3(0, eye_height_offset, 0)
	var blocker: String = ""

	for h in [target_chest_height, target_head_height]:
		var target = player.global_position + Vector3(0, h, 0)
		var query = PhysicsRayQueryParameters3D.create(origin, target)
		query.collision_mask = 1 # Só cenário: muros, construções, lápides, árvores
		query.exclude = [self.get_rid()]

		var result = space_state.intersect_ray(query)
		if result.is_empty() or result.collider == player:
			return "enxerga"
		if blocker == "" and result.collider is Node:
			blocker = str(result.collider.name)

	return "bloqueado por %s" % blocker

# ==============================================================================
# TEXTO DE DEPURAÇÃO (F3) - LIDO PELO player.gd NO HOST
# ==============================================================================

func _state_name() -> String:
	match current_state:
		State.PATROL: return "Patrulha"
		State.CHASE: return "Perseguição"
		State.SEARCH: return "Busca"
		State.SUSPICIOUS: return "Desconfiado"
	return "?"

func _update_debug_text(delta: float) -> void:
	_debug_text_timer -= delta
	if _debug_text_timer > 0.0:
		return
	_debug_text_timer = 0.25

	var fase_nome = ["Calma (antes do portão)", "Vigia (parado, esperando provocação)", "Caçada"][clampi(current_phase, 0, 2)]
	var txt = "Fase: %s\n" % fase_nome
	if _rage_timer > 0.0:
		txt += "FURIOSO por mais %.0f s\n" % _rage_timer
	txt += "Estado: %s\n" % _state_name()
	if _last_noise_msec >= 0:
		txt += "Ouviu barulho há %.1f s\n" % ((Time.get_ticks_msec() - _last_noise_msec) / 1000.0)
	else:
		txt += "Ainda não ouviu barulho\n"

	var closest: CharacterBody3D = null
	var min_d: float = INF
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and p is CharacterBody3D and p.get("is_dead") != true:
			var d = global_position.distance_to(p.global_position)
			if d < min_d:
				min_d = d
				closest = p
	if closest:
		var motivo = "protegido (safe spot)" if _is_player_in_safe_spot(closest) else _vision_reason(closest)
		txt += "Jogador mais próximo (%.1f m): %s" % [min_d, motivo]
	else:
		txt += "Sem jogadores vivos"
	debug_text = txt

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
