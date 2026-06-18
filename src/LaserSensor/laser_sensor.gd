@tool
class_name LaserSensor
extends Node3D

## Maximum detection range of the laser sensor in meters.
@export_custom(PROPERTY_HINT_NONE, "suffix:m") var max_range: float = 1.524:
	set(value):
		value = clamp(value, 0, 100)
		max_range = value

## Toggle visibility of the laser beam visualization.
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
		if _output_tag.is_ready() and value != output:
			_output_tag.write_bit(value)
		output = value

## Current measured distance to detected object (read-only).
@export_custom(PROPERTY_HINT_NONE, "suffix:m") var distance: float = max_range:
	set(value):
		if _distance_tag.is_ready() and value != distance:
			_distance_tag.write_float32(value)
		distance = value

var _mesh: ImmediateMesh
static var _beam_material: StandardMaterial3D = preload("uid://ntmcfd25jgpm")
var _instance: RID
var _scenario: RID
var _ray_query: PhysicsRayQueryParameters3D
var _distance_tag := OIPCommsTag.new()
var _output_tag := OIPCommsTag.new()
var _last_distance: float = -1.0
var _last_beam_color: Color = Color.TRANSPARENT
var _last_transform: Transform3D
var _beam_needs_update: bool = true
## Counter used to throttle the per-tick raycast to ~30 Hz (every 4th
## physics tick at the project's 120 Hz rate). 33 ms detection latency
## is well within typical PLC scan rates and the cached `distance` /
## `_last_*` state stays valid between samples.
var _scan_tick: int = 0

@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group for writing distance values to external systems.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value
## The tag name for the distance value in the selected tag group.[br]Datatype: [code]REAL[/code] (32-bit float)[br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]hr0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var tag_name: String = ""
## The tag name for the boolean detection output in the selected tag group.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var output_tag_name: String = ""


func _validate_property(property: Dictionary) -> void:
	if property.name == "distance":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	elif property.name == "detected":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	elif property.name == "output":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	elif not OIPCommsSetup.validate_tag_property(property):
		OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", "output_tag_name")


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


func _exit_tree() -> void:
	RenderingServer.free_rid(_instance)
	SensorBeamCache.clear_beam(get_instance_id())
	Simulation.started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized)


func _physics_process(_delta: float) -> void:
	_scan_tick += 1
	if _scan_tick % 4 != 0:
		return
	var start_pos := global_position
	var dir := global_transform.basis.z.normalized()
	var end_pos := start_pos + dir * max_range

	_ray_query.from = start_pos
	_ray_query.to = end_pos
	var space_state := get_world_3d().direct_space_state
	var result := space_state.intersect_ray(_ray_query)

	var has_detection := result.size() > 0
	detected = has_detection

	var new_distance: float
	var beam_color: Color
	if has_detection:
		new_distance = start_pos.distance_to(result["position"])
		beam_color = Color.RED
	else:
		new_distance = max_range
		beam_color = Color.GREEN

	distance = new_distance

	var current_transform := global_transform
	var beam_end := start_pos + dir * new_distance
	if _beam_needs_update or new_distance != _last_distance or beam_color != _last_beam_color or current_transform != _last_transform:
		if show_beam:
			_update_beam_mesh(start_pos, new_distance, beam_color)
		SensorBeamCache.set_beam(get_instance_id(), start_pos, beam_end)
		_last_distance = new_distance
		_last_beam_color = beam_color
		_last_transform = current_transform
		_beam_needs_update = false


func _update_beam_mesh(start_pos: Vector3, beam_distance: float, beam_color: Color) -> void:
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _beam_material)
	_mesh.surface_set_color(beam_color)
	_mesh.surface_add_vertex(start_pos)
	_mesh.surface_set_color(beam_color)
	_mesh.surface_add_vertex(start_pos + global_transform.basis.z.normalized() * beam_distance)
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
		_distance_tag.register(tag_group_name, tag_name)
		_output_tag.register(tag_group_name, output_tag_name)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	if _distance_tag.on_group_initialized(tag_group_name_param):
		_distance_tag.write_float32(distance)
	if _output_tag.on_group_initialized(tag_group_name_param):
		_output_tag.write_bit(output)
