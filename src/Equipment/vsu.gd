@tool
class_name VSUUnit
extends Node3D

## Vertical Sort Unit — a PIVOTING transfer. The rear edge (the hinge, where it aligns to the
## infeed conveyor) stays put; the NOSE (front) tilts DOWN or UP to discharge a parcel to a
## lower or a higher conveyor. The belt carries the parcel along. Driven manually or by PLC.
##
## Knobs if the pivot looks wrong on your build: set the discharge angles with
## [member tilt_up_deg] / [member tilt_down_deg].
##
## PLC: lift (BOOL) → nose UP, lower (BOOL) → nose DOWN, run (BOOL) → belt, lift_state (BOOL write,
## TRUE while tilted). Nodes: VSU_Frame (collision) / VSU_LiftConveyor (the pivoting belt).

const _CONV_PATH: String = "vsu/VSU_LiftConveyor"

enum LiftPos { DOWN, UP }

@export_group("Lift (pivot)")
## Nose position: Down (discharge low) or Up (discharge high). Only these two —
## the fixed (rear/right) end stays put, the nose swings between down and up.
@export var lift_position: LiftPos = LiftPos.DOWN:
	set(value):
		lift_position = value
		_comms_write_state(value == LiftPos.UP)
## Nose-up discharge angle, degrees.
@export_range(0.0, 60.0, 0.5, "suffix:deg") var tilt_up_deg: float = 8.0
## Nose-down discharge angle, degrees.
@export_range(0.0, 60.0, 0.5, "suffix:deg") var tilt_down_deg: float = 22.0
## Tilt speed, degrees per second.
@export_range(2.0, 180.0, 1.0, "suffix:deg/s") var tilt_speed: float = 35.0

@export_group("Belt")
## Run the belt (carries parcels along the conveyor).
@export var belt_running: bool = false
## Belt speed, metres per second.
@export_range(0.0, 10.0, 0.05, "suffix:m/s") var belt_speed: float = 1.0
## Flip belt direction.
@export var belt_reverse: bool = false

@export_group("Legs")
## World Y the support feet rest on (the floor). The steel posts stretch from the
## unit DOWN to here, so raising the VSU with the move gizmo lengthens the legs and
## the feet stay planted on the floor — the unit is never lifted off its legs.
@export var floor_y: float = 0.0:
	set(value):
		floor_y = value
		_update_legs()

var _conv: Node3D = null
var _body: StaticBody3D = null
var _base_xform: Transform3D = Transform3D.IDENTITY
var _hinge_local: Vector3 = Vector3.ZERO
var _tilt_axis_local: Vector3 = Vector3(1, 0, 0)
var _flow_local: Vector3 = Vector3(0, 0, 1)
var _cur_angle: float = 0.0
var _tilt_sign: float = 1.0
var _cached: bool = false
## Model-local XZ of the four support feet (under the frame's skid rails) + post half-thickness.
const _FOOT_XZ: Array[Vector2] = [Vector2(1.18, 1.65), Vector2(-1.18, 1.65), Vector2(1.18, -1.6), Vector2(-1.18, -1.6)]
const _POST_HALF: float = 0.09
const _POSTS_NODE: String = "_SupportPosts"
var _post_mesh: BoxMesh = null


func _ready() -> void:
	_cache()
	_apply_materials()
	# Undo any old support-height model lift (legs now reach the floor instead).
	var model: Node3D = get_node_or_null(NodePath("vsu")) as Node3D
	if model != null and not is_zero_approx(model.position.y):
		model.position = Vector3(model.position.x, 0.0, model.position.z)
	_update_legs()
	if Engine.is_editor_hint():
		set_notify_transform(true)


# The build doesn't reliably apply the GLB's embedded materials (renders white),
# so set them directly on the mesh surfaces here. Surface order matches the GLB
# primitives: Frame = [Metal, Motor, Hazard]; LiftConveyor = [Pan, Belt].
# The build does NOT keep the GLB material NAMES on the runtime surface materials
# (resource_name comes back empty → name-matching painted everything grey). And
# generate/physics may wrap VSU_Frame/VSU_LiftConveyor as a StaticBody3D with the
# real MeshInstance3D as a CHILD. So: walk to every MeshInstance3D, find which GLB
# mesh it belongs to via the nearest named ancestor, and paint by SURFACE INDEX
# (GLB primitive order survives import). Frame=[0]Metal [1]Motor [2]Hazard;
# Conveyor=[0]Pan [1]Belt.
func _apply_materials() -> void:
	var meshes: Array[MeshInstance3D] = []
	_collect_mesh_instances(self, meshes)
	for mi: MeshInstance3D in meshes:
		if mi.mesh == null:
			continue
		var group: String = _mesh_group(mi)
		# Per-surface override didn't render on this build's imported mesh, but a
		# whole-node material_override does. So give the VSU the SAME materials the
		# BeltConveyor uses: the conveyor mesh gets the belt-fabric shader, the rest
		# gets the steel conveyor-frame shader.
		if group == "conveyor":
			var belt: ShaderMaterial = BeltSurface.create_material(Color.WHITE, BeltConveyor.BeltTexture.STANDARD)
			belt.set_shader_parameter("Scale", 4.0)
			mi.material_override = belt
		else:
			mi.material_override = ConveyorFrameMesh.create_material()


func _collect_mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	var mi: MeshInstance3D = node as MeshInstance3D
	if mi != null:
		out.append(mi)
	for child: Node in node.get_children():
		_collect_mesh_instances(child, out)


# Nearest ancestor name tells us which GLB mesh this is (survives generate/physics).
func _mesh_group(mi: MeshInstance3D) -> String:
	var n: Node = mi
	while n != null and n != self:
		var nm: String = String(n.name).to_lower()
		if nm.contains("liftconveyor") or nm.contains("conveyor") or nm.contains("belt"):
			return "conveyor"
		if nm.contains("frame"):
			return "frame"
		n = n.get_parent()
	return "frame"


# Identify the surface by the IMPORTED material's albedo (the GLB colours survive
# onto the resource even when the build renders them wrong): very dark = belt,
# yellowish = hazard, else steel. Falls back to (group + surface index) if the
# albedo was flattened (e.g. all white), so it works either way.
func _make_material(group: String, idx: int, src_alb: Color) -> StandardMaterial3D:
	var mx: float = maxf(src_alb.r, maxf(src_alb.g, src_alb.b))
	var is_belt: bool = mx < 0.12
	var is_hazard: bool = src_alb.r > 0.5 and src_alb.b < 0.25 and src_alb.g > 0.3
	if not is_belt and not is_hazard:
		# albedo not distinctive → fall back to known GLB primitive order
		if group == "conveyor" and idx == 1:
			is_belt = true
		elif group == "frame" and idx == 2:
			is_hazard = true
	var col: Color = Color(0.48, 0.50, 0.55)   # steel (flat — metallic risks white-out in this build)
	var metal: float = 0.0
	var rough: float = 0.5
	if is_belt:
		col = Color(0.03, 0.03, 0.035)
		metal = 0.0
		rough = 0.95
	elif is_hazard:
		col = Color(0.88, 0.64, 0.04)
		metal = 0.0
		rough = 0.5
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.metallic = metal
	mat.roughness = rough
	return mat


func _notification(what: int) -> void:
	if what != NOTIFICATION_TRANSFORM_CHANGED or not is_inside_tree():
		return
	# Moving the unit (e.g. the Y gizmo) restretches the legs to the floor.
	_update_legs()


func _cache() -> void:
	if _cached:
		return
	_conv = get_node_or_null(NodePath(_CONV_PATH)) as Node3D
	if _conv == null:
		return
	_base_xform = _conv.transform
	_body = null
	for c: Node in _conv.get_children():
		if c is StaticBody3D:
			_body = c as StaticBody3D
	# Powered transfer belt: grip firmly so heavy parcels and queues don't slip on
	# the incline (the import's 0.5 friction stalls mid-belt once gravity-along-slope
	# plus a few boxes exceed it). High friction + rough combine = enough drag.
	if _body != null and is_instance_valid(_body):
		var pm: PhysicsMaterial = PhysicsMaterial.new()
		pm.friction = 2.0
		pm.rough = true
		pm.bounce = 0.0
		_body.physics_material_override = pm
	# hinge + tilt axis from the conveyor's local AABB (rear edge at the base)
	var aabb: AABB = AABB(Vector3(-0.8, 0, -0.6), Vector3(1.6, 0.2, 1.2))
	var vi: VisualInstance3D = _conv as VisualInstance3D
	if vi != null:
		aabb = vi.get_aabb()
	var flow_x: bool = aabb.size.x >= aabb.size.z
	var fa: int = 0 if flow_x else 2
	if flow_x:
		_flow_local = Vector3(1, 0, 0)
		_tilt_axis_local = Vector3(0, 0, 1)
	else:
		_flow_local = Vector3(0, 0, 1)
		_tilt_axis_local = Vector3(1, 0, 0)
	# Auto-detect which flow-end is physically LOWER — that end is the fixed hinge,
	# the raised end is the moving nose. Geometry-driven, so it cannot be fooled by
	# axis/orientation guesses.
	var hinge_at_max: bool = _lower_end_is_max(aabb, fa)
	var hinge_flow: float = aabb.end[fa] if hinge_at_max else aabb.position[fa]
	if flow_x:
		_hinge_local = Vector3(hinge_flow, aabb.position.y, aabb.get_center().z)
	else:
		_hinge_local = Vector3(aabb.get_center().x, aabb.position.y, hinge_flow)
	# Sign so a positive (UP) angle raises the far nose end.
	_tilt_sign = _compute_tilt_sign(aabb, fa, hinge_at_max)
	_cached = true


# True if the flow-MAX end is the physically lower end (sampled from the mesh).
func _lower_end_is_max(aabb: AABB, fa: int) -> bool:
	var mi: MeshInstance3D = _conv as MeshInstance3D
	if mi == null or mi.mesh == null:
		return true
	var fmin: float = aabb.position[fa]
	var fmax: float = aabb.end[fa]
	var span: float = maxf(fmax - fmin, 0.0001)
	var sum_lo: float = 0.0
	var n_lo: int = 0
	var sum_hi: float = 0.0
	var n_hi: int = 0
	for s: int in range(mi.mesh.get_surface_count()):
		var arr: Array = mi.mesh.surface_get_arrays(s)
		if arr.size() <= Mesh.ARRAY_VERTEX:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v: Vector3 in verts:
			var t: float = (v[fa] - fmin) / span
			# Split at the midpoint so both halves are always populated (quartiles
			# could be empty on centred meshes); compares the two flow-halves' height.
			if t < 0.5:
				sum_lo += v.y
				n_lo += 1
			else:
				sum_hi += v.y
				n_hi += 1
	if n_lo == 0 or n_hi == 0:
		return true
	return (sum_hi / float(n_hi)) < (sum_lo / float(n_lo))


# +1 if a positive angle raises the far nose end, else -1 (tested on the geometry).
func _compute_tilt_sign(aabb: AABB, fa: int, hinge_at_max: bool) -> float:
	var nose_flow: float = aabb.position[fa] if hinge_at_max else aabb.end[fa]
	var c: Vector3 = aabb.get_center()
	# Test the nose at the hinge's height (aabb bottom) so it is a pure pivot about the edge.
	var hy: float = aabb.position.y
	var nose_local: Vector3 = Vector3(nose_flow, hy, c.z) if fa == 0 else Vector3(c.x, hy, nose_flow)
	var axis_parent: Vector3 = (_base_xform.basis * _tilt_axis_local).normalized()
	var pivot_parent: Vector3 = _base_xform * _hinge_local
	var nose_parent: Vector3 = _base_xform * nose_local
	var rot: Basis = Basis(axis_parent, deg_to_rad(1.0))
	var rotated: Vector3 = pivot_parent + rot * (nose_parent - pivot_parent)
	return 1.0 if rotated.y > nose_parent.y else -1.0


func _apply_pivot(angle_deg: float) -> void:
	if _conv == null or not is_instance_valid(_conv):
		return
	var axis_parent: Vector3 = (_base_xform.basis * _tilt_axis_local).normalized()
	var pivot_parent: Vector3 = _base_xform * _hinge_local
	var rot: Basis = Basis(axis_parent, deg_to_rad(angle_deg * _tilt_sign))
	var nb: Basis = rot * _base_xform.basis
	var no: Vector3 = pivot_parent + rot * (_base_xform.origin - pivot_parent)
	_conv.transform = Transform3D(nb, no)


func _physics_process(delta: float) -> void:
	_cache()
	if _conv == null:
		return
	var target: float = -tilt_down_deg
	if lift_position == LiftPos.UP:
		target = tilt_up_deg
	if not is_equal_approx(_cur_angle, target):
		_cur_angle = move_toward(_cur_angle, target, tilt_speed * delta)
		_apply_pivot(_cur_angle)
	if _body != null and is_instance_valid(_body):
		if belt_running and not is_zero_approx(belt_speed):
			# Default flows toward the discharge nose; `belt_reverse` flips it the other way.
			var dir: Vector3 = (_conv.global_transform.basis * _flow_local).normalized() * (1.0 if belt_reverse else -1.0)
			_body.constant_linear_velocity = dir * belt_speed
		else:
			_body.constant_linear_velocity = Vector3.ZERO


# ---------- support legs (feet planted on the floor, posts stretch) ----------
# The 4 steel posts hang from the unit (local Y=0, the skid line) DOWN to `floor_y`
# (world). When the unit is raised with the move gizmo, the posts lengthen so the
# feet stay on the floor instead of the unit lifting off them. Cheap: 4 instances
# share one BoxMesh; only its height + the posts' Y offset change per move.
func _update_legs() -> void:
	if not is_inside_tree():
		return
	var leg_len: float = maxf(0.0, global_position.y - floor_y)
	var holder: Node3D = get_node_or_null(NodePath(_POSTS_NODE)) as Node3D
	if holder == null:
		holder = Node3D.new()
		holder.name = _POSTS_NODE
		add_child(holder, false, Node.INTERNAL_MODE_FRONT)
		_post_mesh = BoxMesh.new()
		var steel: ShaderMaterial = ConveyorFrameMesh.create_material()
		for foot: Vector2 in _FOOT_XZ:
			var mi: MeshInstance3D = MeshInstance3D.new()
			mi.mesh = _post_mesh
			mi.material_override = steel
			mi.position = Vector3(foot.x, 0.0, foot.y)
			holder.add_child(mi)
	if _post_mesh != null:
		_post_mesh.size = Vector3(_POST_HALF * 2.0, maxf(leg_len, 0.001), _POST_HALF * 2.0)
	holder.visible = leg_len > 0.01
	for child: Node in holder.get_children():
		var post: MeshInstance3D = child as MeshInstance3D
		if post != null:
			post.position = Vector3(post.position.x, -leg_len * 0.5, post.position.z)


#region PLC
@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var lift_tag_group_name: String
## The tag group for the nose-up command.
@export_custom(0, "tag_group_enum") var lift_tag_groups: String:
	set(value):
		lift_tag_group_name = value
		lift_tag_groups = value
## Command tag (READ): TRUE tilts the nose UP.[br]Datatype: [code]BOOL[/code]
@export var lift_tag_name: String = ""
@export var lower_tag_group_name: String
## The tag group for the nose-down command.
@export_custom(0, "tag_group_enum") var lower_tag_groups: String:
	set(value):
		lower_tag_group_name = value
		lower_tag_groups = value
## Command tag (READ): TRUE tilts the nose DOWN.[br]Datatype: [code]BOOL[/code]
@export var lower_tag_name: String = ""
@export var run_tag_group_name: String
## The tag group for the belt run command.
@export_custom(0, "tag_group_enum") var run_tag_groups: String:
	set(value):
		run_tag_group_name = value
		run_tag_groups = value
## Command tag (READ): TRUE runs the belt.[br]Datatype: [code]BOOL[/code]
@export var run_tag_name: String = ""
@export var lift_state_tag_group_name: String
## The tag group for the lift state feedback.
@export_custom(0, "tag_group_enum") var lift_state_tag_groups: String:
	set(value):
		lift_state_tag_group_name = value
		lift_state_tag_groups = value
## Status tag (WRITE): TRUE while the nose is tilted (up or down).[br]Datatype: [code]BOOL[/code]
@export var lift_state_tag_name: String = ""

var _lift_tag: OIPCommsTag = OIPCommsTag.new()
var _lower_tag: OIPCommsTag = OIPCommsTag.new()
var _run_tag: OIPCommsTag = OIPCommsTag.new()
var _lift_state_tag: OIPCommsTag = OIPCommsTag.new()


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "lift_tag_group_name", "lift_tag_groups", "lift_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "lower_tag_group_name", "lower_tag_groups", "lower_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "run_tag_group_name", "run_tag_groups", "run_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "lift_state_tag_group_name", "lift_state_tag_groups", "lift_state_tag_name"):
		return


func _enter_tree() -> void:
	lift_tag_group_name = OIPCommsSetup.default_tag_group(lift_tag_group_name)
	lower_tag_group_name = OIPCommsSetup.default_tag_group(lower_tag_group_name)
	run_tag_group_name = OIPCommsSetup.default_tag_group(run_tag_group_name)
	lift_state_tag_group_name = OIPCommsSetup.default_tag_group(lift_state_tag_group_name)
	if not Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _exit_tree() -> void:
	if Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _comms_write_state(tilted_now: bool) -> void:
	if _lift_state_tag.is_ready():
		_lift_state_tag.write_bit(tilted_now)


func _on_simulation_started() -> void:
	if enable_comms:
		_lift_tag.register(lift_tag_group_name, lift_tag_name, OIPComms.TAG_TYPE_BOOL)
		_lower_tag.register(lower_tag_group_name, lower_tag_name, OIPComms.TAG_TYPE_BOOL)
		_run_tag.register(run_tag_group_name, run_tag_name, OIPComms.TAG_TYPE_BOOL)
		_lift_state_tag.register(lift_state_tag_group_name, lift_state_tag_name, OIPComms.TAG_TYPE_BOOL)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	_lift_tag.on_group_initialized(tag_group_name_param)
	_lower_tag.on_group_initialized(tag_group_name_param)
	_run_tag.on_group_initialized(tag_group_name_param)
	if _lift_state_tag.on_group_initialized(tag_group_name_param):
		_lift_state_tag.write_bit(lift_position == LiftPos.UP)


func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms:
		return
	var up: bool = false
	var down: bool = false
	if _lift_tag.matches_group(tag_group_name_param) and _lift_tag.is_ready():
		up = _lift_tag.read_bit()
	if _lower_tag.matches_group(tag_group_name_param) and _lower_tag.is_ready():
		down = _lower_tag.read_bit()
	if _lift_tag.is_ready() or _lower_tag.is_ready():
		var want: LiftPos = LiftPos.DOWN
		if up:
			want = LiftPos.UP
		elif down:
			want = LiftPos.DOWN
		if want != lift_position:
			lift_position = want
	if _run_tag.matches_group(tag_group_name_param) and _run_tag.is_ready():
		belt_running = _run_tag.read_bit()
#endregion # PLC
