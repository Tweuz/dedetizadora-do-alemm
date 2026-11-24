extends Control

# ==============================================================================
# MENU PRINCIPAL DE MULTIPLAYER
# ==============================================================================

# Sinais emitidos quando o usuário clica nos botões do menu
signal host_requested(player_name: String)
signal join_requested(ip: String, player_name: String)

# Referências aos elementos visuais da interface
@onready var name_line_edit: LineEdit = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/NameContainer/NameLineEdit
@onready var host_button: Button = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/HostButton
@onready var join_button: Button = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/JoinContainer/JoinButton
@onready var ip_line_edit: LineEdit = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/JoinContainer/IpLineEdit
@onready var status_label: Label = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/StatusLabel

func _ready() -> void:
	# Conecta os eventos de clique dos botões aos métodos deste script
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	
	# Permite que o jogador pressione Enter no campo de texto para conectar diretamente
	ip_line_edit.text_submitted.connect(func(_text: String) -> void: _on_join_pressed())

func get_player_name() -> String:
	if name_line_edit:
		var n = name_line_edit.text.strip_edges()
		if not n.is_empty():
			return n
	return "Jogador"

func _on_host_pressed() -> void:
	var p_name = get_player_name()
	set_status("Iniciando servidor (Host)...")
	host_requested.emit(p_name)

func _on_join_pressed() -> void:
	var ip: String = ip_line_edit.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	
	var p_name = get_player_name()
	set_status("Tentando conectar a " + ip + " como " + p_name + "...")
	join_requested.emit(ip, p_name)

# Atualiza a mensagem de status exibida para o usuário
func set_status(text: String) -> void:
	if status_label:
		status_label.text = text
