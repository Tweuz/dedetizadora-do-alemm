class_name SoundBank
extends RefCounted

# ==============================================================================
# BANCO DE SONS PROCEDURAIS E PLACEHOLDER (EXTENSÍVEL PARA ARQUIVOS .OGG)
# ==============================================================================
# Permite obter sons gerados por código em tempo de execução.
# Se existir um arquivo em "res://audio/<nome>.ogg" (ou .wav), ele será usado
# automaticamente, facilitando a substituição por arquivos finais de áudio.

static var _cached_streams: Dictionary = {}
static var _whisper_pool: Array[AudioStreamWAV] = []

static func get_sound(sound_name: String) -> AudioStream:
	var s_name: String = sound_name.to_lower()

	# Caso especial para sussurros: busca arquivos externos sussurro_N.ogg ou gera proceduralmente
	if s_name.begins_with("sussurro"):
		var ogg_files: Array[String] = []
		for n in range(1, 10):
			var p: String = "res://audio/sussurro_%d.ogg" % n
			if ResourceLoader.exists(p):
				ogg_files.append(p)
		if ResourceLoader.exists("res://audio/sussurro.ogg"):
			ogg_files.append("res://audio/sussurro.ogg")

		if not ogg_files.is_empty():
			var picked_path: String = ogg_files.pick_random()
			return load(picked_path)

		# Fallback procedural: gera um conjunto de sussurros com frequências e tons variados
		if _whisper_pool.is_empty():
			for i in range(4):
				_whisper_pool.append(_create_whisper_sound())
		return _whisper_pool.pick_random()

	# 1. Verifica se já está em cache
	if _cached_streams.has(s_name):
		return _cached_streams[s_name]

	# 2. Verifica se o usuário adicionou um arquivo .ogg ou .wav correspondente
	var ogg_path: String = "res://audio/" + s_name + ".ogg"
	if ResourceLoader.exists(ogg_path):
		var loaded_ogg = load(ogg_path)
		if loaded_ogg:
			_cached_streams[s_name] = loaded_ogg
			return loaded_ogg

	var wav_path: String = "res://audio/" + s_name + ".wav"
	if ResourceLoader.exists(wav_path):
		var loaded_wav = load(wav_path)
		if loaded_wav:
			_cached_streams[s_name] = loaded_wav
			return loaded_wav

	# 3. Gera o áudio proceduralmente por código (placeholder sintetizado)
	var generated: AudioStream = null
	match s_name:
		"rangido":
			generated = _create_creak_sound()
		"pancada":
			generated = _create_slam_sound()
		"folhagem":
			generated = _create_foliage_sound()
		"vento":
			generated = _create_wind_sound()
		_:
			push_warning("[SoundBank] Som não reconhecido: " + sound_name + ". Usando som genérico.")
			generated = _create_slam_sound()

	if generated:
		_cached_streams[s_name] = generated
	return generated

# ==============================================================================
# GERADORES DE ÁUDIO SINTETIZADO (AudioStreamWAV)
# ==============================================================================

# Som de portão enferrujado abrindo: tom metálico grave com variação de frequência e atrito
static func _create_creak_sound() -> AudioStreamWAV:
	var wav = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var duration: float = 3.5
	var num_samples: int = int(22050 * duration)
	var data = PackedByteArray()
	data.resize(num_samples * 2)

	for i in range(num_samples):
		var t: float = float(i) / 22050.0
		var progress: float = t / duration

		# Envelope suave com pequenas variações de pressão
		var env: float = sin(progress * PI) * (0.8 + 0.2 * sin(t * 14.0))

		# Frequência base variando entre 110 Hz e 220 Hz com vibrações metálicas
		var freq: float = 120.0 + 60.0 * sin(t * 2.5) + 30.0 * sin(t * 9.0)
		var phase: float = t * freq * TAU

		# Harmônicos para simular ressonância metálica
		var s1: float = sin(phase)
		var s2: float = 0.5 * sin(phase * 2.01)
		var s3: float = 0.3 * sin(phase * 3.1)
		# Leve atrito de raspagem
		var noise: float = (randf() * 2.0 - 1.0) * 0.15

		var sample_val: float = (s1 + s2 + s3 + noise) * 0.5 * env
		var sample_int: int = int(clamp(sample_val, -1.0, 1.0) * 15000.0)
		data.encode_s16(i * 2, sample_int)

	wav.data = data
	return wav

# Som de pancada do portão batendo: ruído de impacto metálico + baque grave de baixa frequência
static func _create_slam_sound() -> AudioStreamWAV:
	var wav = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var duration: float = 0.6
	var num_samples: int = int(22050 * duration)
	var data = PackedByteArray()
	data.resize(num_samples * 2)

	for i in range(num_samples):
		var t: float = float(i) / 22050.0
		# Decaimento exponencial rápido
		var env_thud: float = exp(-t * 8.0)
		var env_noise: float = exp(-t * 25.0)

		# Baque grave (sub-grave descendo de 90Hz para 45Hz)
		var thud_freq: float = 90.0 * (1.0 - t * 0.8)
		var thud: float = sin(t * thud_freq * TAU) * env_thud

		# Ruído metálico do impacto inicial
		var noise: float = (randf() * 2.0 - 1.0) * env_noise * 0.7

		var sample_val: float = (thud * 0.7 + noise * 0.5)
		var sample_int: int = int(clamp(sample_val, -1.0, 1.0) * 22000.0)
		data.encode_s16(i * 2, sample_int)

	wav.data = data
	return wav

# Som de folhas balançando / farfalhar na árvore
static func _create_foliage_sound() -> AudioStreamWAV:
	var wav = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var duration: float = 1.6
	var num_samples: int = int(22050 * duration)
	var data = PackedByteArray()
	data.resize(num_samples * 2)

	var last_val: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / 22050.0
		# Envelope com subida e descida suave
		var env: float = sin((t / duration) * PI) * (0.7 + 0.3 * sin(t * 12.0))

		# Ruído filtrado passa-baixa simples (suavização temporal)
		var white_noise: float = randf() * 2.0 - 1.0
		last_val = lerp(last_val, white_noise, 0.18)

		var sample_val: float = last_val * env * 0.6
		var sample_int: int = int(clamp(sample_val, -1.0, 1.0) * 14000.0)
		data.encode_s16(i * 2, sample_int)

	wav.data = data
	return wav

# Som contínuo de vento de fundo em loop
static func _create_wind_sound() -> AudioStreamWAV:
	var wav = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	var duration: float = 4.0
	var num_samples: int = int(22050 * duration)
	wav.loop_begin = 0
	wav.loop_end = num_samples
	var data = PackedByteArray()
	data.resize(num_samples * 2)

	var last_val: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / 22050.0

		# Variação lenta de rajada
		var gust: float = 0.4 + 0.3 * sin(t * 1.5) + 0.2 * sin(t * 3.2)
		var white_noise: float = randf() * 2.0 - 1.0
		last_val = lerp(last_val, white_noise, 0.06)

		var sample_val: float = last_val * gust * 0.4
		var sample_int: int = int(clamp(sample_val, -1.0, 1.0) * 10000.0)
		data.encode_s16(i * 2, sample_int)

	wav.data = data
	return wav

# Som de sussurro fantasmagórico: ruído filtrado com formantes vocálicos dinâmicos ("shhh/whhh/ssss")
static func _create_whisper_sound() -> AudioStreamWAV:
	var wav = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var duration: float = randf_range(1.2, 2.4)
	var num_samples: int = int(22050 * duration)
	var data = PackedByteArray()
	data.resize(num_samples * 2)

	# Frequências básicas de formantes da voz sussurrada
	var base_f1: float = randf_range(520.0, 820.0)
	var base_f2: float = randf_range(1600.0, 2300.0)

	var y1_1: float = 0.0
	var y1_2: float = 0.0
	var y2_1: float = 0.0
	var y2_2: float = 0.0

	for i in range(num_samples):
		var t: float = float(i) / 22050.0
		var progress: float = t / duration

		# Envelope orgânico com subida suave e sopros modulados
		var env: float = sin(progress * PI) * (0.65 + 0.35 * sin(progress * PI * 3.5))

		# Ruído branco como fonte de excitação
		var noise: float = randf() * 2.0 - 1.0

		# Variação lenta dos formantes para simular fonemas
		var f1: float = base_f1 + 140.0 * sin(t * 6.0)
		var f2: float = base_f2 + 280.0 * sin(t * 8.5 + 1.2)

		# Filtro ressonador bipolar 1 (formante grave)
		var w1: float = 2.0 * PI * f1 / 22050.0
		var r1: float = 0.93
		var out1: float = noise * (1.0 - r1) + 2.0 * r1 * cos(w1) * y1_1 - r1 * r1 * y1_2
		y1_2 = y1_1
		y1_1 = out1

		# Filtro ressonador bipolar 2 (formante agudo)
		var w2: float = 2.0 * PI * f2 / 22050.0
		var r2: float = 0.94
		var out2: float = noise * (1.0 - r2) + 2.0 * r2 * cos(w2) * y2_1 - r2 * r2 * y2_2
		y2_2 = y2_1
		y2_1 = out2

		var sample_val: float = (out1 * 0.6 + out2 * 0.4) * env * 0.35
		var sample_int: int = int(clamp(sample_val, -1.0, 1.0) * 11000.0)
		data.encode_s16(i * 2, sample_int)

	wav.data = data
	return wav
