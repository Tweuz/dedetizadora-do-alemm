extends Node3D

# ==============================================================================
# CENA DE ABERTURA - ESTRADA DE TERRA, FLORESTA DENSA, ÁRVORES VIVAS E LIMITES
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
	"ÚLTIMO AVISO"
]

# 2. Configurações de Sussurros e Árvores Vivas
@export var whisper_min_interval: float = 5.0
@export var whisper_max_interval: float = 12.0
@export var behind_player_chance: float = 0.25
@export var direct_eyes_chance: float = 0.25
@export var double_event_chance: float = 0.20

# 3. Referências aos nós filhos
@onready var wind_player: AudioStreamPlayer = $WindAudioPlayer
@onready var signs_container: Node3D = $Signs
@onready var living_trees_container: Node3D = $LivingTrees
@onready var spawn_points_container: Node3D = $SpawnPoints
@onready var void_area: Area3D = $VoidSafetyArea

# MultiMeshInstances para a floresta densa (desempenho otimizado)
@onready var mm_straight: MultiMeshInstance3D = $Forest/MultiMeshStraight
@onready var mm_crooked: MultiMeshInstance3D = $Forest/MultiMeshCrooked
@onready var mm_curved: MultiMeshInstance3D = $Forest/MultiMeshCurved

var _last_side_west: bool = false

func _ready() -> void:
	# 1. Gera a floresta densa otimizada nos MultiMeshInstances
	_build_dense_forest()

	# 2. Configura as placas de aviso ao longo da estrada
	_setup_signs()

	# 3. Inicia o som de vento contínuo em loop
	if wind_player:
		wind_player.stream = SoundBank.get_sound("vento")
		wind_player.volume_db = -6.0
		wind_player.play()

	# 4. Conecta a rede de segurança da área de queda
	if void_area:
		void_area.body_entered.connect(_on_void_area_body_entered)

	# 5. Inicia o ciclo dinâmico de sussurros e olhos das árvores vivas (local)
	_run_living_trees_loop()

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
	var basis = Basis(Vector3.UP, yaw).scaled(Vector3(s_xz, s_y, s_xz))
	var xf = Transform3D(basis, pos)

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

# ==============================================================================
# ÁRVORES VIVAS, SUSSURROS E OLHOS VERMELHOS (CLIENT-SIDE / LOCAL)
# ==============================================================================

func _run_living_trees_loop() -> void:
	while is_inside_tree():
		var delay: float = randf_range(whisper_min_interval, whisper_max_interval)
		await get_tree().create_timer(delay).timeout
		if not is_inside_tree():
			return

		var cam = get_viewport().get_camera_3d()
		if not cam:
			continue

		var all_trees = get_tree().get_nodes_in_group("arvores_vivas")
		if all_trees.is_empty():
			continue

		# Seleciona uma ou duas árvores para o evento paranormal
		var chosen_trees: Array[Node] = []
		var first_tree = _pick_living_tree(all_trees, cam)
		if first_tree:
			chosen_trees.append(first_tree)

		# 20% de chance de dois pares de olhos em árvores diferentes ao mesmo tempo
		if randf() < double_event_chance:
			var second_tree = _pick_living_tree(all_trees, cam, first_tree)
			if second_tree and second_tree != first_tree:
				chosen_trees.append(second_tree)

		for t in chosen_trees:
			if not is_instance_valid(t):
				continue

			# 25% dos casos os olhos aparecem diretamente sem sussurro antes
			if randf() < direct_eyes_chance:
				if t.has_method("show_eyes_directly"):
					t.show_eyes_directly()
			else:
				# Sussurro + balanço + arma a árvore por 6 segundos
				if t.has_method("sway"):
					t.sway()
				if t.has_method("play_whisper"):
					t.play_whisper()
				if t.has_method("arm"):
					t.arm(6.0)

func _pick_living_tree(trees: Array[Node], cam: Camera3D, exclude: Node = null) -> Node:
	var cam_pos = cam.global_position
	var cam_forward = -cam.global_transform.basis.z

	# 25% das vezes escolhe uma árvore viva que esteja ATRÁS do jogador
	if randf() < behind_player_chance:
		var behind_trees: Array[Node] = []
		for t in trees:
			if t == exclude:
				continue
			var to_tree = t.global_position - cam_pos
			if cam_forward.dot(to_tree) < 0.0:
				behind_trees.append(t)
		if not behind_trees.is_empty():
			return behind_trees.pick_random()

	# Alterna os lados (Oeste / Leste) para manter dinamismo nos dois ouvidos
	_last_side_west = not _last_side_west
	var side_trees: Array[Node] = []
	for t in trees:
		if t == exclude:
			continue
		var is_west = t.global_position.x < 0.0
		if is_west == _last_side_west:
			side_trees.append(t)

	if not side_trees.is_empty():
		return side_trees.pick_random()

	# Fallback geral
	return trees.pick_random()
