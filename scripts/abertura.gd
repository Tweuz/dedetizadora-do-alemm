extends Node3D

# ==============================================================================
# CENA DE ABERTURA - ESTRADA DE TERRA E FLORESTA EXTERNA AO CEMITÉRIO
# ==============================================================================

const SoundBank = preload("res://scripts/sound_bank.gd")

# Frases editáveis para as placas ao longo da estrada
@export var sign_phrases: Array[String] = [
	"NÃO ENTRE",
	"PROPRIEDADE AMALDIÇOADA",
	"ELES ESTÃO OLHANDO",
	"VOLTE ENQUANTO PODE",
	"O PORTÃO NÃO SE ABRE DE DENTRO",
	"NENHUMA ALMA ESCAPA",
	"TERRENO SAGRADO DOS MORTOS",
	"ÚLTIMO AVISO"
]

@onready var wind_player: AudioStreamPlayer = $WindAudioPlayer
@onready var signs_container: Node3D = $Signs

func _ready() -> void:
	# Inicializa as frases nas placas da estrada
	_setup_signs()

	# Inicia o som de vento contínuo em loop
	if wind_player:
		wind_player.stream = SoundBank.get_sound("vento")
		wind_player.volume_db = -6.0
		wind_player.play()

func _setup_signs() -> void:
	if not signs_container:
		return

	var sign_nodes = signs_container.get_children()
	for i in range(sign_nodes.size()):
		var sign_node = sign_nodes[i]
		if i < sign_phrases.size():
			if "text" in sign_node:
				sign_node.text = sign_phrases[i]
