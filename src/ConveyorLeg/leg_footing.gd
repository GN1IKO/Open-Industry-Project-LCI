@tool
class_name LegFooting
extends RefCounted


static func resolve_foot(conveyor: Node3D, belt_bottom_world: Vector3,
		legs_normal_world: Vector3, fallback_plane: Plane) -> Variant:
	if conveyor.is_inside_tree() and Engine.is_in_physics_frame():
		var world := conveyor.get_world_3d()
		if world != null and world.direct_space_state != null:
			var exclude_rids: Array[RID] = []
			_collect_collision_rids(conveyor, exclude_rids)
			var query := PhysicsRayQueryParameters3D.new()
			query.from = belt_bottom_world
			query.to = belt_bottom_world - legs_normal_world * 100.0
			query.exclude = exclude_rids
			var hit := world.direct_space_state.intersect_ray(query)
			if not hit.is_empty():
				var foot: Vector3 = hit.position
				return foot
	var foot_v: Variant = fallback_plane.intersects_ray(belt_bottom_world, -legs_normal_world)
	if foot_v == null:
		foot_v = fallback_plane.intersects_ray(belt_bottom_world, legs_normal_world)
	return foot_v


static func _collect_collision_rids(node: Node, out: Array[RID]) -> void:
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())
	for child in node.get_children(true):
		_collect_collision_rids(child, out)


static func capture_leg_state(node: Node3D) -> Dictionary:
	var s: Dictionary = {"xform": node.global_transform}
	if &"size" in node:
		s["size"] = node.get(&"size")
	if &"floor_plane" in node:
		s["floor_plane"] = node.get(&"floor_plane")
	return s


static func legs_state_changed(node: Node3D, last: Dictionary) -> bool:
	if last.is_empty():
		return true
	if node.global_transform != last.get("xform"):
		return true
	if &"size" in node and node.get(&"size") != last.get("size"):
		return true
	if &"floor_plane" in node and node.get(&"floor_plane") != last.get("floor_plane"):
		return true
	return false
