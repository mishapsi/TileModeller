extends EditorNode3DGizmoPlugin
const handle_tex = preload("uid://censw3w53gldn")
var grabbed: bool = false
var vertex: int = -1
var inPos : Vector2
var outPos := Vector3.ZERO
var snapped_during_drag := false
var last_target_world_pos := Vector3.ZERO
var drag_group: Array[int] = []
const SNAP_WORLD_RADIUS := 0.5

const SNAP_PIXEL_RADIUS := 5.0
const SNAP_HOVER_TIME := 0.01
const SNAP_PIXEL_TOLERANCE := 3.0

var hover_snap_index := -1
var hover_start_time := 0.0
var hover_start_mouse_pos := Vector2.ZERO
var last_camera: Camera3D
var last_mouse_pos := Vector2.ZERO
var pending_snap := false

var active_gizmo: EditorNode3DGizmo = null
var undo_redo: EditorUndoRedoManager
var undo_snapshot

func _get_gizmo_name() -> String:
	return "Vertex Snapper"

func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	return "(Drag to move BrushForm) GZ : Vertex Coords"

func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> Variant:
	return gizmo.get_node_3d().transform * gizmo.get_node_3d().brush_form.positions[handle_id]

func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is TileModeller
	
var handle_mesh := SphereMesh.new()

func _init():

	handle_mesh.height = .01
	handle_mesh.radius = .005
	create_material("main", Color(0, 1, 0), false, true)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.depth_test = BaseMaterial3D.DEPTH_TEST_DEFAULT
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	add_material("handles_depth", mat)

func _make_handle_material(color:Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.depth_test = BaseMaterial3D.DEPTH_TEST_DEFAULT
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.fixed_size = true
	return mat

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as TileModeller
	if node == null:
		return
	if node.brush_form == null:
		return
	if node.brush_form.positions.is_empty():
		return
	var selection := EditorInterface.get_selection().get_selected_nodes()
	if node not in selection:
		return
	_draw_vertex_handles(gizmo, node)


func _draw_vertex_handles(gizmo, node):
	var brush = gizmo.get_node_3d()
	var node3d = gizmo.get_node_3d().brush_form as BrushForm
	var vertexHandles = PackedVector3Array()
	var vertexHandlesIds = PackedInt32Array()
	var mat := _make_handle_material(Color(0,1,.5,.5))
	var mat2 := _make_handle_material(Color(1,.5,0,.5))
	for i in node3d.positions.size():
		var xf := Transform3D.IDENTITY
		xf.origin = node3d.positions[i]

		gizmo.add_mesh(
			handle_mesh,
			mat,
			xf
		)
	if node3d.positions.size() > 2:
		for vertex in node3d.positions.size():
			vertexHandles.append(node3d.positions[vertex])
			vertexHandlesIds.append(vertex)
	
	gizmo.add_handles(
		vertexHandles,
		get_material("handles_depth", gizmo),
		vertexHandlesIds,
		false,
		false
	)

	gizmo.add_handles(
		vertexHandles,
		get_material("handles_depth", gizmo),
		vertexHandlesIds,
		false,
		true
	)
	if node.tool_mode in [TileModeller.TOOL_MODE.MOVE_VERTEX]:
		# -------------------------
		# Quad center handles
		# -------------------------
		var quad_positions := PackedVector3Array()
		var quad_ids := PackedInt32Array()

		var quads := node3d.get_quads()

		for q in range(quads.size()):
			var quad := quads[q]

			if quad.size() != 4:
				continue

			var center := Vector3.ZERO
			for vi in quad:
				center += node3d.positions[vi]
			center /= 4.0

			quad_positions.append(center)
			quad_ids.append(-q - 1)
		
		for i in quad_positions.size():
			var xf := Transform3D.IDENTITY
			xf.origin = quad_positions[i]

			gizmo.add_mesh(
				handle_mesh,
				mat2,
				xf
			)

		gizmo.add_handles(
			quad_positions,
			get_material("handles_depth", gizmo),
			quad_ids,
			false,
			true
		)
		
		gizmo.add_handles(
			quad_positions,
			get_material("handles_depth", gizmo),
			quad_ids,
			false,
			false
		)

func _is_handle_highlighted(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> bool:
	return false

func is_handle_under_mouse(
	node: TileModeller,
	camera: Camera3D,
	mouse_pos: Vector2,
	handle_id: int
) -> bool:
	var world_pos = node.brush_form.global_transform * node.positions[handle_id]
	var screen_pos := camera.unproject_position(world_pos)
	return screen_pos.distance_to(mouse_pos) <= SNAP_PIXEL_RADIUS
func _commit_handle(
	gizmo: EditorNode3DGizmo,
	handle_id: int,
	secondary: bool,
	restore: Variant,
	cancel: bool
) -> void:
	grabbed = false
	active_gizmo = null

	var node := gizmo.get_node_3d()

	if cancel:
		node.brush_form.positions = undo_snapshot
		drag_group.clear()
		node.update_gizmos()
		return

	undo_redo.create_action("Move BrushForm Vertex", UndoRedo.MERGE_ENDS)

	undo_redo.add_do_property(
		node,
		"positions",
		node.brush_form.positions
	)

	undo_redo.add_undo_method(
		node.brush_form,
		"_set_mesh_state",
		undo_snapshot
	)

	undo_redo.commit_action()

	node.notify_property_list_changed()
	drag_group.clear()

func _begin_handle_action(
	gizmo: EditorNode3DGizmo,
	handle_id: int,
	secondary: bool
) -> void:
	undo_redo = EditorInterface.get_editor_undo_redo()
	var brush = gizmo.get_node_3d()
	var node = gizmo.get_node_3d().brush_form
	# -------------------------------------------------
	# QUAD HANDLE (negative IDs)
	# -------------------------------------------------
	if brush.tool_mode == TileModeller.TOOL_MODE.PAINT_VERTEX:
		paint_vertex(gizmo,handle_id,secondary)
		return
	if handle_id < 0:
		if secondary:
			var quad_index := -handle_id - 1
			grabbed = true
			active_gizmo = gizmo
			var before = node._get_mesh_state()

			undo_redo.create_action("Delete Quad")
			undo_redo.add_do_method(node, "delete_quad", quad_index)
			undo_redo.add_undo_method(node, "_set_mesh_state", before)
			undo_redo.commit_action()

			node.update_gizmos()
		else:
			var quad_index := -handle_id - 1
			var quad = node.get_quads()[quad_index]
			var center := Vector3.ZERO
			for v in quad:
				center += node.positions[v]
			center /= quad.size()

			node.on_quad_center_clicked(center, secondary)

		return
	grabbed = true
	active_gizmo = gizmo
	undo_snapshot = node._get_mesh_state()

	hover_snap_index = -1
	hover_start_time = Time.get_ticks_msec() * 0.001
	hover_start_mouse_pos = Vector2.ZERO

	if secondary:
		node.delete_vertex(handle_id)
		grabbed = false
		vertex = -1
		return

	drag_group.clear()

	var start_pos = node.positions[handle_id]
	for i in range(node.positions.size()):
		if node.positions[i].is_equal_approx(start_pos):
			drag_group.append(i)
	var cursor = brush.cursor
	cursor.global_position = start_pos
	vertex = handle_id
	snapped_during_drag = false


const DRAG_PIXEL_RADIUS := 56.0

func is_dragging() -> bool:
	if not grabbed or active_gizmo == null:
		return false

	if last_camera == null:
		return true
	var brush = active_gizmo.get_node_3d()

	if brush == null:
		return false
	var node = active_gizmo.get_node_3d().brush_form
	if vertex < 0 or vertex >= node.positions.size():
		return false

	var world_pos = brush.global_transform * node.positions[vertex]
	var screen_pos := last_camera.unproject_position(world_pos)

	return screen_pos.distance_to(last_mouse_pos) <= DRAG_PIXEL_RADIUS


func _set_handle(
	gizmo: EditorNode3DGizmo,
	handle_id: int,
	secondary: bool,
	camera: Camera3D,
	screen_pos: Vector2
) -> void:
	last_camera = camera
	last_mouse_pos = screen_pos

	var node = gizmo.get_node_3d()
	if node.tool_mode == TileModeller.TOOL_MODE.MOVE_VERTEX:
		move_vertex(gizmo,handle_id,secondary, camera, screen_pos)


func paint_vertex(
	gizmo: EditorNode3DGizmo,
	handle_id: int,
	secondary: bool,
):
	var brush = gizmo.get_node_3d()
	var node = gizmo.get_node_3d().brush_form
	if handle_id < 0 or handle_id >= node.positions.size():
		return

	var target_pos = node.positions[handle_id]
	var target_key = node._pos_key(target_pos)

	for i in range(node.positions.size()):
		if node._pos_key(node.positions[i]) == target_key:
			node.colors[i] = brush.vertex_color

	node.notify_property_list_changed()
	gizmo.get_node_3d().update_gizmos()


func move_vertex(	
	gizmo: EditorNode3DGizmo,
	handle_id: int,
	secondary: bool,
	camera: Camera3D,
	screen_pos: Vector2):
	last_camera = camera
	last_mouse_pos = screen_pos
	var brush =  gizmo.get_node_3d()
	var node = gizmo.get_node_3d().brush_form
	var cursor = gizmo.get_node_3d().cursor
	if handle_id >= node.positions.size() or handle_id < 0:
		return

	snapped_during_drag = false
	var now := Time.get_ticks_msec() * 0.001
	var candidate := _find_handle_under_mouse(
		brush,
		node,
		camera,
		screen_pos,
		handle_id
	)

	var snap_index := -1

	if candidate != -1:
		if candidate != hover_snap_index:
			hover_snap_index = candidate
			hover_start_time = now
			hover_start_mouse_pos = screen_pos
			pending_snap = true

		else:
			var hover_time := now - hover_start_time
			var mouse_drift := screen_pos.distance_to(hover_start_mouse_pos)

			if hover_time >= SNAP_HOVER_TIME and mouse_drift <= SNAP_PIXEL_TOLERANCE:
				snap_index = hover_snap_index
	else:
		hover_snap_index = -1
		hover_start_time = 0.0


	var target_world_pos: Vector3

	if snap_index != -1:
		target_world_pos = brush.global_transform * node.positions[snap_index]
		snapped_during_drag = true
	else:
		var ray_origin := camera.project_ray_origin(screen_pos)
		var ray_dir := camera.project_ray_normal(screen_pos)

		var local_pos = node.positions[handle_id]
		var world_pos = brush.global_transform * local_pos

		var plane := get_axis_aligned_plane(camera, world_pos)
		var hit := plane.intersects_ray(ray_origin, ray_dir)
		if hit == null:
			return


		var snap = float(brush.vertex_snap)/float(brush.brush_form.pixels_to_world_unit) * Vector3.ONE
		target_world_pos = hit.snapped(snap)


	var current_world = brush.global_transform * node.positions[handle_id]
	var local_delta = brush.global_transform.basis.inverse() * (target_world_pos - current_world)

	for i in drag_group:
		node.positions[i] += local_delta

	cursor.global_position = target_world_pos
	last_target_world_pos = target_world_pos

	node.notify_property_list_changed()
	brush.update_gizmos()

func _force_snap():
	if active_gizmo == null:
		return
	if hover_snap_index == -1:
		return
	var brush = active_gizmo.get_node_3d()
	var node = active_gizmo.get_node_3d().brush_form

	var target_world = brush.global_transform * node.positions[hover_snap_index]
	var current_world = brush.global_transform * node.positions[vertex]

	var local_delta = brush.global_transform.basis.inverse() * (target_world - current_world)

	for i in drag_group:
		node.positions[i] += local_delta

	snapped_during_drag = true



func _find_handle_under_mouse(
	brush:TileModeller,
	node: BrushForm,
	camera: Camera3D,
	mouse_pos: Vector2,
	exclude_index: int
) -> int:
	var best_index := -1
	var best_screen_dist := SNAP_PIXEL_RADIUS

	var dragged_world := brush.global_transform * node.positions[exclude_index]

	for i in range(node.positions.size()):
		if i == exclude_index:
			continue

		var world_pos := brush.global_transform * node.positions[i]
		if dragged_world.distance_to(world_pos) > SNAP_WORLD_RADIUS:
			continue

		var screen := camera.unproject_position(world_pos)
		var d := screen.distance_to(mouse_pos)

		if d < best_screen_dist:
			best_screen_dist = d
			best_index = i

	return best_index

func get_axis_aligned_plane(camera: Camera3D, origin := Vector3.ZERO) -> Plane:
	var forward := -camera.global_transform.basis.z.normalized()

	var abs_f := Vector3(abs(forward.x), abs(forward.y), abs(forward.z))
	var normal: Vector3

	if abs_f.x > abs_f.y and abs_f.x > abs_f.z:
		normal = Vector3(sign(forward.x), 0, 0)
	elif abs_f.y > abs_f.x and abs_f.y > abs_f.z:
		normal = Vector3(0, sign(forward.y), 0)
	else:
		normal = Vector3(0, 0, sign(forward.z))

	return Plane(normal, origin.dot(normal))
