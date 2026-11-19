extends Node3D

# ==============================================================================
# PLACA DE AVISO DA ESTRADA
# ==============================================================================

@export var text: String = "NÃO ENTRE":
	set(value):
		text = value
		if is_node_ready() and has_node("BoardMesh/Label3D"):
			$BoardMesh/Label3D.text = text

func _ready() -> void:
	if has_node("BoardMesh/Label3D"):
		$BoardMesh/Label3D.text = text
