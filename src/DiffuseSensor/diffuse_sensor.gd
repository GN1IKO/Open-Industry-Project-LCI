@tool
class_name DiffuseSensor
extends Node3D

const _METERS_TO_INCHES: float = 39.3701
const _STAT_PROPERTIES: PackedStringArray = [
	"conveyor_path", "display_unit", "nc_threshold", "label_offset", "label_font_size",
	"show_count", "show_pph", "show_timer", "show_length", "show_pitch", "show_gap", "show_non_conveyable",
]

enum DisplayUnit { METERS, INCHES }

## Maximum detection range of the diffuse sensor in meters.
@export_custom(PROPERTY_HINT_NONE, "suffix:m") var max_range: float = 1.524:
	set(value):
		value = clamp(value, 0, 100)
		max_range = value

## Toggle visibility of the sensor beam visualization.
@export var show_beam: bool = true:
	set(value):
		show_beam = value
		if _instance:
			RenderingServer.instance_set_visible(_instance, show_beam)
			if show_beam:
				_beam_needs_update = true

## When true, output is inverted (false when object detected).
@export var normally_closed: bool = false:
	set(value):
		normally_closed = value
		_update_output()

## True when an object is within detection range (read-only).
@export var detected: bool = false:
	set(value):
		detected = value
		_update_output()

## Final output signal after applying normally_closed logic (read-only).
@export var output: bool = false:
	set(value):
		if _tag.is_ready() and value != output:
			_tag.write_bit(value)
		output = value

@export_group("Statistics")
## Show a floating label with package statistics measured by this sensor.
@export var enable_statistics: bool = false:
	set(value):
		if value == enable_statistics:
			return
		enable_statistics = value
		notify_property_list_changed()
		_apply_statistics_label_state()
## Conveyor whose speed is integrated to convert beam-break time into distance.
## Any node with a [code]speed[/code] property works (conveyors and conveyor assemblies).
@export var conveyor_path: NodePath:
	set(value):
		conveyor_path = value
		_resolve_conveyor()
## Unit used for displayed distances. Internal math is always meters.
@export var display_unit: DisplayUnit = DisplayUnit.METERS:
	set(value):
		display_unit = value
		_update_label()
## Length at or above which a package counts as non-conveyable.
@export_custom(PROPERTY_HINT_NONE, "suffix:m") var nc_threshold: float = 1.201
## Offset of the statistics label relative to the sensor.
@export var label_offset: Vector3 = Vector3(0, 0.5, 0):
	set(value):
		label_offset = value
		if _stats_label and is_instance_valid(_stats_label):
			_stats_label.position = label_offset
## Font size of the statistics label.
@export var label_font_size: int = 32:
	set(value):
		label_font_size = value
		if _stats_label and is_instance_valid(_stats_label):
			_stats_label.font_size = label_font_size
@export_subgroup("Visible Stats")
@export var show_count: bool = true:
	set(value):
		show_count = value
		_update_label()
@export var show_pph: bool = true:
	set(value):
		show_pph = value
		_update_label()
@export var show_timer: bool = true:
	set(value):
		show_timer = value
		_update_label()
## Last and average package length (front edge to back edge).
@export var show_length: bool = true:
	set(value):
		show_length = value
		_update_label()
## Last and average pitch (front edge to next front edge).
@export var show_pitch: bool = true:
	set(value):
		show_pitch = value
		_update_label()
## Last and average gap (back edge to next front edge).
@export var show_gap: bool = true:
	set(value):
		show_gap = value
		_update_label()
## Non-conveyable count, percentage, and average length.
@export var show_non_conveyable: bool = true:
	set(value):
		show_non_conveyable = value
		_update_label()

var _mesh: ImmediateMesh
static var _beam_material: StandardMaterial3D = preload("uid://ntmcfd25jgpm")
var _instance: RID
var _scenario: RID
var _ray_query: PhysicsRayQueryParameters3D
var _tag := OIPCommsTag.new()
var _last_result_distance: float = -1.0
var _last_beam_color: Color = Color.TRANSPARENT
var _last_transform: Transform3D
var _beam_needs_update: bool = true
## Counter used to throttle the per-tick raycast to ~30 Hz (every 4th
## physics tick at the project's 120 Hz rate). 33 ms detection latency
## is well within typical PLC scan rates and the cached `detected` /
## `_last_*` state stays valid between samples.
var _scan_tick: int = 0

var _stats_label: Label3D = null
var _conveyor: Node = null

var _prev_detected: bool = false
var _measuring_length: bool = false
var _measuring_pitch: bool = false
var _measuring_gap: bool = false
var _length_accum: float = 0.0
var _pitch_accum: float = 0.0
var _gap_accum: float = 0.0

var _box_count: int = 0
var _last_length: float = 0.0
var _length_sum: float = 0.0
var _length_count: int = 0
var _last_pitch: float = 0.0
var _pitch_sum: float = 0.0
var _pitch_count: int = 0
var _last_gap: float = 0.0
var _gap_sum: float = 0.0
var _gap_count: int = 0
var _nc_count: int = 0
var _nc_length_sum: float = 0.0
var _timer: float = 0.0
var _timer_started: bool = false

@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group for writing output state to external systems.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value
## The tag name for the output state in the selected tag group.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var tag_name: String = ""


func _validate_property(property: Dictionary) -> void:
	if property.name == "detected":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
		return
	if property.name == "output":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
		return
	if property.name in _STAT_PROPERTIES:
		if not enable_statistics:
			property.usage = PROPERTY_USAGE_NO_EDITOR
		return
	OIPCommsSetup.validate_tag_property(property)


func _enter_tree() -> void:
	_instance = RenderingServer.instance_create()
	_scenario = get_world_3d().scenario
	_mesh = ImmediateMesh.new()

	RenderingServer.instance_set_scenario(_instance, _scenario)
	RenderingServer.instance_set_base(_instance, _mesh)
	RenderingServer.instance_set_visible(_instance, show_beam)
	_beam_needs_update = true

	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collision_mask = 8

	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	Simulation.started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized)

	_resolve_conveyor()
	_apply_statistics_label_state()


func _exit_tree() -> void:
	RenderingServer.free_rid(_instance)
	SensorBeamCache.clear_beam(get_instance_id())
	Simulation.started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized)
	_free_label()


func _physics_process(delta: float) -> void:
	if enable_statistics:
		_update_statistics(delta)
	_scan_tick += 1
	if _scan_tick % 4 != 0:
		return
	var start_pos := global_transform.translated_local(Vector3(0, 0.25, 0.42)).origin
	var dir := global_transform.basis.z.normalized()
	var end_pos := start_pos + dir * max_range

	_ray_query.from = start_pos
	_ray_query.to = end_pos
	var space_state := get_world_3d().direct_space_state
	var result := space_state.intersect_ray(_ray_query)
	var result_distance := max_range
	var has_detection := result.size() > 0

	var beam_color: Color
	if has_detection:
		result_distance = start_pos.distance_to(result["position"])
		detected = true
		beam_color = Color.RED
	else:
		detected = false
		beam_color = Color.GREEN

	var current_transform := global_transform
	var beam_end := start_pos + dir * result_distance
	if _beam_needs_update or result_distance != _last_result_distance or beam_color != _last_beam_color or current_transform != _last_transform:
		if show_beam:
			_update_beam_mesh(start_pos, result_distance, beam_color)
		SensorBeamCache.set_beam(get_instance_id(), start_pos, beam_end)
		_last_result_distance = result_distance
		_last_beam_color = beam_color
		_last_transform = current_transform
		_beam_needs_update = false


func _update_beam_mesh(start_pos: Vector3, result_distance: float, beam_color: Color) -> void:
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _beam_material)
	_mesh.surface_set_color(beam_color)
	_mesh.surface_add_vertex(start_pos)
	_mesh.surface_set_color(beam_color)
	_mesh.surface_add_vertex(start_pos + global_transform.basis.z.normalized() * result_distance)
	_mesh.surface_end()


func use() -> void:
	show_beam = not show_beam


func _update_output() -> void:
	var new_output := detected
	if normally_closed:
		new_output = !detected
	output = new_output


func _on_simulation_started() -> void:
	if enable_comms:
		_tag.register(tag_group_name, tag_name, OIPComms.TAG_TYPE_BOOL)
	if enable_statistics:
		_reset_statistics()


func _tag_group_initialized(tag_group_name_param: String) -> void:
	if _tag.on_group_initialized(tag_group_name_param):
		_tag.write_bit(output)


func _resolve_conveyor() -> void:
	if conveyor_path.is_empty():
		_conveyor = null
		return
	if not is_inside_tree():
		return
	_conveyor = get_node_or_null(conveyor_path)


func _current_speed() -> float:
	if _conveyor and is_instance_valid(_conveyor) and &"speed" in _conveyor:
		return absf(_conveyor.speed)
	return 0.0


func _apply_statistics_label_state() -> void:
	if enable_statistics and is_inside_tree():
		_ensure_label()
	else:
		_free_label()


func _ensure_label() -> void:
	if _stats_label and is_instance_valid(_stats_label):
		return
	var label := Label3D.new()
	label.name = "StatsLabel"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.font_size = label_font_size
	label.position = label_offset
	add_child(label)
	_stats_label = label
	_update_label()


func _free_label() -> void:
	if _stats_label and is_instance_valid(_stats_label):
		_stats_label.queue_free()
	_stats_label = null


func _update_statistics(delta: float) -> void:
	if not Simulation.is_running():
		return

	var speed: float = _current_speed()

	if _measuring_length:
		_length_accum += speed * delta
	if _measuring_pitch:
		_pitch_accum += speed * delta
	if _measuring_gap:
		_gap_accum += speed * delta

	var cur: bool = detected

	# Rising edge: box front edge arrives at the beam.
	if cur and not _prev_detected:
		_timer_started = true
		_box_count += 1
		if _measuring_pitch:
			_last_pitch = _pitch_accum
			_pitch_sum += _pitch_accum
			_pitch_count += 1
		_measuring_pitch = true
		_pitch_accum = 0.0
		if _measuring_gap:
			_last_gap = _gap_accum
			_gap_sum += _gap_accum
			_gap_count += 1
			_measuring_gap = false
		_measuring_length = true
		_length_accum = 0.0

	# Falling edge: box back edge clears the beam.
	if not cur and _prev_detected:
		if _measuring_length:
			_last_length = _length_accum
			_length_sum += _length_accum
			_length_count += 1
			if _length_accum >= nc_threshold:
				_nc_count += 1
				_nc_length_sum += _length_accum
			_measuring_length = false
		_measuring_gap = true
		_gap_accum = 0.0

	_prev_detected = cur

	if _timer_started:
		_timer += delta

	_update_label()


func _reset_statistics() -> void:
	_prev_detected = detected
	_measuring_length = false
	_measuring_pitch = false
	_measuring_gap = false
	_length_accum = 0.0
	_pitch_accum = 0.0
	_gap_accum = 0.0
	_box_count = 0
	_last_length = 0.0
	_length_sum = 0.0
	_length_count = 0
	_last_pitch = 0.0
	_pitch_sum = 0.0
	_pitch_count = 0
	_last_gap = 0.0
	_gap_sum = 0.0
	_gap_count = 0
	_nc_count = 0
	_nc_length_sum = 0.0
	_timer = 0.0
	_timer_started = false
	_update_label()


func _to_unit(meters: float) -> float:
	return meters * _METERS_TO_INCHES if display_unit == DisplayUnit.INCHES else meters


func _unit_suffix() -> String:
	return "in" if display_unit == DisplayUnit.INCHES else "m"


func _update_label() -> void:
	if not (_stats_label and is_instance_valid(_stats_label)):
		return
	var u: String = _unit_suffix()
	var lines: PackedStringArray = []
	if show_count:
		lines.append("Count: %d" % _box_count)
	if show_pph:
		var pph: float = float(_box_count) / _timer * 3600.0 if _timer > 0.0 else 0.0
		lines.append("PPH: %.0f" % pph)
	if show_timer:
		var minutes: int = int(_timer / 60.0)
		var seconds: int = int(_timer) - minutes * 60
		lines.append("Timer: %d:%02d" % [minutes, seconds])
	if show_length:
		lines.append("Last Length: %.2f %s" % [_to_unit(_last_length), u])
		var avg_length: float = _length_sum / float(_length_count) if _length_count > 0 else 0.0
		lines.append("Avg Length: %.2f %s" % [_to_unit(avg_length), u])
	if show_pitch:
		lines.append("Last Pitch: %.2f %s" % [_to_unit(_last_pitch), u])
		var avg_pitch: float = _pitch_sum / float(_pitch_count) if _pitch_count > 0 else 0.0
		lines.append("Avg Pitch: %.2f %s" % [_to_unit(avg_pitch), u])
	if show_gap:
		lines.append("Last Gap: %.2f %s" % [_to_unit(_last_gap), u])
		var avg_gap: float = _gap_sum / float(_gap_count) if _gap_count > 0 else 0.0
		lines.append("Avg Gap: %.2f %s" % [_to_unit(avg_gap), u])
	if show_non_conveyable:
		lines.append("NC Count: %d" % _nc_count)
		var nc_pct: float = float(_nc_count) / float(_length_count) * 100.0 if _length_count > 0 else 0.0
		lines.append("NC %%: %.1f%%" % nc_pct)
		var avg_nc: float = _nc_length_sum / float(_nc_count) if _nc_count > 0 else 0.0
		lines.append("Avg NC Length: %.2f %s" % [_to_unit(avg_nc), u])
	_stats_label.text = "\n".join(lines)
