@tool
class_name CameraTunnelUnit
extends Node3D

## SICK ICR690 NON-CON camera tunnel. As a parcel passes the read gate the illuminators
## FLASH (the capture), the unit reads the parcel's barcode and reports it to the PLC, and
## the illumination turns GREEN (good read) / RED (no read). Auto-aligns onto a conveyor:
## centres across the belt and sits on it, so you slide it ALONG the conveyor length.
##
## Built only from the APIs the conveyors/spawner use (Area3D, MeshInstance3D emission,
## OIPComms tags, Simulation signals) so it compiles on the custom build.
##  PLC: trigger/good_read/no_read (BOOL out), barcode (INT32 out), lights (BOOL in).
## Nodes: Tunnel_Body (collision) / Cameras / Lights (the flash + status illumination).

const _ILLUM_PATH: String = "camera_tunnel/Lights"
const LIGHT_ENERGY: float = 1.5
const FLASH_ENERGY: float = 14.0
const FLASH_COUNT: int = 3
const FLASH_INTERVAL: float = 0.05
const READ_GATE_THICKNESS: float = 0.30
const COL_READY: Color = Color(0.9, 0.9, 0.85)
const COL_GOOD: Color = Color(0.1, 1.0, 0.2)
const COL_NOREAD: Color = Color(1.0, 0.1, 0.1)

## Steady scan illumination on/off (overridden by the lights PLC tag when comms enabled).
@export var lights_on: bool = false:
	set(value):
		lights_on = value
		_apply_lights()
## Enable the read gate / flash / reporting during simulation.
@export var scan_enabled: bool = true
## Belt width the read gate spans.
@export_range(0.4, 2.0, 0.01, "suffix:m") var gate_width: float = 1.219
## Height of the read aperture above belt top.
@export_range(0.2, 2.0, 0.01, "suffix:m") var gate_height: float = 1.1
## Show the running read-statistics HMI text on the tunnel.
@export var show_hmi: bool = true

@export_group("Conveyor Align")
## Auto-align onto the nearest conveyor (within 3 m): centre across the belt + align heading,
## then slide freely ALONG the conveyor length. Turn off for fully free placement.
@export var snap_to_conveyor: bool = true

var _illum: MeshInstance3D = null
var _illum_mats: Array[StandardMaterial3D] = []
var _area: Area3D = null
var _flash_timer: float = 0.0
var _flashes_left: int = 0
var _in_zone: int = 0
var _scanned: Dictionary = {}
var _good_read_hold: float = 0.0
var _aligning: bool = false
var _status: Color = COL_READY
var _hmi: Label3D = null

var _stat_total: int = 0
var _stat_good: int = 0
var _stat_noread: int = 0
var _stat_last: String = ""
var _run_time: float = 0.0

## Emitted on every read: full string, numeric value, optical (always false here — read by data).
signal barcode_read(code: String, value: int, optical: bool)


func _ready() -> void:
	_cache_illum()
	_apply_lights()
	if Engine.is_editor_hint():
		set_notify_transform(true)
	if Simulation.is_running():
		_build_runtime()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint() \
			and snap_to_conveyor and not _aligning and is_inside_tree():
		_align_to_conveyor()


# ---------- conveyor align ----------
func _align_to_conveyor() -> void:
	var conv: Node3D = _find_nearest_conveyor()
	if conv == null:
		return
	var ct: Transform3D = conv.global_transform
	var axis: Vector3 = ct.basis.x
	axis.y = 0.0
	if axis.length() < 0.0001:
		return
	axis = axis.normalized()
	var pos: Vector3 = global_transform.origin
	var along: float = (pos - ct.origin).dot(axis)
	var center: Vector3 = ct.origin + axis * along    # nearest point on the belt centre line
	center.y = ct.origin.y                             # sit on the conveyor (its surface height)
	var b: Basis = Basis()
	b.x = axis
	b.z = axis.cross(Vector3.UP).normalized()
	b.y = b.z.cross(b.x).normalized()
	var target: Transform3D = Transform3D(b.orthonormalized(), center)
	if global_transform.is_equal_approx(target):
		return
	_aligning = true
	global_transform = target
	_aligning = false


func _find_nearest_conveyor() -> Node3D:
	var root: Node = get_tree().edited_scene_root
	if root == null:
		root = get_tree().current_scene
	if root == null:
		return null
	var best: Node3D = null
	var best_d: float = 3.0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n is Node3D and n != self and _is_conveyor_node(n):
			var d: Vector3 = (n as Node3D).global_position - global_position
			d.y = 0.0
			if d.length() < best_d:
				best_d = d.length()
				best = n as Node3D
	return best


func _is_conveyor_node(n: Node) -> bool:
	var s: Script = n.get_script()
	var gn: String = String(s.get_global_name()) if s != null else ""
	return gn in ["BeltConveyor", "RollerConveyor", "BeltSpurConveyor", "RollerSpurConveyor", "CurvedBeltConveyor", "CurvedRollerConveyor"]


# ---------- illumination (flash + status colour on the Lights node) ----------
func _cache_illum() -> void:
	_illum = get_node_or_null(NodePath(_ILLUM_PATH)) as MeshInstance3D
	_illum_mats.clear()
	if _illum == null or _illum.mesh == null:
		return
	for i: int in _illum.mesh.get_surface_count():
		var base: Material = _illum.mesh.surface_get_material(i)
		if base is StandardMaterial3D:
			var m: StandardMaterial3D = (base as StandardMaterial3D).duplicate()
			_illum.set_surface_override_material(i, m)
			_illum_mats.append(m)


func _apply_lights() -> void:
	if _illum == null or not is_instance_valid(_illum):
		_cache_illum()
	var e: float = LIGHT_ENERGY if lights_on else 0.0
	for m: StandardMaterial3D in _illum_mats:
		m.emission_enabled = true
		m.emission = _status
		m.emission_energy_multiplier = e


func _set_flash(energy: float) -> void:
	for m: StandardMaterial3D in _illum_mats:
		m.emission_enabled = true
		m.emission = _status
		m.emission_energy_multiplier = energy if energy > 0.0 else (LIGHT_ENERGY if lights_on else 0.0)


func _set_status(col: Color) -> void:
	_status = col
	for m: StandardMaterial3D in _illum_mats:
		m.emission = col


# ---------- runtime (sim only) ----------
func _build_runtime() -> void:
	if _area != null and is_instance_valid(_area):
		return
	_area = Area3D.new()
	_area.name = "ReadGate"
	_area.collision_mask = 0xFFFFFFFF
	_area.monitoring = true
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(READ_GATE_THICKNESS, gate_height, gate_width)
	cs.shape = box
	cs.position = Vector3(0.0, gate_height * 0.5, 0.0)
	_area.add_child(cs)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)
	if show_hmi:
		_hmi = Label3D.new()
		_hmi.name = "HMI"
		_hmi.pixel_size = 0.0012
		_hmi.font_size = 48
		_hmi.modulate = COL_GOOD
		_hmi.outline_size = 10
		_hmi.outline_modulate = Color.BLACK
		_hmi.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_hmi.no_depth_test = true
		_hmi.position = Vector3(0.0, 2.2, 0.0)
		add_child(_hmi)
	_reset_stats()


func _teardown_runtime() -> void:
	if _area != null and is_instance_valid(_area):
		_area.queue_free()
	if _hmi != null and is_instance_valid(_hmi):
		_hmi.queue_free()
	_area = null
	_hmi = null
	_in_zone = 0
	_scanned.clear()
	_set_status(COL_READY)
	_set_flash(0.0)


func _reset_stats() -> void:
	_stat_total = 0
	_stat_good = 0
	_stat_noread = 0
	_stat_last = ""
	_run_time = 0.0
	_update_hmi()


func _update_hmi() -> void:
	if _hmi == null or not is_instance_valid(_hmi):
		return
	var rate: float = (100.0 * float(_stat_good) / float(_stat_total)) if _stat_total > 0 else 0.0
	var tph: float = (60.0 * float(_stat_total) / _run_time) if _run_time > 0.5 else 0.0
	_hmi.text = "ICR690 READ\nSCANNED %d\nGOOD %d (%.0f%%)\nNO-READ %d\n%.0f/min\n%s" % [
		_stat_total, _stat_good, rate, _stat_noread, tph,
		(_stat_last if _stat_last != "" else "-")]


func _on_body_entered(body: Node3D) -> void:
	if not scan_enabled:
		return
	_in_zone += 1
	_write_bit(_trigger_tag, true)
	var id: int = body.get_instance_id()
	if _scanned.has(id):
		return
	_scanned[id] = true
	_capture(body)


func _on_body_exited(body: Node3D) -> void:
	_in_zone = max(0, _in_zone - 1)
	if _in_zone == 0:
		_write_bit(_trigger_tag, false)
	_scanned.erase(body.get_instance_id())


func _capture(body: Node3D) -> void:
	_flashes_left = FLASH_COUNT
	_flash_timer = 0.0
	_set_flash(FLASH_ENERGY)
	var value: int = int(body.get_meta("barcode_value", -1))
	_stat_total += 1
	if value >= 0:
		if _barcode_tag.is_ready():
			_barcode_tag.write_int32(value)
		_write_bit(_good_read_tag, true)
		_good_read_hold = 0.4
		_stat_good += 1
		_stat_last = String(body.get_meta("barcode_string", str(value)))
		_set_status(COL_GOOD)
		barcode_read.emit(_stat_last, value, false)
	else:
		_write_bit(_no_read_tag, true)
		_good_read_hold = 0.4
		_stat_noread += 1
		_set_status(COL_NOREAD)
		barcode_read.emit("", -1, false)
	_update_hmi()


func _physics_process(delta: float) -> void:
	if not Simulation.is_running():
		return
	_run_time += delta
	if _flashes_left > 0 or _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			if _flashes_left > 0:
				_flashes_left -= 1
				_set_flash(FLASH_ENERGY)
				_flash_timer = FLASH_INTERVAL
			else:
				_set_flash(0.0)
		elif _flash_timer < FLASH_INTERVAL * 0.5:
			_set_flash(0.0)
	if _good_read_hold > 0.0:
		_good_read_hold -= delta
		if _good_read_hold <= 0.0:
			_write_bit(_good_read_tag, false)
			_write_bit(_no_read_tag, false)
			if _in_zone == 0:
				_set_status(COL_READY)
				_set_flash(0.0)


#region PLC
@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var lights_tag_group_name: String
## Tag group for the lights command.
@export_custom(0, "tag_group_enum") var lights_tag_groups: String:
	set(value):
		lights_tag_group_name = value
		lights_tag_groups = value
## Command tag (READ): TRUE forces scan illumination on.[br]Datatype: [code]BOOL[/code]
@export var lights_tag_name: String = ""
@export var trigger_tag_group_name: String
## Tag group for the trigger/photoeye status.
@export_custom(0, "tag_group_enum") var trigger_tag_groups: String:
	set(value):
		trigger_tag_group_name = value
		trigger_tag_groups = value
## Status tag (WRITE): TRUE while a parcel is in the read gate.[br]Datatype: [code]BOOL[/code]
@export var trigger_tag_name: String = ""
@export var good_read_tag_group_name: String
## Tag group for the good-read pulse.
@export_custom(0, "tag_group_enum") var good_read_tag_groups: String:
	set(value):
		good_read_tag_group_name = value
		good_read_tag_groups = value
## Status tag (WRITE): pulses TRUE on a successful read.[br]Datatype: [code]BOOL[/code]
@export var good_read_tag_name: String = ""
@export var no_read_tag_group_name: String
## Tag group for the no-read pulse.
@export_custom(0, "tag_group_enum") var no_read_tag_groups: String:
	set(value):
		no_read_tag_group_name = value
		no_read_tag_groups = value
## Status tag (WRITE): pulses TRUE when a parcel passes with no code.[br]Datatype: [code]BOOL[/code]
@export var no_read_tag_name: String = ""
@export var barcode_tag_group_name: String
## Tag group for the decoded barcode value.
@export_custom(0, "tag_group_enum") var barcode_tag_groups: String:
	set(value):
		barcode_tag_group_name = value
		barcode_tag_groups = value
## Data tag (WRITE): numeric value of the last good read.[br]Datatype: [code]INT32[/code]
@export var barcode_tag_name: String = ""

var _lights_tag: OIPCommsTag = OIPCommsTag.new()
var _trigger_tag: OIPCommsTag = OIPCommsTag.new()
var _good_read_tag: OIPCommsTag = OIPCommsTag.new()
var _no_read_tag: OIPCommsTag = OIPCommsTag.new()
var _barcode_tag: OIPCommsTag = OIPCommsTag.new()


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "lights_tag_group_name", "lights_tag_groups", "lights_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "trigger_tag_group_name", "trigger_tag_groups", "trigger_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "good_read_tag_group_name", "good_read_tag_groups", "good_read_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "no_read_tag_group_name", "no_read_tag_groups", "no_read_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "barcode_tag_group_name", "barcode_tag_groups", "barcode_tag_name"):
		return


func _enter_tree() -> void:
	lights_tag_group_name = OIPCommsSetup.default_tag_group(lights_tag_group_name)
	trigger_tag_group_name = OIPCommsSetup.default_tag_group(trigger_tag_group_name)
	good_read_tag_group_name = OIPCommsSetup.default_tag_group(good_read_tag_group_name)
	no_read_tag_group_name = OIPCommsSetup.default_tag_group(no_read_tag_group_name)
	barcode_tag_group_name = OIPCommsSetup.default_tag_group(barcode_tag_group_name)
	if not Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.connect(_on_simulation_started)
	if not Simulation.stopped.is_connected(_on_simulation_stopped):
		Simulation.stopped.connect(_on_simulation_stopped)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _exit_tree() -> void:
	if Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.disconnect(_on_simulation_started)
	if Simulation.stopped.is_connected(_on_simulation_stopped):
		Simulation.stopped.disconnect(_on_simulation_stopped)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _write_bit(tag: OIPCommsTag, value: bool) -> void:
	if enable_comms and tag.is_ready():
		tag.write_bit(value)


func _on_simulation_started() -> void:
	_build_runtime()
	if enable_comms:
		_lights_tag.register(lights_tag_group_name, lights_tag_name, OIPComms.TAG_TYPE_BOOL)
		_trigger_tag.register(trigger_tag_group_name, trigger_tag_name, OIPComms.TAG_TYPE_BOOL)
		_good_read_tag.register(good_read_tag_group_name, good_read_tag_name, OIPComms.TAG_TYPE_BOOL)
		_no_read_tag.register(no_read_tag_group_name, no_read_tag_name, OIPComms.TAG_TYPE_BOOL)
		_barcode_tag.register(barcode_tag_group_name, barcode_tag_name, OIPComms.TAG_TYPE_INT32)


func _on_simulation_stopped() -> void:
	_teardown_runtime()


func _tag_group_initialized(tag_group_name_param: String) -> void:
	_lights_tag.on_group_initialized(tag_group_name_param)
	_trigger_tag.on_group_initialized(tag_group_name_param)
	_good_read_tag.on_group_initialized(tag_group_name_param)
	_no_read_tag.on_group_initialized(tag_group_name_param)
	_barcode_tag.on_group_initialized(tag_group_name_param)


func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms:
		return
	if _lights_tag.matches_group(tag_group_name_param) and _lights_tag.is_ready():
		var v: bool = _lights_tag.read_bit()
		if v != lights_on:
			lights_on = v
#endregion # PLC
