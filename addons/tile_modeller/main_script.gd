@tool
extends EditorPlugin
class_name TileEditorPlugin

enum AxisDir { X_POS, X_NEG, Y_POS, Y_NEG, Z_POS, Z_NEG }

const TOOLBAR = preload("uid://cogsqfaa3p3rw")
var toolbar = TOOLBAR.instantiate()
const PlaneGZMscr = preload("uid://bfhag4hutu00u")
const VertexGZMScr := preload("uid://dgcrowpoxl2l4")
var vertexGZM := VertexGZMScr.new()
var planeGZM = PlaneGZMscr.new()
const UVEditPlug := preload("uid://bfhag4hutu00u")
const TILESET_PLUG := preload("uid://ds1ua8s3ma4um")
var TilesetPalette = TILESET_PLUG.new()
var UVEdit = UVEditPlug.new()
var editor_camera: Camera3D
var plane := Plane(Vector3.UP, 0.0) # y = 0 plane
var brush:TileModeller
var _drag_painting := false
var _last_stamp_cell : Vector3i = Vector3i(999999, 999999, 999999)
var _paint_selection: Array[Node] = []
var custom_quad_points

func _enter_tree():
	add_custom_type("TileModeller",
		"TileModeller",
		preload("uid://chmhpbke7rmjq"),
		preload("uid://db6f08svi1pat"))

	add_node_3d_gizmo_plugin(planeGZM)
	add_node_3d_gizmo_plugin(vertexGZM)

	add_inspector_plugin(UVEdit)
	add_inspector_plugin(TilesetPalette)
	set_input_event_forwarding_always_enabled()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU,toolbar)

func _ready() -> void:
	toolbar.tool_mode_selected.connect(_on_tool_mode_selected)
	toolbar.vertex_color_changed.connect(_on_vertex_color_changed)
	toolbar.vertex_snap_changed.connect(_on_vertex_snap_changed)
	toolbar.rotate_tile.connect(_on_rotate_tile)
	toolbar.export_mesh.connect(_on_export_mesh)


func _forward_3d_gui_input(
	viewport_camera: Camera3D,
	event: InputEvent
) -> int:

	var selection := get_editor_interface().get_selection()
	var selected := selection.get_selected_nodes()
	if selected.is_empty():
		return 0

	var brush: TileModeller = null
	var node := selected[0]
	if node is TileModeller:
		brush = node

	if brush == null:
		return 0

	if brush.select_mode == TileModeller.TileSelectMode.TILES:
		if node is TileModeller and node.tool_mode == TileModeller.TOOL_MODE.TILE:
			return _paint_tiles(event,selection,viewport_camera, brush)
	if brush.select_mode == TileModeller.TileSelectMode.CORNERS:
		if node is TileModeller and node.tool_mode == TileModeller.TOOL_MODE.TILE:
			var quad_points = get_custom_quad(viewport_camera,event, brush)
			planeGZM.custom_quad_points = quad_points
			return _paint_custom_quad(event,selection,viewport_camera,brush, quad_points)
	return 0

func _on_export_mesh():
	if brush:
		brush.export_mesh()

func _on_rotate_tile():
	if brush:
		brush.orientation = fmod(brush.orientation + 1, 4)

func _on_tool_mode_selected(mode:TileModeller.TOOL_MODE):
	if brush:
		brush.tool_mode = mode

func _on_vertex_color_changed(color:Color):
	if brush:
		brush.vertex_color = color

func _on_vertex_snap_changed(amount:int):
	if brush:
		brush.vertex_snap = amount

func _process(delta: float) -> void:
	if brush:
		brush.update_gizmos()

	if vertexGZM.active_gizmo == null:
		return
	if not vertexGZM.pending_snap:
		return

	var now := Time.get_ticks_msec() * 0.001
	var hover_time := now - vertexGZM.hover_start_time

	if hover_time >= vertexGZM.SNAP_HOVER_TIME:
		vertexGZM._force_snap()
		vertexGZM.pending_snap = false

static func get_axis_aligned_plane(camera: Camera3D, origin := Vector3.ZERO) -> Plane:
	var forward := -camera.global_transform.basis.z.normalized()

	var abs_f := Vector3(
		abs(forward.x),
		abs(forward.y),
		abs(forward.z)
	)

	var normal: Vector3

	if abs_f.x > abs_f.y and abs_f.x > abs_f.z:
		normal = Vector3(sign(forward.x), 0, 0)
	elif abs_f.y > abs_f.x and abs_f.y > abs_f.z:
		normal = Vector3(0, sign(forward.y), 0)
	else:
		normal = Vector3(0, 0, sign(forward.z))

	return Plane(normal, origin.dot(normal))
static func stable_plane_axes_from_normal(n: Vector3) -> Array[Vector3]:
	n = n.normalized()

	var up := Vector3.UP
	if abs(n.dot(up)) > 0.99:
		up = Vector3.RIGHT

	var right := up.cross(n).normalized()
	var down  := n.cross(right).normalized()

	# 🔒 Enforce deterministic orientation
	if right.dot(Vector3.RIGHT) > 0:
		right = -right
		down  = -down

	return [right, down]
static func orientation_index_from_normal(n: Vector3) -> int:
	n = n.normalized()

	# Use dominant axis
	if abs(n.x) > abs(n.y) and abs(n.x) > abs(n.z):
		return 1 if n.x > 0.0 else 3
	elif abs(n.y) > abs(n.z):
		return 3 if n.y > 0.0 else 1
	else:
		return 3 if n.z > 0.0 else 3

static func rotate_axes_in_plane(
	right: Vector3,
	down: Vector3,
	orientation: int
) -> Array[Vector3]:
	match orientation & 3:
		0:
			return [right, down]
		1: # 90° CW
			return [-down, right]
		2: # 180°
			return [-right, -down]
		3: # 270° CW
			return [down, -right]
	return [right, down]
static func basis_from_plane(normal: Vector3, orientation: int) -> Basis:
	normal = normal.normalized()

	var axes := stable_plane_axes_from_normal(normal)
	var rotated := rotate_axes_in_plane(axes[0], axes[1], orientation)

	var right := rotated[0]
	var down  := rotated[1]

	var b := Basis()
	b.x = right
	b.y = normal     
	b.z = down       
	return b


static func get_normal_axis_enum(normal: Vector3) -> AxisDir:
	normal = normal.normalized()

	var a = normal.abs()

	if a.x > a.y and a.x > a.z:
		return AxisDir.X_POS if normal.x > 0.0 else AxisDir.X_NEG
	elif a.y > a.x and a.y > a.z:
		return AxisDir.Y_POS if normal.y > 0.0 else AxisDir.Y_NEG
	else:
		return AxisDir.Z_POS if normal.z > 0.0 else AxisDir.Z_NEG


func _paint_custom_quad(event, selection, viewport_camera: Camera3D, brush: TileModeller, quad_points:Array) -> int:
	if event is InputEventKey and event.keycode == KEY_R and event.pressed and !event.echo:
		brush.orientation = int(fmod(brush.orientation + 1, 4))
		return 2
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_paint_selection = selection.get_selected_nodes().duplicate()
			_drag_painting = true
			_last_stamp_cell = Vector3i(999999, 999999, 999999)

			var bf = brush.brush_form
			if bf:
				bf.begin_quad_paint()

			_try_stamp_custom_quad(viewport_camera, event.position, brush, quad_points)
			_restore_paint_selection()
			return 2
		else:
			_drag_painting = false

			var bf = brush.brush_form
			if bf:
				bf.end_quad_paint()

			_restore_paint_selection()
			return 2

	# Dragging
	if event is InputEventMouseMotion and _drag_painting and event.button_mask == MOUSE_BUTTON_LEFT:
		_try_stamp_custom_quad(viewport_camera, event.position, brush, quad_points)
		_restore_paint_selection()
		return 2

	return 0

static func wall_face_offset(brush, normal: Vector3) -> Vector3:
	normal = normal.normalized()
	var value = Vector2(brush.vertex_snap, brush.vertex_snap)/ Vector2(brush.brush_form.pixels_to_world_unit,brush.brush_form.pixels_to_world_unit)
	if abs(normal.y) > 0.99:
		return Vector3.ZERO
	if normal.x > 0.9:
		return Vector3(0, value.y, 0)

	# -X wall
	if normal.x < -0.9:
		return Vector3(0, 0, value.x)

	# +Z wall
	if normal.z > 0.9:
		return Vector3(0, value.y, 0)

	# -Z wall
	if normal.z < -0.9:
		return Vector3(-value.x, 0, 0)

	return Vector3.ZERO

static func wall_face_offset2(normal,right, down,brush:TileModeller):
	normal = normal.normalized()
	var size = float(brush.tile_size.x)/float(brush.brush_form.pixels_to_world_unit)
	if abs(normal.y) > 0.99:
		return right * size + down * size
	if normal.x > 0.9:
		return right* size
	if normal.x < -0.9:
		return down* size
	if normal.z > 0.9:
		return right* size
	if normal.z < -0.9:
		return down* size

	return Vector3.ZERO

static func snap_point_to_plane_grid(
	point: Vector3,
	camera: Camera3D,
	normal: Vector3,
	grid_origin: Vector3,
	grid: Vector2
) -> Vector3:
	var tangent := normal.cross(Vector3.UP)
	if tangent.length_squared() < 0.001:
		tangent = normal.cross(Vector3.RIGHT)
	tangent = tangent.normalized()

	var bitangent := normal.cross(tangent).normalized()

	var plane_origin := grid_origin - normal * (grid_origin - point).dot(normal)

	var rel := point - plane_origin
	var u := rel.dot(tangent)
	var v := rel.dot(bitangent)

	match get_normal_axis_enum(normal):
		AxisDir.Y_NEG:
			u = round((u - grid.x * 0.5) / grid.x) * grid.x
			v = round((v + grid.y * 0.5) / grid.y) * grid.y
		AxisDir.X_NEG:
			u = round((u + grid.x * 0.5) / grid.x) * grid.x
			v = round((v - grid.y * 0.5) / grid.y) * grid.y
		AxisDir.Z_NEG:
			u = round((u + grid.x * 0.5) / grid.x) * grid.x
			v = round((v - grid.y * 0.5) / grid.y) * grid.y
		AxisDir.X_POS:
			u = round((u - grid.x * 0.5) / grid.x) * grid.x
			v = round((v + grid.y * 0.5) / grid.y) * grid.y
		AxisDir.Z_POS:
			u = round((u - grid.x * 0.5) / grid.x) * grid.x
			v = round((v + grid.y * 0.5) / grid.y) * grid.y
		AxisDir.Y_POS:
			u = round((u + grid.x * 0.5) / grid.x) * grid.x
			v = round((v - grid.y * 0.5) / grid.y) * grid.y

	return plane_origin + tangent * u + bitangent * v

func _try_stamp_at_mouse(
	viewport_camera: Camera3D,
	mouse_pos: Vector2,
	brush: TileModeller
) -> void:

	if _is_over_brushform_handle(viewport_camera, mouse_pos, brush):
		return

	var ray_origin := viewport_camera.project_ray_origin(mouse_pos)
	var ray_dir := viewport_camera.project_ray_normal(mouse_pos)

	var cursor := brush.cursor
	var plane := get_axis_aligned_plane(viewport_camera, cursor.global_position)

	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var normal := plane.normal.normalized()

	var snapped := snap_point_to_plane_grid(
		hit,
		viewport_camera,
		normal,
		cursor.global_position,
		Vector2(brush.vertex_snap, brush.vertex_snap)/ Vector2(brush.brush_form.pixels_to_world_unit,brush.brush_form.pixels_to_world_unit)
	)

	var cell := Vector3i(
		floor(snapped.x),
		floor(snapped.y),
		floor(snapped.z)
	)

	if cell == _last_stamp_cell:
		return

	_last_stamp_cell = cell

	var bf: BrushForm = brush.brush_form

	var basis := basis_from_plane(plane.normal,orientation_from_normal(normal))

	var stamp = brush.get_tile_stamp_offsets()

	if stamp.is_empty():
		stamp[Vector2i.ZERO] = brush.tile_coord
	var stamp_origin := get_stamp_origin(snapped, brush, normal)
	for offset in stamp.keys():
		var tile_coord = stamp[offset]

		var axes := plane_axes_from_normal_hardcoded(normal)
		var right = axes.right
		var down  = axes.down

		

		var place_pos = stamp_origin + right * (offset.x * (float(brush.tile_size.x) / float(brush.brush_form.pixels_to_world_unit))) + down  * (offset.y* (float(brush.tile_size.x) / float(brush.brush_form.pixels_to_world_unit)))
		
		bf.place_quad_undoable(
			place_pos + wall_face_offset2(normal, right, down, brush),
			normal,
			basis,
			brush.active_tileset_source_id,
			tile_coord,
			brush.tile_size,
			brush.tileset,
			brush.orientation
		)

	cursor.global_position = stamp_origin
	var focus_point := focus_selection_gdscript()
	_focus_editor_camera_on_point(
		get_editor_interface().get_editor_viewport_3d().get_camera_3d(),
		focus_point
	)

func get_custom_quad(
	viewport_camera: Camera3D,
	event: InputEvent,
	brush: TileModeller
) -> PackedVector3Array:
	if event is not InputEventMouse:
		return PackedVector3Array()

	var mouse_pos = event.position
	var ray_origin := viewport_camera.project_ray_origin(mouse_pos)
	var ray_dir := viewport_camera.project_ray_normal(mouse_pos)

	var cursor := brush.cursor
	var plane := get_axis_aligned_plane(viewport_camera, cursor.global_position)

	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return PackedVector3Array()

	var normal := plane.normal.normalized()

	var snapped := snap_point_to_plane_grid(
		hit,
		viewport_camera,
		normal,
		cursor.global_position,
		Vector2(
			brush.vertex_snap,
			brush.vertex_snap
		) / Vector2(
			brush.brush_form.pixels_to_world_unit,
			brush.brush_form.pixels_to_world_unit
		)
	)

	var axes := plane_axes_from_normal_hardcoded(normal)
	var right : Vector3 = axes.right.normalized()
	var down  : Vector3 = axes.down.normalized()

	var face_offset := wall_face_offset(brush, normal)
	var pixel_to_world := 1.0 / brush.brush_form.pixels_to_world_unit

	if brush.tile_corners.size() < 4:
		return PackedVector3Array()

	var origin_uv : Vector2 = brush.tile_corners[0]

	var world_pts := PackedVector3Array()

	for c in brush.tile_corners:
		var local_px : Vector2 = c - origin_uv
		var world_offset = right * (local_px.x * pixel_to_world) + down  * (local_px.y * pixel_to_world)

		world_pts.append(
			snapped
			+ face_offset
			+ world_offset
		)

	return world_pts

func _try_stamp_custom_quad(
	viewport_camera: Camera3D,
	mouse_pos: Vector2,
	brush: TileModeller,
	quad_points:Array
) -> void:

	if _is_over_brushform_handle(viewport_camera, mouse_pos, brush):
		return

	var ray_origin := viewport_camera.project_ray_origin(mouse_pos)
	var ray_dir := viewport_camera.project_ray_normal(mouse_pos)

	var cursor := brush.cursor
	var plane := get_axis_aligned_plane(viewport_camera, cursor.global_position)

	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var normal := plane.normal.normalized()

	var snapped := snap_point_to_plane_grid(
		hit,
		viewport_camera,
		normal,
		cursor.global_position,
		Vector2(brush.vertex_snap, brush.vertex_snap)/ Vector2(brush.brush_form.pixels_to_world_unit,brush.brush_form.pixels_to_world_unit)
	)

	var cell := Vector3i(
		floor(snapped.x),
		floor(snapped.y),
		floor(snapped.z)
	)
	if cell == _last_stamp_cell:
		return
	_last_stamp_cell = cell

	var bf = brush.brush_form

	var basis := basis_from_plane(normal, brush.orientation)

	bf.place_custom_quad_undoable(
		quad_points,
		normal,
		basis,
		brush.active_tileset_source_id,
		brush.tile_coord,
		brush.tile_size,
		brush.tileset,
		brush.tile_corners,
		brush.orientation
	)

	cursor.global_position = snapped

static func get_stamp_origin(
	snapped: Vector3,
	brush: TileModeller,
	normal: Vector3
) -> Vector3:
	var axes := plane_axes_from_normal_hardcoded(normal)
	var right = axes.right
	var down  = axes.down
	var anchor = brush.tile_corners[0]

	return (
		snapped
		+ right * (anchor.x / brush.tile_size.x)
		+ down  * (anchor.y / brush.tile_size.y)
		+ wall_face_offset(brush, normal)
	)

func _paint_tiles(event,selection,viewport_camera,brush):
	if event is InputEventKey and event.keycode == KEY_R and event.pressed and !event.echo:
		brush.orientation = int(fmod(brush.orientation + 1, 4))
		return 2

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_paint_selection = selection.get_selected_nodes().duplicate()
			_drag_painting = true
			_last_stamp_cell = Vector3i(999999, 999999, 999999)
			var bf = brush.brush_form
			if bf:
				bf.begin_quad_paint()

			_try_stamp_at_mouse(viewport_camera, event.position, brush)
			_restore_paint_selection()
			return 2
		else:
			_drag_painting = false

			var bf = brush.brush_form
			if bf:
				bf.end_quad_paint()

			_restore_paint_selection()
			return 2

	if event is InputEventMouseMotion and _drag_painting and event.button_mask == MOUSE_BUTTON_LEFT:
		_try_stamp_at_mouse(viewport_camera, event.position, brush)
		_restore_paint_selection()
		return 2

	return 0

func _restore_paint_selection() -> void:
	var selection := get_editor_interface().get_selection()

	selection.clear()

	for n in _paint_selection:
		if is_instance_valid(n):
			selection.add_node(n)


const HANDLE_PICK_RADIUS := 8.0

func _is_over_brushform_handle(
	viewport_camera: Camera3D,
	mouse_pos: Vector2,
	brush: TileModeller
) -> bool:
	var bf: BrushForm = brush.brush_form

	if bf == null:
		return false

	for i in range(bf.positions.size()):
		var world_pos = brush.global_transform * bf.positions[i]
		var screen_pos := viewport_camera.unproject_position(world_pos)

		if screen_pos.distance_to(mouse_pos) <= HANDLE_PICK_RADIUS:
			return true

	return false

func _handles(object: Object) -> bool:
	if object is TileModeller:
		brush = object
		toolbar.set_brush_values(brush)
	return object is TileModeller

func _make_visible(visible: bool) -> void:
	toolbar.visible = visible

func _exit_tree():
	remove_custom_type("TileModeller")
	remove_custom_type("BrushForm")
	remove_custom_type("VertexAttachment")
	remove_node_3d_gizmo_plugin(vertexGZM)
	remove_node_3d_gizmo_plugin(planeGZM)
	remove_inspector_plugin(UVEdit)
	remove_inspector_plugin(TilesetPalette)
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
static func orientation_from_normal(n: Vector3) -> int:
	n = n.normalized()

	# Use dominant axis
	if abs(n.x) > abs(n.y) and abs(n.x) > abs(n.z):
		return 1 if n.x > 0.0 else 3
	elif abs(n.y) > abs(n.z):
		return 3 if n.y > 0.0 else 1
	else:
		return 3 if n.z > 0.0 else 3

static func plane_axes_from_normal_hardcoded(normal: Vector3) -> Dictionary:
	normal = normal.normalized()

	# Floor (normal = +Y)
	if normal.y > 0.9:
		return {
			"right": Vector3.RIGHT * -sign(normal.y),   # +X
			"down":  Vector3.FORWARD * -sign(normal.y) # +Z
		}

	# Ceiling (normal = -Y)
	if normal.y < -0.9:
		return {
			"right": Vector3.RIGHT,    # +X
			"down":  Vector3.BACK      # -Z
		}

	# Wall facing +X / -X
	if abs(normal.x) > 0.9:
		return {
			"right": Vector3.FORWARD * -sign(normal.x),
			"down":  Vector3.DOWN
		}

	# Wall facing +Z / -Z
	if abs(normal.z) > 0.9:
		return {
			"right": Vector3.RIGHT * -sign(normal.z),
			"down":  Vector3.DOWN
		}
	# Fallback (should never hit)
	return {
		"right": Vector3.RIGHT,
		"down":  Vector3.FORWARD
	}


var _camera_tween: Tween = null

const CAMERA_FOCUS_EPSILON := 15.05
func focus_selection_gdscript() -> Vector3:
	var center := Vector3.ZERO
	var count := 0
	var selection := get_editor_interface().get_selection()
	var selected := selection.get_selected_nodes()

	var brush: TileModeller = null
	var node := selected[0]

	if node is TileModeller:
		brush = node

	var node_3d := node as Node3D

	# --- Equivalent to gizmo origin ---
	var gizmo_xform := brush.cursor.global_transform
	var pos := gizmo_xform.origin

	if pos.is_finite():
		center += pos
		count += 1

	if count > 1:
		center /= count

	return center
func warp_mouse_to_editor_viewport_center() -> void:
	var vp := get_editor_interface().get_editor_viewport_3d(0)
	if vp == null:
		return

	var center := vp.get_visible_rect().size * 0.5
	vp.warp_mouse(center)

func _focus_editor_camera_on_point(
	camera: Camera3D,
	target: Vector3,
	duration := 0.15
) -> void:
	if _camera_tween and _camera_tween.is_running():
		return
	var cam_xform := camera.global_transform
	var forward := -cam_xform.basis.z.normalized()

	var to_target := target - cam_xform.origin
	var distance := to_target.dot(forward)
	if distance <= 0.001:
		return

	var target_pos := target - forward * distance

	# 🔒 Early out if already focused
	if cam_xform.origin.distance_to(target_pos) <= CAMERA_FOCUS_EPSILON:
		return

	_camera_tween = get_tree().create_tween()
	_camera_tween.set_trans(Tween.TRANS_SINE)
	_camera_tween.set_ease(Tween.EASE_OUT)

	_camera_tween.tween_property(
		camera,
		"global_position",
		target_pos,
		duration
	)
	warp_mouse_to_editor_viewport_center()
