extends Node3D

# ==============================================================================
# SCRIPT DE PLACA DE AVISO (ESCRITA COM SANGUE, PINGOS, BORRÕES E VARIAÇÕES)
# ==============================================================================

@export var text: String = "NÃO ENTRE":
	set(value):
		text = value
		_update_text()

@export var board_width: float = 1.6
@export var board_height: float = 0.6
@export var board_tilt_deg: float = 0.0
@export var text_tilt_deg: float = 0.0
@export var wood_tone: Color = Color(0.18, 0.14, 0.11, 1.0)
@export var has_stain: bool = false
@export var stain_offset: Vector2 = Vector2(0.2, -0.04)
@export var stain_size: Vector2 = Vector2(0.45, 0.22)
@export var drips_count: int = 3

@onready var post_mesh: MeshInstance3D = $PostMesh
@onready var board_mesh: MeshInstance3D = $BoardMesh
@onready var label_main: Label3D = $BoardMesh/Label3D_Main
@onready var label_blur: Label3D = $BoardMesh/Label3D_Blur
@onready var stain_mesh: MeshInstance3D = $BoardMesh/StainQuad
@onready var drips_container: Node3D = $BoardMesh/DripsContainer

func _ready() -> void:
	_apply_visual_customizations()
	_update_text()

func _update_text() -> void:
	if not is_inside_tree():
		return
	if label_main:
		label_main.text = text
	if label_blur:
		label_blur.text = text

func _apply_visual_customizations() -> void:
	# 1. Inclinação da placa completa ou do texto
	if board_tilt_deg != 0.0:
		board_mesh.rotation_degrees.z = board_tilt_deg
	if text_tilt_deg != 0.0:
		label_main.rotation_degrees.z = text_tilt_deg
		label_blur.rotation_degrees.z = text_tilt_deg

	# 2. Variação no tamanho da placa de madeira
	if board_mesh and board_mesh.mesh is BoxMesh:
		var new_box = board_mesh.mesh.duplicate() as BoxMesh
		new_box.size = Vector3(board_width, board_height, 0.05)
		board_mesh.mesh = new_box

	# 3. Variação no tom da madeira
	if board_mesh:
		var wood_mat = StandardMaterial3D.new()
		wood_mat.albedo_color = wood_tone
		wood_mat.roughness = 0.92
		board_mesh.material_override = wood_mat

	# 4. Mancha de sangue escuro/apagador arranhado
	if stain_mesh:
		stain_mesh.visible = has_stain
		if has_stain:
			stain_mesh.position = Vector3(stain_offset.x, stain_offset.y, 0.032)
			if stain_mesh.mesh is QuadMesh:
				var qm = stain_mesh.mesh.duplicate() as QuadMesh
				qm.size = stain_size
				stain_mesh.mesh = qm

	# 5. Gera os pingos de sangue escorrendo abaixo de letras
	_setup_blood_drips()

func _setup_blood_drips() -> void:
	if not drips_container:
		return
	for c in drips_container.get_children():
		c.queue_free()

	var blood_mat = StandardMaterial3D.new()
	blood_mat.albedo_color = Color(0.38, 0.03, 0.03, 0.95) # Vermelho-sangue escuro (#6b0a0a)
	blood_mat.roughness = 0.35
	blood_mat.metallic = 0.1

	var count = clamp(drips_count, 1, 5)
	var x_spread = (board_width * 0.7)
	for i in range(count):
		var drip = MeshInstance3D.new()
		var quad = QuadMesh.new()
		var d_width = randf_range(0.015, 0.032)
		var d_height = randf_range(0.08, 0.22)
		quad.size = Vector2(d_width, d_height)
		drip.mesh = quad
		drip.material_override = blood_mat

		var rand_x = -x_spread * 0.5 + (x_spread / float(count)) * (i + randf_range(0.2, 0.8))
		var rand_y = -board_height * 0.22 - (d_height * 0.5)
		drip.position = Vector3(rand_x, rand_y, 0.028)
		drips_container.add_child(drip)
