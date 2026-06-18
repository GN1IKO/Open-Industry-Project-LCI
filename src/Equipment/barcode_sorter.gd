@tool
class_name BarcodeSorter
extends Node3D

## Routes parcels by a [CameraTunnelUnit]'s read result. It listens to the tunnel's
## [signal CameraTunnelUnit.barcode_read]; for each parcel that matches [member sort_mode]
## it fires the assigned [Diverter] after [member divert_delay] — the time the parcel takes
## to travel from the read gate to the diverter. Typical use: NO_READ rejects unreadable
## parcels into a reject lane, just like a real sortation line.

enum SortMode { NO_READ, EVEN_VALUE, ODD_VALUE, ALWAYS }

## The CameraTunnel whose reads drive the sort.
@export var camera_tunnel: CameraTunnelUnit
## The Diverter fired to route matching parcels off the main line.
@export var diverter: Diverter
## Which parcels get diverted.
@export var sort_mode: SortMode = SortMode.NO_READ
## Seconds from the read to when the parcel reaches the diverter (its travel time).
@export_range(0.0, 10.0, 0.05, "suffix:s") var divert_delay: float = 1.2

var _queue: Array[float] = []
var _t: float = 0.0
var _connected: bool = false


func _ready() -> void:
	_connect()


func _connect() -> void:
	if _connected or camera_tunnel == null or not is_instance_valid(camera_tunnel):
		return
	if not camera_tunnel.barcode_read.is_connected(_on_read):
		camera_tunnel.barcode_read.connect(_on_read)
	_connected = true


func _exit_tree() -> void:
	if _connected and camera_tunnel != null and is_instance_valid(camera_tunnel) \
			and camera_tunnel.barcode_read.is_connected(_on_read):
		camera_tunnel.barcode_read.disconnect(_on_read)
	_connected = false


func _on_read(_code: String, value: int, _optical: bool) -> void:
	if _should_divert(value):
		_queue.append(_t + divert_delay)


func _should_divert(value: int) -> bool:
	match sort_mode:
		SortMode.NO_READ:
			return value < 0
		SortMode.EVEN_VALUE:
			return value >= 0 and value % 2 == 0
		SortMode.ODD_VALUE:
			return value >= 0 and value % 2 == 1
		SortMode.ALWAYS:
			return true
	return false


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not Simulation.is_running():
		return
	if not _connected:
		_connect()
	_t += delta
	while not _queue.is_empty() and _queue[0] <= _t:
		_queue.pop_front()
		if diverter != null and is_instance_valid(diverter):
			diverter.divert()
