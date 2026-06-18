@tool
class_name BoxSpawner
extends ResizableNode3D

## The box scene to spawn (must be a Box-derived PackedScene).
@export var scene: PackedScene
## When enabled, stops spawning new boxes.
@export var disable: bool = false:
	set(value):
		if value == disable:
			return
		disable = value
		if is_inside_tree():
			_change_texture()
			if not disable:
				_reset_spawn_cycle()

@export_group("Box")
## The color applied to spawned boxes.
@export var box_color: Color = Color.WHITE:
	set(value):
		box_color = value
## Mass applied to spawned boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var mass: float = 10.0
## Initial velocity applied to spawned boxes.
@export var initial_linear_velocity: Vector3 = Vector3.ZERO

@export_subgroup("Random Size")
## Enable random sizing for spawned boxes within min/max range.
@export var random_size: bool = false
## Minimum size for randomly sized boxes (X, Y, Z dimensions).
@export var random_size_min: Vector3 = Vector3(0.4, 0.3, 0.3)
## Maximum size for randomly sized boxes (X, Y, Z dimensions).
@export var random_size_max: Vector3 = Vector3(0.8, 0.5, 0.5)

@export_subgroup("Random Mass")
## Enable random mass for spawned boxes within min/max range.
@export var random_mass: bool = false
## Minimum mass for randomly massed boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var random_mass_min: float = 5.0
## Maximum mass for randomly massed boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var random_mass_max: float = 15.0

@export_group("Spawn Rate")
## Number of boxes spawned per minute (0-1000).
@export var boxes_per_minute: int = 45:
	set(value):
		value = clamp(value, 0, 1000)
		boxes_per_minute = value

## When true, boxes spawn at a fixed rate. When false, spawn times vary randomly.
@export var fixed_rate: bool = true
## When enabled, prevents spawning when another box already occupies the target space.
@export var prevent_box_overlap: bool = true
## Optional conveyor reference. Spawning pauses when conveyor speed is zero.
@export var conveyor: Node3D = null:
	set(value):
		conveyor = value
		if not value:
			_conveyor_stopped = false

@export_group("Non-Conveyable")
## Probability that a spawned box uses the non-conveyable random size profile.
@export_range(0.0, 1.0, 0.01) var non_conveyable_spawn_chance: float = 0.0
## Minimum size for non-conveyable boxes (X, Y, Z dimensions).
@export var non_conveyable_random_size_min: Vector3 = Vector3.ONE
## Maximum size for non-conveyable boxes (X, Y, Z dimensions).
@export var non_conveyable_random_size_max: Vector3 = Vector3.ONE

@export_group("Label")
## Prefix for the unique ID label on each spawned box. Leave empty for no label.
@export var label_prefix: String = ""
## Font size of the Label3D on each spawned box.
@export var label_font_size: int = 64

@export_group("Barcode Label")
## Apply the standardized parcel barcode (Turbo_G5XXXXX_Z + four Data Matrix codes,
## per the Label_Specification) to every spawned box — a fresh unique code each spawn.
## The CameraTunnel reads it; labels clear with the boxes when the simulation stops.
@export var barcode_labels: bool = true

var _scan_interval: float = 0.0
var _conveyor_stopped: bool = false
var _next_spawn_time: float = 0.0
var _spawn_counter: int = 0
var _first_spawn_done: bool = false
var _label_counter: int = 0
var _pending_spawn_size: Vector3 = Vector3.ZERO
var _has_pending_spawn_size: bool = false
var _nc_bag: Array[bool] = []
var _nc_bag_bpm: int = 0
var _nc_bag_chance: float = -1.0

@onready var _preview_mesh: MeshInstance3D = $MeshInstance3D
@onready var disabled_box_texture: MeshInstance3D = $MeshInstance3D2
@onready var _preview_collision: CollisionShape3D = $Area3D/CollisionShape3D


func _init() -> void:
	super._init()
	size_default = Vector3(0.6, 0.4, 0.4)


func _enter_tree() -> void:
	super._enter_tree()
	_reset_spawn_cycle()


func _ready() -> void:
	Simulation.started.connect(_on_simulation_started)
	Simulation.stopped.connect(_on_simulation_ended)
	_on_size_changed()
	_change_texture()


func _on_size_changed() -> void:
	if is_instance_valid(_preview_mesh):
		_preview_mesh.scale = size * 0.5
	if is_instance_valid(disabled_box_texture):
		disabled_box_texture.scale = size * 0.501
	if is_instance_valid(_preview_collision):
		var box_shape := _preview_collision.shape as BoxShape3D
		if box_shape:
			box_shape.size = size


func _physics_process(delta: float) -> void:
	if conveyor and Simulation.is_running() and &"speed" in conveyor:
		_conveyor_stopped = is_zero_approx(conveyor.speed)

	if disable or _conveyor_stopped or not Simulation.is_running():
		return

	if not _first_spawn_done:
		if _spawn_box():
			_first_spawn_done = true
			_on_spawn_succeeded()
		return

	if boxes_per_minute <= 0:
		return

	_scan_interval += delta

	if fixed_rate:
		var time_between: float = 60.0 / float(boxes_per_minute)
		if _scan_interval >= time_between:
			if _spawn_box():
				_on_spawn_succeeded()
	else:
		if _scan_interval >= _next_spawn_time:
			if _spawn_box():
				_on_spawn_succeeded()


func _spawn_box() -> bool:
	var box := _instantiate_box()
	if not box:
		return false

	var spawn_transform := Transform3D(_get_spawn_basis(), global_position)
	var check_transform := spawn_transform
	check_transform.origin.y -= 0.5
	var check_size := Vector3(box.size.x, 1.0, box.size.z)
	return _add_box_to_scene(box, spawn_transform, check_transform, check_size)


func _instantiate_box() -> Box:
	if not scene:
		return null

	var box := scene.instantiate() as Box
	if not box:
		return null

	var spawn_request := _reserve_spawn_request()
	box.size = spawn_request["size"]
	box.set_meta("_reserved_spawn_size", spawn_request["size"])
	box.set_meta("_used_pending_spawn_size", spawn_request["used_pending"])
	return box


func _get_spawn_size() -> Vector3:
	if _draw_nc_from_bag():
		return _get_random_size(non_conveyable_random_size_min, non_conveyable_random_size_max)
	if random_size:
		return _get_random_size(random_size_min, random_size_max)
	return size


# Pseudo-random NC quota: per BPM-sized window, exactly round(chance * BPM)
# spawns are NC, randomly distributed. Refills when the bag is empty or when
# BPM / chance changed since the bag was built.
func _draw_nc_from_bag() -> bool:
	if _nc_bag.is_empty() \
			or _nc_bag_bpm != boxes_per_minute \
			or not is_equal_approx(_nc_bag_chance, non_conveyable_spawn_chance):
		_refill_nc_bag()
	if _nc_bag.is_empty():
		return false
	return bool(_nc_bag.pop_back())


func _refill_nc_bag() -> void:
	_nc_bag.clear()
	_nc_bag_bpm = boxes_per_minute
	_nc_bag_chance = non_conveyable_spawn_chance
	if boxes_per_minute <= 0 or non_conveyable_spawn_chance <= 0.0:
		return
	var nc_count: int = int(roundf(non_conveyable_spawn_chance * float(boxes_per_minute)))
	nc_count = clampi(nc_count, 0, boxes_per_minute)
	for i in boxes_per_minute:
		_nc_bag.append(i < nc_count)
	_nc_bag.shuffle()


func _get_random_size(min_size: Vector3, max_size: Vector3) -> Vector3:
	var lower := min_size.min(max_size)
	var upper := min_size.max(max_size)
	return Vector3(
		randf_range(lower.x, upper.x),
		randf_range(lower.y, upper.y),
		randf_range(lower.z, upper.z)
	)


func _get_spawn_basis() -> Basis:
	return global_transform.basis.orthonormalized()


func _reserve_spawn_request() -> Dictionary:
	if _has_pending_spawn_size:
		_has_pending_spawn_size = false
		return {
			"size": _pending_spawn_size,
			"used_pending": true,
		}
	return {
		"size": _get_spawn_size(),
		"used_pending": false,
	}


func _add_box_to_scene(box: Box, spawn_transform: Transform3D, check_transform: Transform3D, check_size: Vector3) -> bool:
	if not _can_spawn_box(check_size, check_transform):
		_requeue_failed_spawn_size(box)
		box.queue_free()
		return false

	if box.get_meta("_used_pending_spawn_size", false):
		_clear_pending_spawn_size()
	if random_mass:
		box.mass = randf_range(random_mass_min, random_mass_max)
	else:
		box.mass = mass
	box.initial_linear_velocity = initial_linear_velocity
	box.color = box_color
	box.instanced = true

	if label_prefix != "":
		_label_counter += 1
		if _label_counter > 999:
			_label_counter = 1
		var label := Label3D.new()
		label.name = "IDLabel"
		label.text = label_prefix + "%03d" % _label_counter
		label.font_size = label_font_size
		label.position = Vector3(0, box.size.y / 2.0 + 0.01, 0)
		label.rotation_degrees = Vector3(-90, 0, 0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		box.get_node("RigidBody3D").add_child(label)

	if barcode_labels:
		_apply_barcode_label(box)

	add_child(box, true)
	box.global_transform = spawn_transform
	if get_tree().edited_scene_root:
		box.owner = get_tree().edited_scene_root

	var rb := box.get_node_or_null("RigidBody3D") as RigidBody3D
	if rb:
		rb.top_level = true
		rb.global_transform = spawn_transform
		rb.linear_velocity = initial_linear_velocity
	return true


func _requeue_failed_spawn_size(box: Box) -> void:
	var spawn_size: Variant = box.get_meta("_reserved_spawn_size", box.size)
	if spawn_size is Vector3:
		_pending_spawn_size = spawn_size
		_has_pending_spawn_size = true


func _clear_pending_spawn_size() -> void:
	_pending_spawn_size = Vector3.ZERO
	_has_pending_spawn_size = false


func _on_spawn_succeeded() -> void:
	_scan_interval = 0.0
	_spawn_counter += 1
	if not fixed_rate:
		_next_spawn_time = _get_random_spawn_interval()


func _can_spawn_box(box_size: Vector3, spawn_transform: Transform3D) -> bool:
	if not prevent_box_overlap:
		return true

	var spawn_pos := spawn_transform.origin
	var inv_spawn_basis := spawn_transform.basis.orthonormalized().inverse()
	var half_check_size := box_size * 0.5
	for child in get_children():
		if not child is Box:
			continue
		var other_box := child as Box
		if not is_instance_valid(other_box):
			continue
		var other_rb := other_box.get_node_or_null("RigidBody3D") as Node3D
		var other_pos: Vector3 = other_rb.global_position if other_rb else other_box.global_position
		var other_half := other_box.size * 0.5

		# Compare in the spawner's local frame so the AABB test still uses the
		# correct per-axis extents when the spawner (or its conveyor) is rotated.
		var local_offset := inv_spawn_basis * (other_pos - spawn_pos)
		var dx := absf(local_offset.x)
		var dy := absf(local_offset.y)
		var dz := absf(local_offset.z)
		if dx < half_check_size.x + other_half.x \
				and dy < half_check_size.y + other_half.y \
				and dz < half_check_size.z + other_half.z:
			return false
	return true


func _reset_spawn_cycle() -> void:
	_scan_interval = 0.0
	_spawn_counter = 0
	_first_spawn_done = false
	_next_spawn_time = _get_random_spawn_interval()
	_nc_bag.clear()


func _get_random_spawn_interval() -> float:
	if boxes_per_minute <= 0:
		return INF
	return (60.0 / float(boxes_per_minute)) * randf_range(0.5, 1.5)


func _change_texture() -> void:
	if not is_inside_tree():
		return
	disabled_box_texture.visible = disable


func use() -> void:
	disable = not disable


## Stamps a standardized parcel barcode on the box top and stores the code as metadata
## (on the RigidBody3D, which is what the CameraTunnel read-gate detects).
func _apply_barcode_label(box: Box) -> void:
	var rb := box.get_node_or_null("RigidBody3D")
	if rb == null:
		return
	var bc: Dictionary = BarcodeLabel.generate()
	rb.set_meta("barcode_value", bc["value"])
	rb.set_meta("barcode_string", bc["string"])

	var top: float = box.size.y / 2.0 + 0.002
	var w: float = minf(box.size.x, box.size.z) * 0.78
	var tex: Texture2D = BarcodeLabel.make_texture(bc["value"])
	var aspect: float = float(tex.get_height()) / float(tex.get_width())  # codes-strip h/w

	# white sticker backing (codes on top, text below)
	var sticker := MeshInstance3D.new()
	sticker.name = "BarcodeLabel"
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, w * (aspect + 0.34))
	sticker.mesh = pm
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.97, 0.97, 0.95)
	sticker.material_override = wm
	sticker.position = Vector3(0, top, 0)
	rb.add_child(sticker)

	# the four Data Matrix codes (kept square via the texture's true aspect)
	var codes := MeshInstance3D.new()
	codes.name = "BarcodeCodes"
	var cm := PlaneMesh.new()
	cm.size = Vector2(w * 0.92, w * 0.92 * aspect)
	codes.mesh = cm
	var lm := StandardMaterial3D.new()
	lm.albedo_texture = tex
	lm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	codes.material_override = lm
	codes.position = Vector3(0, top + 0.001, -w * (aspect + 0.34) * 0.22)
	rb.add_child(codes)

	# human-readable string under the codes
	var text := Label3D.new()
	text.name = "BarcodeText"
	text.text = bc["string"]
	text.font_size = 48
	text.pixel_size = w * 0.0012
	text.modulate = Color.BLACK
	text.rotation_degrees = Vector3(-90, 0, 0)
	text.position = Vector3(0, top + 0.002, w * (aspect + 0.34) * 0.28)
	rb.add_child(text)


func _on_simulation_started() -> void:
	if conveyor and &"speed" not in conveyor:
		push_warning("Conveyor reference in " + name + " does not have a speed property")
	_clear_pending_spawn_size()
	_label_counter = 0
	if barcode_labels:
		randomize()                      # fresh barcode sequence each run
	_reset_spawn_cycle()


func _on_simulation_ended() -> void:
	_clear_pending_spawn_size()
	_conveyor_stopped = false
	_label_counter = 0
