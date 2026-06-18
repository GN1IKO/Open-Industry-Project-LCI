@tool
class_name ColorSensor
extends Node3D

## Maximum detection range of the color sensor in meters.
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
		if _output_tag.is_ready() and value != output:
			_output_tag.write_bit(value)
		output = value

## The color currently detected by the sensor (read-only).
@export var color_detected: Color = Color.BLACK:
	set(value):
		color_detected = value
		_update_color_value()

## Maps detected colors to integer values for PLC communication.
@export var color_map: Dictionary[Color, int] = {
	Color.RED: 1,
	Color.GREEN: 2,
	Color.BLUE: 3
}:
	set(value):
		color_map = value
		_update_color_value()

## Integer value corresponding to detected color from color_map (read-only).
@export var color_value: int = 0:
	set(value):
		if _color_tag.is_ready() and value != color_value:
			_color_tag.write_int32(value)
		color_value = value

var _mesh: ImmediateMesh
static var _beam_material: StandardMaterial3D = preload("uid://ntmcfd25jgpm")
var _instance: RID
var _scenario: RID
var _ray_query: PhysicsRayQueryParameters3D
var _color_tag := OIPCommsTag.new()
var _output_tag := OIPCommsTag.new()
var _last_result_distance: float = -1.0
var _last_beam_color: Color = Color.TRANSPARENT
var _last_transform: Transform3D
var _beam_needs_update: bool = true

@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group for writing color values to external systems.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value
## The tag name for the color value in the selected tag group.[br]Datatype: [code]DINT[/code] (32-bit integer)[br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]hr0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var tag_name: String = ""
## The tag name for the boolean detection output in the selected tag group.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var output_tag_name: String = ""


func _validate_property(property: Dictionary) -> void:
	if property.name == "color_detected":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	elif property.name == "color_value":
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
	var start_pos := global_transform.translated_local(Vector3(0, 0.25, 0.42)).origin
	var dir := global_transform.basis.z.normalized()
	var end_pos := start_pos + dir * max_range

	_ray_query.from = start_pos
	_ray_query.to = end_pos
	var space_state := get_world_3d().direct_space_state
	var result := space_state.intersect_ray(_ray_query)
	var result_distance := max_range
	var has_detection := result.size() > 0
	detected = has_detection

	if has_detection:
		result_distance = start_pos.distance_to(result["position"])
		var collider: CollisionObject3D = result["collider"]
		var mesh_instance: MeshInstance3D = collider.get_node("MeshInstance3D")

		var material: StandardMaterial3D = mesh_instance.get_surface_override_material(0)
		if not material:
			material = mesh_instance.mesh.surface_get_material(0)

		color_detected = material.albedo_color
	else:
		color_detected = Color.TRANSPARENT

	var beam_color := color_detected if color_detected != Color.TRANSPARENT else Color.GREEN
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


func _update_color_value() -> void:
	if color_map.has(color_detected):
		color_value = color_map[color_detected]
	else:
		color_value = 0


func _update_output() -> void:
	var new_output := detected
	if normally_closed:
		new_output = !detected
	output = new_output


func _on_simulation_started() -> void:
	if enable_comms:
		_color_tag.register(tag_group_name, tag_name)
		_output_tag.register(tag_group_name, output_tag_name)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	if _color_tag.on_group_initialized(tag_group_name_param):
		_color_tag.write_int32(color_value)
	if _output_tag.on_group_initialized(tag_group_name_param):
		_output_tag.write_bit(output)
