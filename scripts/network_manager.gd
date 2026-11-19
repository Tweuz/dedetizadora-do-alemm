extends Node3D

# ==============================================================================
# GERENCIADOR DE REDE E MULTIPLAYER (ENetMultiplayerPeer)
# ==============================================================================

# Definições da sala
const PORT: int = 7777
const MAX_PLAYERS: int = 4

# Cenas instanciáveis na rede
@export var player_scene: PackedScene = preload("res://scenes/player.tscn")
@export var ghost_scene: PackedScene = preload("res://scenes/ghost.tscn")

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

# Índice sequencial para distribuir novos jogadores em pontos de spawn diferentes
var _next_spawn_index: int = 0

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

	# Configura o MultiplayerSpawner via código para garantir redundância
	_setup_spawner()

func _setup_spawner() -> void:
	# Define o nó onde os jogadores e o fantasma serão adicionados
	spawner.spawn_path = players_container.get_path()
	# Registra as cenas permitidas para replicação de spawn na rede
	spawner.clear_spawnable_scenes()
	spawner.add_spawnable_scene("res://scenes/player.tscn")
	spawner.add_spawnable_scene("res://scenes/ghost.tscn")

# ==============================================================================
# CRIAÇÃO DE SALA (HOST) E ENTRADA (CLIENT)
# ==============================================================================

func _on_host_requested() -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(PORT, MAX_PLAYERS)
	
	if error != OK:
		menu.set_status("Erro ao criar o servidor na porta %d (Código: %d). A porta já está em uso?" % [PORT, error])
		return

	# Atribui o peer criado à árvore de multiplayer da Godot
	multiplayer.multiplayer_peer = peer
	
	# Oculta o menu para o host começar a jogar
	menu.visible = false
	print("[MULTIPLAYER] Servidor criado com sucesso na porta %d. Máximo de %d jogadores." % [PORT, MAX_PLAYERS])

	# O Host sempre possui o Peer ID = 1. Spawna o personagem do Host imediatamente.
	_spawn_player(1)

	# Spawna o fantasma no servidor (o MultiplayerSpawner replica automaticamente para os clientes)
	_spawn_ghost()

func _on_join_requested(ip: String) -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(ip, PORT)
	
	if error != OK:
		menu.set_status("Erro ao tentar conectar a %s:%d (Código: %d)" % [ip, PORT, error])
		return

	multiplayer.multiplayer_peer = peer
	menu.set_status("Conectando a %s:%d... Aguarde." % [ip, PORT])
	print("[MULTIPLAYER] Tentando conectar ao Host: %s:%d" % [ip, PORT])

# ==============================================================================
# SINAIS DE REDE (GODOT MULTIPLAYER API)
# ==============================================================================

# Executado no servidor quando um novo jogador (peer) conecta no jogo
func _on_peer_connected(id: int) -> void:
	print("[MULTIPLAYER] Novo peer conectado com ID: ", id)
	
	# Apenas o servidor tem permissão de instanciar novos nós no MultiplayerSpawner!
	# O MultiplayerSpawner automaticamente replicará esse nó em todos os clientes conectados.
	if multiplayer.is_server():
		_spawn_player(id)

# Executado quando um jogador desconecta
func _on_peer_disconnected(id: int) -> void:
	print("[MULTIPLAYER] Peer desconectado: ", id)
	
	if multiplayer.is_server():
		var player_node = players_container.get_node_or_null(str(id))
		if player_node:
			# Ao remover o nó no servidor, o MultiplayerSpawner replica a exclusão para todos os clientes
			player_node.queue_free()

# Executado no cliente quando a conexão com o host é finalizada com sucesso
func _on_connected_to_server() -> void:
	print("[MULTIPLAYER] Conexão bem-sucedida! Meu ID de peer é: ", multiplayer.get_unique_id())
	# Oculta a interface de menu para o cliente jogar
	menu.visible = false

# Executado no cliente caso a tentativa de conexão falhe (ex: IP incorreto, porta fechada)
func _on_connection_failed() -> void:
	print("[MULTIPLAYER] Falha ao conectar ao servidor.")
	multiplayer.multiplayer_peer = null
	menu.visible = true
	menu.set_status("Falha na conexão! Verifique se o Host está rodando e se o IP está correto.")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# Executado no cliente se o servidor for fechado ou a conexão cair
func _on_server_disconnected() -> void:
	print("[MULTIPLAYER] O servidor foi desconectado.")
	multiplayer.multiplayer_peer = null
	
	# Remove os jogadores da cena local
	for child in players_container.get_children():
		child.queue_free()
		
	menu.visible = true
	menu.set_status("A conexão com o servidor foi encerrada.")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ==============================================================================
# SPAWN DE PERSONAGENS E FANTASMA (EXECUTADO EXCLUSIVAMENTE PELO SERVIDOR)
# ==============================================================================

func _spawn_player(id: int) -> void:
	# Evita criar duplicatas se o nó com o ID já existir
	if players_container.has_node(str(id)):
		return

	var player = player_scene.instantiate()
	
	# Define o nome do nó exatamente como a string do ID (ex: "1", "24981273")
	player.name = str(id)
	
	# Posiciona o jogador em um dos Marker3D de spawn da abertura (em frente à van)
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
		# Fallback com pequeno deslocamento aleatório caso não haja marcadores
		spawn_pos = Vector3(randf_range(-1.5, 1.5), 0.5, randf_range(84.0, 86.0))

	player.position = spawn_pos

	# O segundo argumento `true` (force_readable_name) é essencial na Godot 4:
	# Ele impede que a engine renomeie o nó para algo como @CharacterBody3D@2,
	# mantendo o nome rigorosamente idêntico em todos os clientes conectados.
	players_container.add_child(player, true)
	print("[MULTIPLAYER] Jogador instanciado com sucesso para o peer: %d na posição %v" % [id, spawn_pos])

func _spawn_ghost() -> void:
	if players_container.has_node("Ghost"):
		return

	var ghost = ghost_scene.instantiate()
	ghost.name = "Ghost"
	players_container.add_child(ghost, true)
	print("[MULTIPLAYER] Fantasma instanciado no servidor com sucesso.")
