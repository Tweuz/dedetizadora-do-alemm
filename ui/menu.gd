extends Control

# ==============================================================================
# MENU PRINCIPAL DE MULTIPLAYER
# ==============================================================================

# Sinais emitidos quando o usuário clica nos botões do menu
signal host_requested
signal join_requested(ip: String)

# Referências aos elementos visuais da interface
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

func _on_host_pressed() -> void:
	set_status("Iniciando servidor (Host)...")
	host_requested.emit()

func _on_join_pressed() -> void:
	var ip: String = ip_line_edit.text.strip_edges()
	# Se o campo estiver vazio, utiliza o IP local padrão (localhost)
	if ip.is_empty():
		ip = "127.0.0.1"
	
	set_status("Tentando conectar a " + ip + "...")
	join_requested.emit(ip)

# Atualiza a mensagem de status exibida para o usuário
func set_status(text: String) -> void:
	if status_label:
		status_label.text = text
