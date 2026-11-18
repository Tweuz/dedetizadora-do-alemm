extends StaticBody3D

# ==============================================================================
# POSTE DE ILUMINAÇÃO DO CEMITÉRIO
# ==============================================================================

@onready var light: OmniLight3D = $OmniLight3D
@onready var bulb_mesh: MeshInstance3D = $LanternBulb

var bulb_material: StandardMaterial3D

func _ready() -> void:
	# Adiciona ao grupo de iluminação do cenário
	add_to_group("street_lights")
	
	# Cria uma cópia do material da lâmpada para que cada poste possa piscar independentemente
	if bulb_mesh.material_override:
		bulb_material = bulb_mesh.material_override.duplicate()
	elif bulb_mesh.get_active_material(0):
		bulb_material = bulb_mesh.get_active_material(0).duplicate()
	else:
		bulb_material = StandardMaterial3D.new()
		bulb_material.albedo_color = Color(1.0, 0.9, 0.65)
		bulb_material.emission_enabled = true
		bulb_material.emission = Color(1.0, 0.85, 0.5)
		bulb_material.emission_energy_multiplier = 2.0
		
	bulb_mesh.material_override = bulb_material

# Liga ou desliga a luz e o brilho emissivo da lâmpada
func set_light_enabled(enabled: bool) -> void:
	if light:
		light.visible = enabled
	if bulb_material:
		bulb_material.emission_energy_multiplier = 2.0 if enabled else 0.0

func is_light_enabled() -> bool:
	return light.visible if light else false
