extends CharacterBody3D

# ==============================================================================
# JOGO DE TERROR COOPERATIVO - SCRIPT DO JOGADOR (PRIMEIRA PESSOA)
# ==============================================================================

# Velocidades de locomoção
const WALK_SPEED: float = 3.5
const SPRINT_SPEED: float = 6.0
const ACCELERATION: float = 10.0
const GRAVITY: float = 18.0

# Sensibilidade do mouse e limite vertical do olhar
@export var mouse_sensitivity: float = 0.003
var pitch_limit: float = deg_to_rad(89.0)

# Referências aos nós filhos
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/Flashlight
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer

func _enter_tree() -> void:
	# Define a autoridade de rede deste nó usando o nome do nó.
	# Quando o MultiplayerSpawner cria o jogador, o nome dele é definido como o peer_id (ex: "1", "248192").
	var peer_id: int = name.to_int()
	if peer_id <= 0:
		peer_id = 1 # Fallback caso a cena seja aberta isolada no editor para testes
	
	set_multiplayer_authority(peer_id)
	
	# Garante que o MultiplayerSynchronizer também tenha a autoridade deste jogador
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(peer_id)

func _ready() -> void:
	# Cria dinamicamente as ações no InputMap caso ainda não existam no project.godot
	_setup_default_inputs()
	
	# Configuração de autoridade local vs remota
	if is_multiplayer_authority():
		# Jogador Local:
		# 1. Ativa a câmera local
		camera.current = true
		
		# 2. Configura a malha do próprio corpo para projetar apenas sombra.
		# Isso impede que o modelo 3D bloqueie a visão da câmera em primeira pessoa.
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		
		# 3. Captura o cursor do mouse para a movimentação em primeira pessoa
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		# Jogador Remoto:
		# Desativa câmera e processamento de inputs locais.
		# A posição, rotação e status da lanterna são atualizados pelo MultiplayerSynchronizer.
		camera.current = false
		set_physics_process(false)
		set_process_unhandled_input(false)

# ==============================================================================
# ENTRADAS DE USUÁRIO (MOUSE E TECLAS RÁPIDAS)
# ==============================================================================
func _unhandled_input(event: InputEvent) -> void:
	# Apenas o dono do personagem processa entradas
	if not is_multiplayer_authority():
		return

	# Clicar na tela quando o mouse estiver livre recaptura o cursor
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return

	# ESC libera ou recaptura o mouse (essencial para sair de tela cheia ou usar menus)
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return

	# Mouse Look (olhar ao redor):
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Gira o corpo horizontalmente (Yaw - eixo Y)
		rotate_y(-event.relative.x * mouse_sensitivity)
		
		# Gira a cabeça verticalmente (Pitch - eixo X)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clamp(head.rotation.x, -pitch_limit, pitch_limit)
		get_viewport().set_input_as_handled()
		return

	# Alternar lanterna com a tecla 'F'
	if event.is_action_pressed("toggle_flashlight"):
		toggle_flashlight()
		get_viewport().set_input_as_handled()
		return

# ==============================================================================
# FÍSICA E MOVIMENTAÇÃO (WASD + CORRER + SEM PULO)
# ==============================================================================
func _physics_process(delta: float) -> void:
	# Apenas o jogador local executa a física e move seu personagem
	if not is_multiplayer_authority():
		return

	# Aplica gravidade básica caso esteja no ar
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	# Pulo desativado conforme solicitado no design de terror!

	# Velocidade de movimento: caminhar padrão ou correr com Shift pressionado
	var current_speed: float = WALK_SPEED
	if Input.is_action_pressed("sprint"):
		current_speed = SPRINT_SPEED

	# Leitura do vetor de movimentação WASD
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	
	# Converte a direção do plano 2D para o espaço 3D relativo à rotação atual do corpo
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	# Aceleração e desaceleração suave
	if direction != Vector3.ZERO:
		velocity.x = lerp(velocity.x, direction.x * current_speed, ACCELERATION * delta)
		velocity.z = lerp(velocity.z, direction.z * current_speed, ACCELERATION * delta)
	else:
		velocity.x = lerp(velocity.x, 0.0, ACCELERATION * delta)
		velocity.z = lerp(velocity.z, 0.0, ACCELERATION * delta)

	move_and_slide()

# ==============================================================================
# SISTEMA DE LANTERNA
# ==============================================================================
func toggle_flashlight() -> void:
	# Envia chamada RPC para sincronizar o estado da lanterna instantaneamente entre todos
	set_flashlight_state.rpc(not flashlight.visible)

@rpc("call_local", "reliable")
func set_flashlight_state(is_on: bool) -> void:
	# Atualiza o nó SpotLight3D
	flashlight.visible = is_on

# ==============================================================================
# CONFIGURAÇÃO AUTOMÁTICA DE INPUTS (FALLBACK DE SEGURANÇA)
# ==============================================================================
func _setup_default_inputs() -> void:
	# Garante que as ações de entrada funcionem de imediato, mesmo se ainda não cadastradas no editor
	_add_action_key("move_forward", KEY_W)
	_add_action_key("move_back", KEY_S)
	_add_action_key("move_left", KEY_A)
	_add_action_key("move_right", KEY_D)
	_add_action_key("sprint", KEY_SHIFT)
	_add_action_key("toggle_flashlight", KEY_F)

func _add_action_key(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
		var ev: InputEventKey = InputEventKey.new()
		ev.physical_keycode = keycode
		InputMap.action_add_event(action, ev)
