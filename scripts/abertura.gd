extends Node3D

# ==============================================================================
# CENA DE ABERTURA - ESTRADA DE TERRA, FLORESTA DENSA, OLHOS E LIMITES
# ==============================================================================

const SoundBank = preload("res://scripts/sound_bank.gd")

# 1. Configurações das Placas de Aviso
@export var sign_phrases: Array[String] = [
	"NÃO ENTRE",
	"PROPRIEDADE AMALDIÇOADA",
	"ELES ESTÃO OLHANDO",
	"VOLTE ENQUANTO PODE",
	"O PORTÃO NÃO SE ABRE DE DENTRO",
	"NENHUMA ALMA ESCAPA",
	"TERRENO SAGRADO DOS MORTOS",
	"ÚLTIMO AVISO",
	"NÃO OLHE PRA TRÁS",
	"ELE JÁ SABE SEU NOME",
	"SÓ OS MORTOS PASSAM",
	"FUJA",
	"VOCÊ FOI AVISADO",
	"AQUI FICAM OS ESQUECIDOS",
	"NÃO EXISTE SAÍDA",
	"CALE-SE"
]

# 2. Configurações de Olhos Aleatórios na Floresta
@export var eyes_min_interval: float = 2.0        # segundos mínimos entre eventos
@export var eyes_max_interval: float = 6.0        # segundos máximos entre eventos
@export var eyes_fov_half_deg: float = 60.0       # metade do campo de visão aceito (graus)
@export var eyes_min_distance: float = 8.0        # distância mínima da câmera
@export var eyes_max_distance: float = 28.0       # distância máxima da câmera
@export var eyes_forest_depth_min: float = 1.0    # metros dentro da floresta (mínimo)
@export var eyes_forest_depth_max: float = 6.0    # metros dentro da floresta (máximo)
@export var eyes_height_min: float = 1.0          # altura mínima dos olhos
@export var eyes_height_max: float = 5.0          # altura máxima dos olhos
@export var double_eyes_chance: float = 0.30      # chance de segundo par de olhos
@export var whisper_chance: float = 0.40          # chance de tocar sussurro junto
@export var eyes_scare_distance: float = 12.0     # distância de susto (< N m + direto)
@export var eyes_scare_angle_deg: float = 15.0    # ângulo de susto (olhar direto)

# 3. Referências aos nós filhos
@onready var wind_player: AudioStreamPlayer = $WindAudioPlayer
@onready var signs_container: Node3D = $Signs
@onready var spawn_points_container: Node3D = $SpawnPoints
@onready var void_area: Area3D = $VoidSafetyArea
@onready var eyes_container: Node3D = $EyesContainer  # nó pai dos pares de olhos gerados

# MultiMeshInstances para a floresta densa (desempenho otimizado)
@onready var mm_straight: MultiMeshInstance3D = $Forest/MultiMeshStraight
@onready var mm_crooked: MultiMeshInstance3D = $Forest/MultiMeshCrooked
@onready var mm_curved: MultiMeshInstance3D = $Forest/MultiMeshCurved

# Estado interno dos olhos ativos (para evitar pontos muito próximos)
var _active_eye_positions: Array[Vector3] = []

func _ready() -> void:
	# 1. Gera a floresta densa otimizada nos MultiMeshInstances
	_build_dense_forest()

	# 2. Configura as placas de aviso ao longo da estrada e na floresta
	_setup_signs()

	# 3. Inicia o som de vento contínuo em loop
	if wind_player:
		wind_player.stream = SoundBank.get_sound("vento")
		wind_player.volume_db = -6.0
		wind_player.play()

	# 4. Conecta a rede de segurança da área de queda
	if void_area:
		void_area.body_entered.connect(_on_void_area_body_entered)

	# 5. Inicia o novo sistema de olhos aleatórios na floresta (local)
	_run_eyes_loop()

# ==============================================================================
# REDE DE SEGURANÇA (TELEPORTE MULTIPLAYER CASO CAIA ABAIXO DE Y = -15)
# ==============================================================================

func _physics_process(_delta: float) -> void:
	# Somente o servidor executa a verificação e coordena o teleporte seguro
	if not multiplayer.is_server():
		return

	var players = get_tree().get_nodes_in_group("players")
	for p in players:
		if is_instance_valid(p) and p is CharacterBody3D:
			if p.global_position.y < -15.0:
				_teleport_player_to_safety(p)

func _on_void_area_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body.is_in_group("players") and body is CharacterBody3D:
		_teleport_player_to_safety(body)

func _teleport_player_to_safety(player: CharacterBody3D) -> void:
	var safe_pos = Vector3(0, 0.5, 85.0)
	if spawn_points_container and spawn_points_container.get_child_count() > 0:
		var pts = spawn_points_container.get_children()
		var picked = pts.pick_random() as Node3D
		if picked:
			safe_pos = picked.global_position

	print("[SEGURANÇA] Jogador caiu no vazio! Teleportando para posição segura: ", safe_pos)
	if player.has_method("rpc_teleport"):
		player.rpc_teleport.rpc(safe_pos)
	else:
		player.global_position = safe_pos

# ==============================================================================
# FLORESTA DENSA PROCEDURAL (3 TIPOS DE ÁRVORE EM MULTIMESHINSTANCE3D)
# ==============================================================================

func _build_dense_forest() -> void:
	if not mm_straight or not mm_crooked or not mm_curved:
		return

	# Materiais escuros e fantasmagóricos da casca e copa
	var mat_bark = StandardMaterial3D.new()
	mat_bark.albedo_color = Color(0.09, 0.07, 0.05, 1.0)
	mat_bark.roughness = 0.95

	var mat_foliage = StandardMaterial3D.new()
	mat_foliage.albedo_color = Color(0.03, 0.05, 0.03, 1.0)
	mat_foliage.roughness = 0.95

	# Tipo A: Tronco reto e alto
	var mesh_a = _create_straight_tree_mesh(mat_bark, mat_foliage)
	# Tipo B: Tronco torto, inclinado de 8 a 25 graus
	var mesh_b = _create_crooked_tree_mesh(mat_bark, mat_foliage)
	# Tipo C: Tronco com curva (dois segmentos em ângulo) com galhos secos finos
	var mesh_c = _create_curved_tree_mesh(mat_bark, mat_foliage)

	# Listas de matrizes de transformação para cada tipo
	var straight_xforms: Array[Transform3D] = []
	var crooked_xforms: Array[Transform3D] = []
	var curved_xforms: Array[Transform3D] = []

	# Usa semente determinística para consistência perfeita em multiplayer
	seed(777123)

	# 1. Floresta Oeste: 4 fileiras de X = -6.4 até X = -16.0, Z = 35.0 a 93.0
	var west_rows = [-6.4, -9.2, -12.4, -15.8]
	for r_x in west_rows:
		var z: float = 35.0
		while z <= 93.0:
			var pos = Vector3(r_x + randf_range(-0.35, 0.35), 0.0, z + randf_range(-0.35, 0.35))
			_categorize_tree_transform(pos, straight_xforms, crooked_xforms, curved_xforms)
			z += randf_range(1.7, 2.5)

	# 2. Floresta Leste: 4 fileiras de X = 6.4 até X = 16.0, Z = 35.0 a 93.0
	var east_rows = [6.4, 9.2, 12.4, 15.8]
	for r_x in east_rows:
		var z: float = 35.0
		while z <= 93.0:
			var pos = Vector3(r_x + randf_range(-0.35, 0.35), 0.0, z + randf_range(-0.35, 0.35))
			_categorize_tree_transform(pos, straight_xforms, crooked_xforms, curved_xforms)
			z += randf_range(1.7, 2.5)

	# 3. Floresta Sul (fundo atrás da van fechando o mapa): X = -16.0 a 16.0, Z = 94.0 a 103.0
	var south_rows = [94.0, 97.5, 101.5]
	for r_z in south_rows:
		var x: float = -16.0
		while x <= 16.0:
			var pos = Vector3(x + randf_range(-0.35, 0.35), 0.0, r_z + randf_range(-0.35, 0.35))
			_categorize_tree_transform(pos, straight_xforms, crooked_xforms, curved_xforms)
			x += randf_range(1.8, 2.6)

	# Restaura a semente aleatória para o gameplay
	randomize()

	# Aplica nos MultiMeshInstances
	_setup_multimesh(mm_straight, mesh_a, straight_xforms)
	_setup_multimesh(mm_crooked, mesh_b, crooked_xforms)
	_setup_multimesh(mm_curved, mesh_c, curved_xforms)
	print("[FLORESTA] MultiMesh populado: %d Retas, %d Tortas, %d Curvas. Total: %d árvores." % [
		straight_xforms.size(), crooked_xforms.size(), curved_xforms.size(),
		straight_xforms.size() + crooked_xforms.size() + curved_xforms.size()
	])

func _categorize_tree_transform(pos: Vector3, list_a: Array[Transform3D], list_b: Array[Transform3D], list_c: Array[Transform3D]) -> void:
	# Rotação aleatória de Yaw e escala de altura/espessura
	var yaw = randf() * TAU
	var s_xz = randf_range(0.85, 1.25)
	var s_y = randf_range(0.85, 1.35)
	var tree_basis = Basis(Vector3.UP, yaw).scaled(Vector3(s_xz, s_y, s_xz))
	var xf = Transform3D(tree_basis, pos)

	# Proporção: ~55% retas, ~25% tortas, ~20% curvas com galhos secos
	var roll = randf()
	if roll < 0.55:
		list_a.append(xf)
	elif roll < 0.80:
		list_b.append(xf)
	else:
		list_c.append(xf)

func _setup_multimesh(mmi: MultiMeshInstance3D, mesh: Mesh, xforms: Array[Transform3D]) -> void:
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
	mmi.multimesh = mm

func _create_straight_tree_mesh(mat_bark: Material, mat_foliage: Material) -> Mesh:
	var st = SurfaceTool.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 0.18
	cyl.bottom_radius = 0.26
	cyl.height = 6.2
	cyl.material = mat_bark
	st.append_from(cyl, 0, Transform3D(Basis(), Vector3(0, 3.1, 0)))

	var cone = CylinderMesh.new()
	cone.top_radius = 0.05
	cone.bottom_radius = 1.5
	cone.height = 3.6
	cone.material = mat_foliage
	st.append_from(cone, 0, Transform3D(Basis(), Vector3(0, 5.5, 0)))
	return st.commit()

func _create_crooked_tree_mesh(mat_bark: Material, mat_foliage: Material) -> Mesh:
	var st = SurfaceTool.new()
	# Segmento inferior reto
	var cyl_low = CylinderMesh.new()
	cyl_low.top_radius = 0.22
	cyl_low.bottom_radius = 0.28
	cyl_low.height = 2.8
	cyl_low.material = mat_bark
	st.append_from(cyl_low, 0, Transform3D(Basis(), Vector3(0, 1.4, 0)))

	# Segmento superior inclinado entre 15 e 20 graus
	var rot_b = Basis(Vector3.RIGHT, deg_to_rad(18.0))
	var cyl_up = CylinderMesh.new()
	cyl_up.top_radius = 0.14
	cyl_up.bottom_radius = 0.22
	cyl_up.height = 3.4
	cyl_up.material = mat_bark
	st.append_from(cyl_up, 0, Transform3D(rot_b, Vector3(0, 4.1, 0.5)))

	# Copa torta deslocada no sentido da inclinação
	var foliage_b = SphereMesh.new()
	foliage_b.radius = 1.5
	foliage_b.height = 3.2
	foliage_b.material = mat_foliage
	st.append_from(foliage_b, 0, Transform3D(Basis(), Vector3(0, 5.6, 1.05)))
	return st.commit()

func _create_curved_tree_mesh(mat_bark: Material, mat_foliage: Material) -> Mesh:
	var st = SurfaceTool.new()
	# Segmento 1 inclinado para um lado
	var rot_c1 = Basis(Vector3.FORWARD, deg_to_rad(14.0))
	var cyl_c1 = CylinderMesh.new()
	cyl_c1.top_radius = 0.22
	cyl_c1.bottom_radius = 0.28
	cyl_c1.height = 2.6
	cyl_c1.material = mat_bark
	st.append_from(cyl_c1, 0, Transform3D(rot_c1, Vector3(-0.3, 1.3, 0)))

	# Segmento 2 curvando para o lado oposto
	var rot_c2 = Basis(Vector3.FORWARD, deg_to_rad(-16.0))
	var cyl_c2 = CylinderMesh.new()
	cyl_c2.top_radius = 0.14
	cyl_c2.bottom_radius = 0.22
	cyl_c2.height = 3.2
	cyl_c2.material = mat_bark
	st.append_from(cyl_c2, 0, Transform3D(rot_c2, Vector3(0.2, 3.8, 0)))

	# Galhos finos secos pontiagudos
	var branch_mesh = CylinderMesh.new()
	branch_mesh.top_radius = 0.04
	branch_mesh.bottom_radius = 0.09
	branch_mesh.height = 1.8
	branch_mesh.material = mat_bark

	var rot_br1 = Basis(Vector3(0.4, 0.2, 0.8).normalized(), deg_to_rad(48.0))
	st.append_from(branch_mesh, 0, Transform3D(rot_br1, Vector3(-0.6, 3.6, 0.2)))

	var rot_br2 = Basis(Vector3(-0.3, 0.1, -0.9).normalized(), deg_to_rad(52.0))
	st.append_from(branch_mesh, 0, Transform3D(rot_br2, Vector3(0.7, 4.4, -0.3)))

	# Copa irregular
	var foliage_c = SphereMesh.new()
	foliage_c.radius = 1.3
	foliage_c.height = 2.5
	foliage_c.material = mat_foliage
	st.append_from(foliage_c, 0, Transform3D(Basis(), Vector3(0.1, 5.5, 0)))
	return st.commit()

# ==============================================================================
# CONFIGURAÇÃO DAS PLACAS DE AVISO COM SANGUE
# ==============================================================================

func _setup_signs() -> void:
	if not signs_container:
		return

	var sign_nodes = signs_container.get_children()
	for i in range(sign_nodes.size()):
		var sign_node = sign_nodes[i]
		if i < sign_phrases.size():
			if "text" in sign_node:
				sign_node.text = sign_phrases[i]

		# Placas que ficaram na floresta: vão pra frente da primeira fileira,
		# viradas pra estrada, e perdem o poste (ficam grudadas na árvore)
		if sign_node is Node3D:
			var gx: float = sign_node.global_position.x
			if absf(gx) > 4.0:
				var lado: float = signf(gx)
				var pos: Vector3 = sign_node.global_position
				pos.x = lado * 5.9
				pos.y = clampf(pos.y, 1.5, 2.2)
				sign_node.global_position = pos
				sign_node.rotation.y = -lado * PI / 2.0
				print("[PLACA] filhos de ", sign_node.name, ": ", sign_node.get_children().map(func(c): return c.name))
				_remover_pe_da_placa(sign_node)

func _remover_pe_da_placa(no: Node) -> void:
	for filho in no.get_children():
		var nome: String = String(filho.name).to_lower()
		if nome.contains("post") or nome.contains("pole") or nome.contains("stand") or nome.contains("leg"):
			filho.queue_free()
		else:
			_remover_pe_da_placa(filho)

# ==============================================================================
# OLHOS ALEATÓRIOS NA BORDA DA FLORESTA (CLIENT-SIDE / LOCAL, SEM SINCRONIZAR)
# ==============================================================================

func _run_eyes_loop() -> void:
	# Aguarda um frame para garantir que a câmera local foi criada
	await get_tree().process_frame
	while is_inside_tree():
		var delay: float = randf_range(eyes_min_interval, eyes_max_interval)
		await get_tree().create_timer(delay).timeout
		if not is_inside_tree():
			return

		var cam = get_viewport().get_camera_3d()
		if not cam:
			continue

		# Sorteia o ponto principal dentro do campo de visão da câmera
		var point_a = _pick_eye_point(cam, Vector3.ZERO)
		if point_a == Vector3.ZERO:
			continue

		# 40% de chance de tocar um sussurro 3D no ponto antes/junto dos olhos
		if randf() < whisper_chance:
			_play_whisper_at(point_a)

		# Cria os olhos nesse ponto (sem await, para o segundo par poder ser paralelo)
		_spawn_eye_pair(cam, point_a)

		# 30% de chance de um segundo par com 0,5 a 1,5 s de atraso
		if randf() < double_eyes_chance:
			_spawn_delayed_second_pair(cam, point_a)

func _spawn_delayed_second_pair(cam: Camera3D, exclude_pos: Vector3) -> void:
	# Executa em paralelo (sem bloquear o loop principal)
	var delay = randf_range(0.5, 1.5)
	await get_tree().create_timer(delay).timeout
	if not is_inside_tree():
		return
	var cam2 = get_viewport().get_camera_3d()
	if not cam2:
		return
	var point_b = _pick_eye_point(cam2, exclude_pos)
	if point_b != Vector3.ZERO:
		_spawn_eye_pair(cam2, point_b)

func _pick_eye_point(cam: Camera3D, exclude_near: Vector3) -> Vector3:
	# Tenta até 8 vezes sortear um ponto válido na borda da floresta
	for _attempt in range(8):
		# Escolhe lado Oeste (X negativo) ou Leste (X positivo) aleatoriamente
		var side_x: float = -1.0 if randf() < 0.5 else 1.0
		# Profundidade dentro da floresta: 1 a 6 m além da borda da estrada (X=±3 m)
		var depth = randf_range(eyes_forest_depth_min, eyes_forest_depth_max)
		var pos_x = side_x * (3.0 + depth)
		# Posição Z ao longo da estrada (Z 36 a 92)
		var pos_z = randf_range(36.0, 92.0)
		var pos_y = randf_range(eyes_height_min, eyes_height_max)
		var candidate = Vector3(pos_x, pos_y, pos_z)

		# Rejeita pontos em cima ou dentro da estrada (|X| < 3.5 m)
		if abs(candidate.x) < 3.5:
			continue

		# Verifica distância à câmera
		var dist = cam.global_position.distance_to(candidate)
		if dist < eyes_min_distance or dist > eyes_max_distance:
			continue

		# Verifica se está dentro do campo de visão da câmera
		var to_point = (candidate - cam.global_position).normalized()
		var cam_forward = -cam.global_transform.basis.z
		var angle_deg = rad_to_deg(cam_forward.angle_to(to_point))
		if angle_deg > eyes_fov_half_deg:
			continue

		# Rejeita se muito próximo de outro par de olhos ativo (< 3 m)
		var too_close = false
		for active_pos in _active_eye_positions:
			if candidate.distance_to(active_pos) < 3.0:
				too_close = true
				break
		if too_close:
			continue

		# Rejeita se igual ao ponto anterior excluído (< 4 m)
		if exclude_near != Vector3.ZERO and candidate.distance_to(exclude_near) < 4.0:
			continue

		return candidate

	return Vector3.ZERO  # Falhou em todos os 8 tentativas

func _spawn_eye_pair(cam: Camera3D, world_pos: Vector3) -> void:
	if not eyes_container:
		return

	# Registra posição ativa para evitar sobreposição
	_active_eye_positions.append(world_pos)

	# --- Cria os materiais dos olhos ---
	var eye_mat = StandardMaterial3D.new()
	eye_mat.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
	eye_mat.emission_enabled = true
	eye_mat.emission = Color(1.0, 0.0, 0.0, 1.0)
	eye_mat.emission_energy_multiplier = 5.0

	# --- Cria o nó raiz do par ---
	var pair_root = Node3D.new()
	eyes_container.add_child(pair_root)
	pair_root.global_position = world_pos

	# Vira os olhos sempre em direção à câmera
	pair_root.look_at(cam.global_position, Vector3.UP)

	# --- Cria os dois olhos (esferas emissivas) ---
	var eye_mesh = SphereMesh.new()
	eye_mesh.radius = 0.055
	eye_mesh.height = 0.11

	var left_eye = MeshInstance3D.new()
	left_eye.mesh = eye_mesh
	left_eye.material_override = eye_mat
	left_eye.position = Vector3(-0.11, 0.0, 0.0)
	pair_root.add_child(left_eye)

	var right_eye = MeshInstance3D.new()
	right_eye.mesh = eye_mesh
	right_eye.material_override = eye_mat
	right_eye.position = Vector3(0.11, 0.0, 0.0)
	pair_root.add_child(right_eye)

	# --- Aparecimento rápido via Tween (0.2 s) ---
	pair_root.scale = Vector3.ZERO
	var tween_in = create_tween()
	tween_in.tween_property(pair_root, "scale", Vector3.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await tween_in.finished

	# --- Permanência de 1 a 2 s, monitorando susto ---
	var stay_time = randf_range(1.0, 2.0)
	var elapsed = 0.0
	var step = 0.05
	var scared_away = false

	while elapsed < stay_time and is_instance_valid(pair_root):
		await get_tree().create_timer(step).timeout
		elapsed += step

		var current_cam = get_viewport().get_camera_3d()
		if not current_cam:
			break

		var to_pair = pair_root.global_position - current_cam.global_position
		var dist_now = to_pair.length()
		var angle_now = rad_to_deg((-current_cam.global_transform.basis.z).angle_to(to_pair.normalized()))

		# Susto: jogador chegou perto E olhou direto
		if dist_now < eyes_scare_distance and angle_now < eyes_scare_angle_deg:
			scared_away = true
			break

	if not is_instance_valid(pair_root):
		_active_eye_positions.erase(world_pos)
		return

	# --- Piscada (achatamento vertical por ~0.1 s) se não foi assustado ---
	if not scared_away:
		var tween_blink = create_tween()
		tween_blink.tween_property(pair_root, "scale:y", 0.08, 0.08).set_trans(Tween.TRANS_SINE)
		tween_blink.tween_property(pair_root, "scale:y", 1.0, 0.08).set_trans(Tween.TRANS_SINE)
		await tween_blink.finished
		# Pequena pausa após piscada
		await get_tree().create_timer(0.15).timeout

	# --- Desaparecimento ---
	if is_instance_valid(pair_root):
		var tween_out = create_tween()
		tween_out.tween_property(pair_root, "scale", Vector3.ZERO, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		await tween_out.finished

	_active_eye_positions.erase(world_pos)
	if is_instance_valid(pair_root):
		pair_root.queue_free()

func _play_whisper_at(world_pos: Vector3) -> void:
	# Cria um AudioStreamPlayer3D temporário para o sussurro 3D posicionado na floresta
	var asp = AudioStreamPlayer3D.new()
	asp.stream = SoundBank.get_sound("sussurro")
	asp.unit_size = 4.0
	asp.max_distance = 32.0
	asp.pitch_scale = randf_range(0.88, 1.18)
	asp.volume_db = randf_range(-8.0, -4.0)
	eyes_container.add_child(asp)
	asp.global_position = world_pos
	asp.play()
	# Remove o player depois que o som terminar (máx 3 s)
	await get_tree().create_timer(3.0).timeout
	if is_instance_valid(asp):
		asp.queue_free()
