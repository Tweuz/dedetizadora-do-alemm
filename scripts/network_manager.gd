extends Node3D

# ==============================================================================
# GERENCIADOR DE REDE E MULTIPLAYER (ENetMultiplayerPeer)
# ==============================================================================

signal item_picked_up(jogador: Node, item_id: String)

# Definições da sala
const PORT: int = 7777
const MAX_PLAYERS: int = 4

# Cenas instanciáveis na rede
@export var player_scene: PackedScene = preload("res://scenes/player.tscn")
@export var ghost_scene: PackedScene = preload("res://scenes/ghost.tscn")
@export var item_pickup_scene: PackedScene = preload("res://scenes/item_pickup.tscn")

# Configurações do Sorteio de Itens
@export_group("Sorteio de Itens")
@export var debug_seed: int = 0 # 0 = aleatório; != 0 para repetir em testes

# Referências aos nós da cena principal
@onready var menu: Control = $UI/Menu
@onready var players_container: Node3D = $Players
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var spawn_points_container: Node3D = (
	get_node_or_null("SpawnPoints") if has_node("SpawnPoints")
	else (get_node_or_null("Abertura/SpawnPoints") if has_node("Abertura/SpawnPoints")
	else (get_node_or_null("Cemiterio/SpawnPoints") if has_node("Cemiterio/SpawnPoints")
	else find_child("SpawnPoints", true, false)))
)

# Variáveis globais de partida
var _next_spawn_index: int = 0
var _my_player_name: String = "Jogador"
var gate_slammed_time: float = -1.0 # Momento (segundos) em que o portão bateu
var _items_already_spawned: bool = false
var _spawned_items_data: Array[Dictionary] = [] # Salva para sincronizar clientes que conectam depois

func _ready() -> void:
	# Conecta os sinais da interface de usuário (menu)
	menu.host_requested.connect(_on_host_requested)
	menu.join_requested.connect(_on_join_requested)

	# Conecta os sinais nativos de multiplayer da Godot
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# Conecta com o portão para detectar o sinal gate_slammed
	_connect_to_gate()

	# Configura o MultiplayerSpawner via código para garantir redundância
	_setup_spawner()

func _connect_to_gate() -> void:
	var gate = get_node_or_null("Cemiterio/Portao")
	if not gate:
		gate = find_child("Portao", true, false)
	if gate and gate.has_signal("gate_slammed"):
		gate.gate_slammed.connect(_on_gate_slammed)

func _on_gate_slammed() -> void:
	gate_slammed_time = Time.get_ticks_msec() / 1000.0
	print("[MULTIPLAYER] Portão bateu em t = %.2f s." % gate_slammed_time)
	rpc_sync_gate_time.rpc(gate_slammed_time)

	# O sorteio roda uma vez por partida, depois que o portão bate, no servidor
	if multiplayer.is_server() and not _items_already_spawned:
		_items_already_spawned = true
		_server_spawn_items()

@rpc("call_local", "reliable")
func rpc_sync_gate_time(t: float) -> void:
	gate_slammed_time = t

func _setup_spawner() -> void:
	spawner.spawn_path = players_container.get_path()
	spawner.clear_spawnable_scenes()
	spawner.add_spawnable_scene("res://scenes/player.tscn")
	spawner.add_spawnable_scene("res://scenes/ghost.tscn")
	spawner.add_spawnable_scene("res://scenes/item_pickup.tscn")

# ==============================================================================
# CRIAÇÃO DE SALA (HOST) E ENTRADA (CLIENT)
# ==============================================================================

func _on_host_requested(p_name: String) -> void:
	_my_player_name = p_name
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(PORT, MAX_PLAYERS)
	
	if error != OK:
		menu.set_status("Erro ao criar o servidor na porta %d (Código: %d). A porta já está em uso?" % [PORT, error])
		return

	multiplayer.multiplayer_peer = peer
	menu.visible = false
	print("[MULTIPLAYER] Servidor criado com sucesso na porta %d. Máximo de %d jogadores." % [PORT, MAX_PLAYERS])

	_spawn_player(1, _my_player_name)
	_spawn_ghost()

func _on_join_requested(ip: String, p_name: String) -> void:
	_my_player_name = p_name
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(ip, PORT)
	
	if error != OK:
		menu.set_status("Erro ao tentar conectar a %s:%d (Código: %d)" % [ip, PORT, error])
		return

	multiplayer.multiplayer_peer = peer
	menu.set_status("Conectando a %s:%d... Aguarde." % [ip, PORT])
	print("[MULTIPLAYER] Tentando conectar ao Host: %s:%d" % [ip, PORT])

# ==============================================================================
# SINAIS DE REDE
# ==============================================================================

func _on_peer_connected(id: int) -> void:
	print("[MULTIPLAYER] Novo peer conectado com ID: ", id)
	if multiplayer.is_server():
		_spawn_player(id)
		# Se os itens já foram gerados, envia o estado do portão e dos itens para o novo cliente
		if gate_slammed_time > 0.0:
			rpc_id(id, "rpc_sync_gate_time", gate_slammed_time)

func _on_peer_disconnected(id: int) -> void:
	print("[MULTIPLAYER] Peer desconectado: ", id)
	if multiplayer.is_server():
		var player_node = players_container.get_node_or_null(str(id))
		if player_node:
			player_node.queue_free()

func _on_connected_to_server() -> void:
	print("[MULTIPLAYER] Conexão bem-sucedida! Meu ID de peer é: ", multiplayer.get_unique_id())
	menu.visible = false
	rpc_id(1, "server_register_player_name", multiplayer.get_unique_id(), _my_player_name)

@rpc("any_peer", "call_local", "reliable")
func server_register_player_name(peer_id: int, p_name: String) -> void:
	if not multiplayer.is_server():
		return
	var player_node = players_container.get_node_or_null(str(peer_id))
	if player_node and player_node.has_method("set_player_name"):
		player_node.set_player_name.rpc(p_name)

func _on_connection_failed() -> void:
	print("[MULTIPLAYER] Falha ao conectar ao servidor.")
	multiplayer.multiplayer_peer = null
	menu.visible = true
	menu.set_status("Falha na conexão! Verifique se o Host está rodando e se o IP está correto.")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_server_disconnected() -> void:
	print("[MULTIPLAYER] O servidor foi desconectado.")
	multiplayer.multiplayer_peer = null
	
	for child in players_container.get_children():
		child.queue_free()
		
	menu.visible = true
	menu.set_status("A conexão com o servidor foi encerrada.")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ==============================================================================
# SPAWN DE PERSONAGENS E FANTASMA
# ==============================================================================

func _spawn_player(id: int, initial_name: String = "Jogador") -> void:
	if players_container.has_node(str(id)):
		return

	var player = player_scene.instantiate()
	player.name = str(id)
	player.player_name = initial_name
	
	if not spawn_points_container:
		spawn_points_container = (
			get_node_or_null("SpawnPoints") if has_node("SpawnPoints")
			else (get_node_or_null("Abertura/SpawnPoints") if has_node("Abertura/SpawnPoints")
			else (get_node_or_null("Cemiterio/SpawnPoints") if has_node("Cemiterio/SpawnPoints")
			else find_child("SpawnPoints", true, false)))
		)

	var spawn_pos: Vector3 = Vector3(0, 0.5, 85.0)
	if spawn_points_container and spawn_points_container.get_child_count() > 0:
		var points = spawn_points_container.get_children()
		var selected_marker = points[_next_spawn_index % points.size()] as Node3D
		spawn_pos = selected_marker.global_position
		_next_spawn_index += 1
	else:
		spawn_pos = Vector3(randf_range(-1.5, 1.5), 0.5, randf_range(84.0, 86.0))

	player.position = spawn_pos
	players_container.add_child(player, true)
	print("[MULTIPLAYER] Jogador instanciado com sucesso para o peer: %d na posição %v" % [id, spawn_pos])

func _spawn_ghost() -> void:
	if players_container.has_node("Ghost"):
		return

	var ghost = ghost_scene.instantiate()
	ghost.name = "Ghost"
	players_container.add_child(ghost, true)
	print("[MULTIPLAYER] Fantasma instanciado no servidor com sucesso.")

# ==============================================================================
# SORTEIO E SPAWN DE ITENS NO CEMITÉRIO (EXCLUSIVO DO SERVIDOR)
# ==============================================================================

func _server_spawn_items() -> void:
	if debug_seed != 0:
		seed(debug_seed)
		print("[ITENS] Semente de depuração ativa: %d" % debug_seed)

	# 1. Agrupa os Marker3D válidos do grupo "item_spawn" por região (excluindo subsolo)
	var all_spawns = get_tree().get_nodes_in_group("item_spawn")
	var valid_spawns: Array[Marker3D] = []

	var chapel_points: Array[Marker3D] = []
	var crypt_points: Array[Marker3D] = []
	var old_graves_points: Array[Marker3D] = []
	var gravedigger_points: Array[Marker3D] = []
	var shed_points: Array[Marker3D] = []
	var new_graves_points: Array[Marker3D] = []

	for s in all_spawns:
		if not (s is Marker3D):
			continue
		# Regra: Nenhum item nasce dentro do subsolo (Z <= -20 com Y < -1.0)
		if s.name.begins_with("Item_Basement") or s.global_position.y < -1.0:
			continue

		valid_spawns.append(s)
		var sname = s.name
		if sname.begins_with("Item_Chapel"):
			chapel_points.append(s)
		elif sname.begins_with("Item_Crypt"):
			crypt_points.append(s)
		elif sname.begins_with("Item_OldGraves"):
			old_graves_points.append(s)
		elif sname.begins_with("Item_Gravedigger"):
			gravedigger_points.append(s)
		elif sname.begins_with("Item_Shed"):
			shed_points.append(s)
		elif sname.begins_with("Item_NewGraves"):
			new_graves_points.append(s)

	var used_markers: Array[Marker3D] = []
	var chosen_positions: Array[Vector3] = []

	# Função auxiliar para selecionar um ponto respeitando distância mínima de 5 metros
	var pick_marker_func = func(pool: Array[Marker3D], require_dist: bool = true) -> Marker3D:
		var shuffled = pool.duplicate()
		shuffled.shuffle()
		for candidate in shuffled:
			if used_markers.has(candidate):
				continue
			var pos = candidate.global_position
			var too_close = false
			if require_dist:
				for existing_pos in chosen_positions:
					if pos.distance_to(existing_pos) < 5.0:
						too_close = true
						break
			if not too_close:
				used_markers.append(candidate)
				chosen_positions.append(pos)
				return candidate
		# Se não encontrar com 5m, relaxa a distância se o pool tiver candidatos não usados
		for candidate in shuffled:
			if not used_markers.has(candidate):
				used_markers.append(candidate)
				chosen_positions.append(candidate.global_position)
				return candidate
		return null

	print("\n========== [SORTEIO DE ITENS NO CEMITÉRIO] ==========")

	# 1. Livro: capela, cripta ou túmulos antigos
	var pool_livro: Array[Marker3D] = chapel_points + crypt_points + old_graves_points
	var marker_livro = pick_marker_func.call(pool_livro)
	_spawn_item_at_marker("livro", "Livro Antigo", Color(0.85, 0.45, 0.1), marker_livro)

	# 2. Chave Subsolo: capela, cripta ou túmulos antigos (nunca no mesmo ponto do livro)
	var marker_chave_sub = pick_marker_func.call(pool_livro)
	_spawn_item_at_marker("chave_subsolo", "Chave do Subsolo", Color(0.2, 0.8, 0.9), marker_chave_sub)

	# 3. Chave Cripta: casa do coveiro, galpão ou túmulos novos
	var pool_chave_cripta: Array[Marker3D] = gravedigger_points + shed_points + new_graves_points
	var marker_chave_cripta = pick_marker_func.call(pool_chave_cripta)
	_spawn_item_at_marker("chave_cripta", "Chave da Cripta", Color(0.9, 0.85, 0.1), marker_chave_cripta)

	# 4. Arma: casa do coveiro ou galpão
	var pool_arma: Array[Marker3D] = gravedigger_points + shed_points
	var marker_arma = pick_marker_func.call(pool_arma)
	_spawn_item_at_marker("arma", "Revólver Velho", Color(0.15, 0.15, 0.2), marker_arma)

	# 5. Itens do Pentagrama (1 a 5) em pontos espalhados
	for i in range(1, 6):
		var item_id = "item_pentagrama_%d" % i
		var display_name = "Relíquia %d" % i
		var p_color = Color(0.9, 0.1, 0.3)
		var marker_pent = pick_marker_func.call(valid_spawns)
		_spawn_item_at_marker(item_id, display_name, p_color, marker_pent)

	# 6. Balas (6 unidades) em pontos aleatórios
	for i in range(6):
		var marker_bala = pick_marker_func.call(valid_spawns)
		_spawn_item_at_marker("bala", "Munição", Color(0.95, 0.7, 0.1), marker_bala)

	# 7. Seringas (3 unidades - cubo verde claro)
	for i in range(3):
		var marker_seringa = pick_marker_func.call(valid_spawns)
		_spawn_item_at_marker("seringa", "Seringa", Color(0.4, 0.95, 0.5), marker_seringa)

	# 8. Extras (10 cubos cinza)
	for i in range(10):
		var marker_extra = pick_marker_func.call(valid_spawns)
		_spawn_item_at_marker("extra", "Objeto Quebrado", Color(0.5, 0.5, 0.5), marker_extra)

	print("=====================================================\n")

func _spawn_item_at_marker(item_id: String, display_name: String, color: Color, marker: Marker3D) -> void:
	if not marker:
		push_warning("[ITENS] Não foi possível encontrar ponto para o item: " + item_id)
		return

	var pos = marker.global_position
	spawn_item_in_world(item_id, display_name, pos, color)
	print("  • Item '%s' [%s] -> Marcador '%s' em %v" % [item_id, display_name, marker.name, pos])

# Chamado tanto no sorteio inicial quanto quando um jogador solta um item (tecla G)
func spawn_item_in_world(item_id: String, display_name: String, pos: Vector3, custom_color: Color = Color.WHITE) -> Node:
	if not multiplayer.is_server():
		return null

	var item = item_pickup_scene.instantiate()
	var final_color = custom_color
	if final_color == Color.WHITE:
		# Cores padrão por tipo de item
		match item_id:
			"livro": final_color = Color(0.85, 0.45, 0.1)
			"chave_subsolo": final_color = Color(0.2, 0.8, 0.9)
			"chave_cripta": final_color = Color(0.9, 0.85, 0.1)
			"arma": final_color = Color(0.15, 0.15, 0.2)
			"bala": final_color = Color(0.95, 0.7, 0.1)
			"seringa": final_color = Color(0.4, 0.95, 0.5)
			_:
				if item_id.begins_with("item_pentagrama"):
					final_color = Color(0.9, 0.1, 0.3)
				else:
					final_color = Color(0.5, 0.5, 0.5)

	item.item_id = item_id
	item.display_name = display_name
	item.item_color = final_color
	item.position = pos

	players_container.add_child(item, true)
	return item
