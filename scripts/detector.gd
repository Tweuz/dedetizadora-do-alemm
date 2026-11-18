extends Node3D

# ==============================================================================
# SCRIPT DO DETECTOR DE FANTASMA (ESTILO CONTADOR GEIGER POR SOM E LED)
# ==============================================================================

# Cores da luz indicadora (LED)
const COLOR_OFF: Color = Color(0.08, 0.08, 0.08)
const COLOR_GREEN: Color = Color(0.1, 0.95, 0.15)  # Verde: Longe
const COLOR_YELLOW: Color = Color(1.0, 0.85, 0.1)  # Amarelo: Médio
const COLOR_RED: Color = Color(1.0, 0.15, 0.15)    # Vermelho: Perto

# Estado do detector
var is_active: bool = false
var time_until_next_beep: float = 0.0
var target_led_color: Color = COLOR_OFF

# Material próprio do LED para permitir mudança dinâmica de cor e emissão
var led_material: StandardMaterial3D

# Referências aos nós
@onready var led_mesh: MeshInstance3D = $LedLight
@onready var audio_player: AudioStreamPlayer3D = $AudioStreamPlayer3D

func _ready() -> void:
	# Cria uma instância exclusiva de material para o LED deste jogador
	led_material = StandardMaterial3D.new()
	led_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	led_material.roughness = 0.2
	led_material.emission_enabled = true
	led_material.emission_energy_multiplier = 0.0
	led_mesh.material_override = led_material

	# Gera procedimentalmente o áudio do bip (contador Geiger)
	audio_player.stream = _create_beep_stream()

	# Inicia recolhido / desligado
	set_active(false)

func _process(delta: float) -> void:
	# O cálculo de proximidade e os bips só ocorrem no jogador local com o detector ativo
	if not is_active:
		return

	# Suaviza a intensidade da emissão do LED (efeito de pulsar quando bipa)
	led_material.emission_energy_multiplier = lerp(led_material.emission_energy_multiplier, 2.0, 12.0 * delta)

	# Localiza o fantasma no grupo "ghost"
	var ghost = get_tree().get_first_node_in_group("ghost") as Node3D
	
	if not ghost or not is_instance_valid(ghost):
		# Sem fantasma na cena: sem bip e LED verde padrão
		_update_led(COLOR_GREEN, false)
		time_until_next_beep = 0.0
		return

	# Distância calculada localmente através da posição sincronizada do fantasma
	var distance: float = global_position.distance_to(ghost.global_position)

	# Se a distância for maior que 15 metros: SEM BIP e LED verde
	if distance > 15.0:
		_update_led(COLOR_GREEN, true)
		time_until_next_beep = 0.0
		return

	# Normaliza a distância entre 2m e 15m (t = 0.0 a 15m; t = 1.0 a <= 2m)
	var t: float = clamp((15.0 - distance) / (15.0 - 2.0), 0.0, 1.0)

	# Atualiza a cor do LED de acordo com a proximidade:
	# Verde longe (> 10m), Amarelo médio (5m a 10m), Vermelho perto (<= 5m)
	if distance > 10.0:
		_update_led(COLOR_GREEN, true)
	elif distance > 5.0:
		_update_led(COLOR_YELLOW, true)
	else:
		_update_led(COLOR_RED, true)

	# Gerenciamento dos bips estilo contador Geiger:
	# Intervalo: 2.0s a 15m até 0.1s a 2m (ou menos)
	# Tom (pitch): 1.0 (grave/padrão) a 15m até 1.55 (mais agudo) a 2m
	var beep_interval: float = lerp(2.0, 0.1, t)
	var beep_pitch: float = lerp(1.0, 1.55, t)

	time_until_next_beep -= delta
	if time_until_next_beep <= 0.0:
		# Toca o bip
		audio_player.pitch_scale = beep_pitch
		audio_player.play()
		
		# Pulso de brilho visual no LED junto ao som do bip
		led_material.emission_energy_multiplier = 4.5
		
		# Reinicia a contagem regressiva para o próximo bip
		time_until_next_beep = beep_interval

# Alterna entre ligado e desligado (chamado quando o jogador pressiona Q)
func toggle_active() -> void:
	set_active(not is_active)

func set_active(active: bool) -> void:
	is_active = active
	visible = is_active

	if not is_active:
		time_until_next_beep = 0.0
		_update_led(COLOR_OFF, false)
		if audio_player:
			audio_player.stop()

# Atualiza a cor e o brilho do LED
func _update_led(color: Color, is_lit: bool) -> void:
	if not led_material:
		return
		
	led_material.albedo_color = color
	led_material.emission = color
	if not is_lit:
		led_material.emission_energy_multiplier = 0.0

# Gera proceduralmente um clique/bip curto de 35ms sem estalo de áudio
func _create_beep_stream() -> AudioStreamWAV:
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var num_samples: int = int(22050 * 0.035) # ~35 milissegundos
	var data: PackedByteArray = PackedByteArray()
	data.resize(num_samples * 2)

	for i in range(num_samples):
		var t: float = float(i) / 22050.0
		# Envelope exponencial rápido para gerar o 'tick/clique' característico de contador Geiger
		var envelope: float = exp(-float(i) / (float(num_samples) * 0.35))
		var sample: int = int(sin(t * 900.0 * TAU) * 14000.0 * envelope)
		data.encode_s16(i * 2, sample)

	wav.data = data
	return wav
