extends Node3D

# ==============================================================================
# SCRIPT DE ITEM COLETÁVEL NO MUNDO
# ==============================================================================

signal picked_up(by_player: Node)

@export var item_id: String = "extra"
@export var display_name: String = "Objeto Antigo"
@export var item_color: Color = Color(0.6, 0.6, 0.6, 1.0)

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var interaction_area: Area3D = $InteractionArea
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer

func _enter_tree() -> void:
	# Autoridade sempre do servidor
	set_multiplayer_authority(1)
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(1)

func _ready() -> void:
	add_to_group("items")
	_apply_visual()

func setup_item(p_id: String, p_name: String, p_color: Color) -> void:
	item_id = p_id
	display_name = p_name
	item_color = p_color
	_apply_visual()

func _apply_visual() -> void:
	if not is_inside_tree():
		return
	if mesh_instance:
		var mat = StandardMaterial3D.new()
		mat.albedo_color = item_color
		mat.roughness = 0.5
		# Pequeno brilho sutil para itens especiais
		if item_id.begins_with("item_pentagrama"):
			mat.emission_enabled = true
			mat.emission = item_color
			mat.emission_energy_multiplier = 0.5
		mesh_instance.material_override = mat

# Interação acionada quando o jogador pressiona E olhando para este item
func interact_pickup(player: Node) -> void:
	if not multiplayer.is_server():
		# Se chamado no cliente, avisa o servidor
		rpc_id(1, "server_request_pickup", player.get_path())
		return
	_server_process_pickup(player)

@rpc("any_peer", "call_local", "reliable")
func server_request_pickup(player_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var player = get_node_or_null(player_path)
	if player:
		_server_process_pickup(player)

func _server_process_pickup(player: Node) -> void:
	if player.has_method("server_try_add_item"):
		var added = player.server_try_add_item(item_id, display_name)
		if added:
			picked_up.emit(player)
			# Despacha sinal global no servidor se necessário
			var nm = get_tree().current_scene
			if nm and nm.has_signal("item_picked_up"):
				nm.item_picked_up.emit(player, item_id)
			queue_free()
