extends EditorNode3DGizmoPlugin
const handle_tex = preload("uid://censw3w53gldn")

signal quad_split_requested(
	quad_index: int,
	axis: String,            
	offset_world: float,      
	normal_world: Vector3,    
	right_world: Vector3,    
	down_world: Vector3      
)

signal quad_texel_split_requested(
	quad_index: int,
	axis: String,            
	texel_coord: float,        
	normal_world: Vector3,
	right_world: Vector3,
	down_world: Vector3
)

var handle_mat_vertex: StandardMaterial3D
var handle_mat_quad: StandardMaterial3D
var split_line_mesh: ImmediateMesh
var split_line_material: StandardMaterial3D
var edge_mesh: ImmediateMesh
var edge_material: StandardMaterial3D

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
var active_split_quad_index: int = -1
var active_split_center: Vector3 = Vector3.ZERO
var active_split_axis: String = "" 
var active_split_texel_coord = Vector2()

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

	handle_mat_vertex = _make_handle_material(Color(0,1,.5,.5))
	handle_mat_quad   = _make_handle_material(Color(1,.5,0,.5))

	create_material("main", Color(0, 1, 0), false, true)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.depth_test = BaseMaterial3D.DEPTH_TEST_DEFAULT
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	add_material("handles_depth", mat)
	split_line_mesh = ImmediateMesh.new()

	split_line_material = StandardMaterial3D.new()
	split_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	split_line_material.albedo_color = Color(1, 1, 0)
	split_line_material.cull_mode =BaseMaterial3D.CULL_DISABLED
	
	edge_mesh = ImmediateMesh.new()
	edge_material = StandardMaterial3D.new()
	edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_material.albedo_color = Color(.5, .5, .5,.5)
	edge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge_material.cull_mode =BaseMaterial3D.CULL_DISABLED

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

func _emit_quad_split(brush: TileModeller) -> void:
	var bf := brush.brush_form
	var quad := bf.get_quads()[active_split_quad_index]
	if quad.size() != 4:
		return

	var center_local := Vector3.ZERO
	for v in quad:
		center_local += bf.positions[v]
	center_local /= 4.0
	var center_world := brush.global_transform * center_local

	var a := bf.positions[quad[0]]
	var b := bf.positions[quad[1]]
	var c := bf.positions[quad[2]]
	var normal_local := (b - a).cross(c - a).normalized()
	var normal_world := (brush.global_transform.basis * normal_local).normalized()

	var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
	var right = axes.right.normalized()
	var down  = axes.down.normalized()

	var offset_axis = down if active_split_axis == "horizontal" else right
	var viewport := EditorInterface.get_editor_viewport_3d()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return

	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)

	var plane := Plane(normal_world, center_world.dot(normal_world))
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var texel_world := 1.0 / brush.brush_form.pixels_to_world_unit
	var offset = (hit - center_world).dot(offset_axis)
	offset = round(offset / texel_world) * texel_world

	quad_split_requested.emit(
		active_split_quad_index,
		active_split_axis,
		offset,
		normal_world,
		right,
		down
	)
func _emit_quad_texel_split(brush: TileModeller) -> void:
	var bf := brush.brush_form
	var quad := bf.get_quads()[active_split_quad_index]
	if quad.size() != 4:
		return

	# World positions
	var p3 := []
	for vi in quad:
		p3.append(brush.global_transform * bf.positions[vi])

	# Quad normal
	var normal_world = (p3[1] - p3[0]).cross(p3[2] - p3[0]).normalized()
	if normal_world.length_squared() < 1e-8:
		return

	# Stable consumer axes
	var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
	var right_world = axes.right.normalized()
	var down_world  = axes.down.normalized()
	if right_world.cross(down_world).dot(normal_world) < 0.0:
		down_world = -down_world

	var texel_coord = active_split_texel_coord

	quad_texel_split_requested.emit(
		active_split_quad_index,
		active_split_axis,
		texel_coord,
		normal_world,
		right_world,
		down_world
	)


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	last_camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
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

	for i in node3d.positions.size():
		var xf := Transform3D.IDENTITY
		xf.origin = node3d.positions[i]

		gizmo.add_mesh(
			handle_mesh,
			handle_mat_vertex,
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

	if node.tool_mode in [TileModeller.TOOL_MODE.MOVE_VERTEX, TileModeller.TOOL_MODE.QUAD_SPLIT]:
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
				handle_mat_quad,
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
	if node.tool_mode in [TileModeller.TOOL_MODE.MOVE_VERTEX,TileModeller.TOOL_MODE.QUAD_SPLIT]:
		_draw_triangle_outline(gizmo, node)
	if node.tool_mode == TileModeller.TOOL_MODE.QUAD_SPLIT:

		if last_camera == null:
			return

		var viewport := EditorInterface.get_editor_viewport_3d()
		if viewport == null:
			return

		var mouse_pos := viewport.get_mouse_position()

		var hovered_quad := _find_quad_under_mouse(
			last_camera,
			node,
			mouse_pos
		)

		if hovered_quad != -1:
			active_split_quad_index = hovered_quad
		else:
			active_split_quad_index = -1

		if active_split_quad_index == -1:
			return

		var quad = node.brush_form.get_quads()[active_split_quad_index]

		active_split_axis = _pick_polygon_split_axis_from_mouse(
			last_camera,
			node,
			quad,
			mouse_pos
		)

		if brush.quad_texel_split:
			_draw_texel_split_axis_line(gizmo, node)
		else:
			_draw_split_axis_line(gizmo, node)

	else:
		active_split_quad_index = -1
func _draw_triangle_outline(
	gizmo: EditorNode3DGizmo,
	brush: TileModeller
) -> void:
	if !edge_mesh:
		edge_mesh = ImmediateMesh.new()
	var bf := brush.brush_form
	if bf.indices.size() < 3:
		return

	var camera := EditorInterface.get_editor_viewport_3d().get_camera_3d()
	if camera == null:
		return

	var edge_count := {}

	var indices := bf.indices
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]

		_count_edge(edge_count, a, b)
		_count_edge(edge_count, b, c)
		_count_edge(edge_count, c, a)

	edge_mesh.clear_surfaces()
	edge_mesh.surface_begin(
		Mesh.PRIMITIVE_TRIANGLES,
		edge_material
	)

	for key in edge_count.keys():
		if edge_count[key] > 1: continue

		var i0 = key.x
		var i1 = key.y

		var p0 := brush.global_transform * bf.positions[i0]
		var p1 := brush.global_transform * bf.positions[i1]

		_add_thick_edge(p0, p1, camera,edge_mesh)

	edge_mesh.surface_end()

	gizmo.add_mesh(
		edge_mesh,
		edge_material,
		Transform3D.IDENTITY
	)

func _count_edge(map: Dictionary, i0: int, i1: int) -> void:
	var a := min(i0, i1)
	var b := max(i0, i1)
	var key := Vector2i(a, b)

	if map.has(key):
		map[key] += 1
	else:
		map[key] = 1


func _add_thick_edge(
	p0: Vector3,
	p1: Vector3,
	camera: Camera3D,
	mesh: ImmediateMesh
) -> void:
	var dir := (p1 - p0).normalized()
	var view_dir := (camera.global_transform.origin - (p0 + p1) * 0.5).normalized()

	var side := dir.cross(view_dir)
	if side.length() < 1e-6:
		return

	side = side.normalized() * 0.005

	var a := p0 - side
	var b := p0 + side
	var c := p1 - side
	var d := p1 + side

	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(b)
	mesh.surface_add_vertex(c)

	mesh.surface_add_vertex(b)
	mesh.surface_add_vertex(d)
	mesh.surface_add_vertex(c)


func _dist_point_to_segment_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0
	if ab.length_squared() > 0.0:
		t = clamp((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	var proj := a + ab * t
	return p.distance_to(proj)

func _pick_polygon_split_axis_from_mouse(
	camera: Camera3D,
	brush: TileModeller,
	polygon: Array,
	mouse_pos: Vector2
) -> String:
	match polygon.size():
		4:
			return _pick_quad_split_axis_from_mouse(camera, brush, polygon, mouse_pos)
		3:
			return _pick_triangle_split_axis_from_mouse(camera, brush, polygon, mouse_pos)
		_:
			return active_split_axis

func _pick_triangle_split_axis_from_mouse(
	camera: Camera3D,
	brush: TileModeller,
	tri: Array,
	mouse_pos: Vector2
) -> String:
	var bf := brush.brush_form
	if tri.size() != 3:
		return active_split_axis

	var a := bf.positions[tri[0]]
	var b := bf.positions[tri[1]]
	var c := bf.positions[tri[2]]

	var normal_local := (b - a).cross(c - a)
	if normal_local.length_squared() < 1e-8:
		return active_split_axis

	var normal_world := (brush.global_transform.basis * normal_local).normalized()

	var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
	var right = axes.right.normalized()
	var down  = axes.down.normalized()
	if right.cross(down).dot(normal_world) < 0.0:
		down = -down

	var center_local := (a + b + c) / 3.0
	var center_world := brush.global_transform * center_local

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)
	var plane := Plane(normal_world, center_world.dot(normal_world))
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return active_split_axis

	var m2 := Vector2(
		(hit - center_world).dot(right),
		(hit - center_world).dot(down)
	)

	var pts := []
	for vi in tri:
		var w := brush.global_transform * bf.positions[vi]
		var rel := w - center_world
		pts.append(Vector2(rel.dot(right), rel.dot(down)))

	var dist_point_to_seg = func(p: Vector2, a: Vector2, b: Vector2) -> float:
		var ab := b - a
		if ab.length_squared() < 1e-8:
			return p.distance_to(a)
		var t := clamp((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		return p.distance_to(a + ab * t)

	var best_edge := -1
	var best_dist := INF

	for i in range(3):
		var j := (i + 1) % 3
		var d := dist_point_to_seg.call(m2, pts[i], pts[j])
		if d < best_dist:
			best_dist = d
			best_edge = i

	var e0 = pts[best_edge]
	var e1 = pts[(best_edge + 1) % 3]
	var edge_dir = (e1 - e0).normalized()


	if abs(edge_dir.x) >= abs(edge_dir.y):
		return "horizontal"
	else:
		return "vertical"

func _dist_point_to_seg_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-6:
		return p.distance_to(a)
	var t := clamp((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _get_best_quad_edge_from_mouse(
	camera: Camera3D,
	brush: TileModeller,
	quad: Array,
	mouse_pos: Vector2
) -> Dictionary:
	var bf := brush.brush_form
	if quad.size() != 4:
		return {}

	var a := bf.positions[quad[0]]
	var b := bf.positions[quad[1]]
	var c := bf.positions[quad[2]]
	var normal_local := (b - a).cross(c - a)
	if normal_local.length_squared() < 1e-8:
		return {}

	var normal_world := (brush.global_transform.basis * normal_local).normalized()

	var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
	var right = axes.right.normalized()
	var down  = axes.down.normalized()
	if right.cross(down).dot(normal_world) < 0.0:
		down = -down

	var center := Vector3.ZERO
	for vi in quad:
		center += brush.global_transform * bf.positions[vi]
	center /= 4.0

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)
	var plane := Plane(normal_world, center.dot(normal_world))
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return {}

	var m2 := Vector2(
		(hit - center).dot(right),
		(hit - center).dot(down)
	)

	var pts := []
	for vi in quad:
		var w := brush.global_transform * bf.positions[vi]
		var rel := w - center
		pts.append(Vector2(rel.dot(right), rel.dot(down)))

	var c2 := Vector2.ZERO
	for p in pts: c2 += p
	c2 /= 4.0

	pts.sort_custom(func(a, b):
		return atan2(a.y - c2.y, a.x - c2.x) < atan2(b.y - c2.y, b.x - c2.x)
	)

	var area := 0.0
	for i in range(4):
		var p0 = pts[i]
		var p1 = pts[(i + 1) % 4]
		area += p0.x * p1.y - p1.x * p0.y
	if area < 0.0:
		pts.reverse()

	var dist_point_to_seg = func(p, a, b):
		var ab = b - a
		if ab.length_squared() < 1e-8:
			return p.distance_to(a)
		var t := clamp((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		return p.distance_to(a + ab * t)

	var best_edge := -1
	var best_dist := INF
	for i in range(4):
		var j := (i + 1) % 4
		var d := dist_point_to_seg.call(m2, pts[i], pts[j])
		if d < best_dist:
			best_dist = d
			best_edge = i
	if best_edge == -1:
		return {}
	var i0 := (best_edge+1) % 4
	var i1 := (i0 + 1) % 4
	return {
		"normal": normal_world,
		"right": right,
		"down": down,
		"edge_dir_2d": (pts[i1] - pts[i0]).normalized(),
		"center": center
	}
	
func _compute_quad_face_normal(w: Array) -> Vector3:
	var n0 = (w[1] - w[0]).cross(w[3] - w[0])
	var n1 = (w[3] - w[1]).cross(w[2] - w[1])

	var n = n0 + n1
	if n.length_squared() < 1e-8:
		return Vector3.ZERO

	return n.normalized()

func _pick_quad_edge_screen_space(
	camera: Camera3D,
	brush: TileModeller,
	quad: Array,
	mouse_pos: Vector2
) -> Dictionary:
	if quad.size() != 4:
		return {}

	var bf := brush.brush_form
	var xf := brush.global_transform

	var w := []
	for vi in quad:
		w.append(bf.positions[vi])

	var s := []
	for p in w:
		s.append(camera.unproject_position(p))

	var edges := [
		[0, 1],
		[1, 3],
		[3, 2],
		[2, 0]
	]

	var best_edge := -1
	var best_dist := INF

	for ei in range(edges.size()):
		var i0 = edges[ei][0]
		var i1 = edges[ei][1]

		var d := _dist_point_to_seg_2d(mouse_pos, s[i0], s[i1])
		if d < best_dist:
			best_dist = d
			best_edge = ei

	if best_edge == -1:
		return {}

	var face_normal := _compute_quad_face_normal(w)
	if face_normal == Vector3.ZERO:
		return {}

	var e0 = edges[best_edge][0]
	var e1 = edges[best_edge][1]
	var edge_dir = (w[e1] - w[e0]).normalized()
	var edge_normal = edge_dir.cross(face_normal).normalized()

	return {
		"edge_index": best_edge,
		"edge_verts": [e0, e1],
		"edge_dir": edge_dir,
		"edge_normal": edge_normal,
		"quad_normal": face_normal,
		"screen_dist": best_dist
	}

func project_to_quad_2d(v: Vector3, x: Vector3, y: Vector3) -> Vector2:
	return Vector2(v.dot(x), v.dot(y))

func _pick_quad_split_axis_from_mouse(
	camera: Camera3D,
	brush: TileModeller,
	quad: Array,
	mouse_pos: Vector2
) -> String:
	var info := _pick_quad_edge_screen_space(
		camera,
		brush,
		quad,
		mouse_pos
	)
	if info.is_empty():
		return active_split_axis

	var bf := brush.brush_form
	var xf := brush.global_transform

	var p3 := []
	var puv := []
	for vi in quad:
		p3.append(xf * bf.positions[vi])
		puv.append(bf.uvs[vi])

	var center := Vector3.ZERO
	for p in p3:
		center += p
	center /= 4.0

	var uv_center := Vector2.ZERO
	for uv in puv:
		uv_center += uv
	uv_center /= 4.0

	var du_world := Vector3.ZERO
	var dv_world := Vector3.ZERO

	for i in range(4):
		var du = puv[i].x - uv_center.x
		var dv = puv[i].y - uv_center.y
		du_world += (p3[i] - center) * du
		dv_world += (p3[i] - center) * dv

	if du_world.length_squared() < 1e-8 or dv_world.length_squared() < 1e-8:
		return active_split_axis

	du_world = du_world.normalized()
	dv_world = dv_world.normalized()

	var edge_dir: Vector3 = info.edge_dir.normalized()

	var u_align := abs(edge_dir.dot(du_world))
	var v_align := abs(edge_dir.dot(dv_world))

	if u_align >= v_align:
		return "vertical"
	else:
		return "horizontal"



func _draw_texel_split_axis_line(gizmo: EditorNode3DGizmo, brush: TileModeller) -> void:
	if active_split_quad_index < 0:
		return

	var bf := brush.brush_form
	var quad := bf.get_quads()[active_split_quad_index]
	if quad.size() != 4:
		return

	var viewport := EditorInterface.get_editor_viewport_3d()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	var mouse_pos := viewport.get_mouse_position()

	var a := brush.global_transform * bf.positions[quad[0]]
	var b := brush.global_transform * bf.positions[quad[1]]
	var c := brush.global_transform * bf.positions[quad[2]]

	var normal_world := (b - a).cross(c - a).normalized()
	if normal_world.length_squared() < 1e-8:
		return

	var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
	var right_world = axes.right.normalized()
	var down_world  = axes.down.normalized()
	if right_world.cross(down_world).dot(normal_world) < 0.0:
		down_world = -down_world

	var center_world := Vector3.ZERO
	for vi in quad:
		center_world += brush.global_transform * bf.positions[vi]
	center_world /= 4.0

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)

	var plane := Plane(normal_world, center_world.dot(normal_world))
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var p3_raw := []
	var puv_raw := []
	for vi in quad:
		p3_raw.append(brush.global_transform * bf.positions[vi])
		puv_raw.append(bf.uvs[vi])

	var get_d_uv = func(uv: Vector2) -> float:
		return uv.y if active_split_axis == "horizontal" else uv.x

	var uv_center := Vector2.ZERO
	for uv in puv_raw:
		uv_center += uv
	uv_center /= 4.0

	var order := []
	for i in range(4):
		order.append({
			"i": i,
			"a": atan2(puv_raw[i].y - uv_center.y, puv_raw[i].x - uv_center.x)
		})
	order.sort_custom(func(x, y): return x.a < y.a)

	var p3 := []
	var puv := []
	for e in order:
		p3.append(p3_raw[e.i])
		puv.append(puv_raw[e.i])

	if compute_triangle_normal(p3[0], p3[1], p3[2]).dot(normal_world) < 0.0:
		p3.reverse()
		puv.reverse()

	var du_world := Vector3.ZERO
	var dv_world := Vector3.ZERO
	for i in range(4):
		var du = puv[i].x - uv_center.x
		var dv = puv[i].y - uv_center.y
		du_world += (p3[i] - center_world) * du
		dv_world += (p3[i] - center_world) * dv

	if du_world.length() < 1e-6 or dv_world.length() < 1e-6:
		return

	du_world = du_world.normalized()
	dv_world = dv_world.normalized()

	var min_u := INF
	var max_u := -INF
	var min_v := INF
	var max_v := -INF
	for uv in puv:
		min_u = min(min_u, uv.x)
		max_u = max(max_u, uv.x)
		min_v = min(min_v, uv.y)
		max_v = max(max_v, uv.y)

	var umin_p := INF
	var umax_p := -INF
	var vmin_p := INF
	var vmax_p := -INF
	for i in range(4):
		var rp = p3[i] - center_world
		var up = rp.dot(du_world)
		var vp = rp.dot(dv_world)
		umin_p = min(umin_p, up)
		umax_p = max(umax_p, up)
		vmin_p = min(vmin_p, vp)
		vmax_p = max(vmax_p, vp)

	if abs(umax_p - umin_p) < 1e-8 or abs(vmax_p - vmin_p) < 1e-8:
		return

	var use_v := active_split_axis == "horizontal"

	var best_uv := 0.0
	var best_d := INF

	for i in range(4):
		var j := (i + 1) % 4

		var a3 = p3[i]
		var b3 = p3[j]
		var auv = puv[i]
		var buv = puv[j]

		var ab = b3 - a3
		var t := clamp((hit - a3).dot(ab) / ab.dot(ab), 0.0, 1.0)
		var p_edge = a3.lerp(b3, t)

		var d = p_edge.distance_squared_to(hit)
		if d < best_d:
			best_d = d
			best_uv = lerp(auv.y if use_v else auv.x,
						   buv.y if use_v else buv.x,
						   t)

	var uv_u := best_uv if not use_v else 0.0
	var uv_v := best_uv if use_v else 0.0

	
	var tileset := brush.tileset
	var src := tileset.get_source(brush.brush_form.face_source_by_id[(brush.brush_form.quad_face_id_by_key[quad])])
	if src == null or src.texture == null:
		return

	var atlas_size_px = src.texture.get_size()
	var texel_uv_x := 1.0 / float(atlas_size_px.x)
	var texel_uv_y := 1.0 / float(atlas_size_px.y)

	var texel_coord: float
	if active_split_axis == "horizontal":
		texel_coord = round(uv_v / texel_uv_y) * texel_uv_y
	else:
		texel_coord = round(uv_u / texel_uv_x) * texel_uv_x

	var dmin := INF
	var dmax := -INF
	for uv in puv:
		var d := get_d_uv.call(uv)
		dmin = min(dmin, d)
		dmax = max(dmax, d)

	var step := texel_uv_y if active_split_axis == "horizontal" else texel_uv_x
	var inner_min := dmin + step
	var inner_max := dmax - step
	#if inner_max <= inner_min + 1e-9:
		#return
	texel_coord = clamp(texel_coord, inner_min, inner_max)
	texel_coord = round(texel_coord / step) * step
	texel_coord = clamp(texel_coord, inner_min, inner_max)
	active_split_texel_coord = texel_coord
	var hits_world := []

	for i in range(4):
		var j := (i + 1) % 4

		var auv: Vector2 = puv[i]
		var buv: Vector2 = puv[j]
		var a3: Vector3  = p3[i]
		var b3: Vector3  = p3[j]

		var da = get_d_uv.call(auv) - texel_coord
		var db = get_d_uv.call(buv) - texel_coord

		if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
			var denom = get_d_uv.call(buv) - get_d_uv.call(auv)
			if abs(denom) < 1e-8:
				continue
			var t = (texel_coord - get_d_uv.call(auv)) / denom
			t = clamp(t, 0.0, 1.0)
			hits_world.append(a3.lerp(b3, t))
		elif abs(da) < 1e-8:
			var too_close := false
			for h in hits_world:
				if h.distance_to(a3) < 1e-6:
					too_close = true
					break
			if not too_close:
				hits_world.append(a3)

	if hits_world.size() < 2:
		return

	if hits_world.size() > 2:
		var best_i := 0
		var best_j := 1
		best_d = -INF
		for ii in range(hits_world.size()):
			for jj in range(ii + 1, hits_world.size()):
				var d = hits_world[ii].distance_squared_to(hits_world[jj])
				if d > best_d:
					best_d = d
					best_i = ii
					best_j = jj
		hits_world = [hits_world[best_i], hits_world[best_j]]

	var p0 = hits_world[0]
	var p1 = hits_world[1]

	var line_dir = (p1 - p0).normalized()
	var side_dir := normal_world.cross(line_dir).normalized()

	var half_w := 0.005
	var half_t := 0.003

	var f0 = p0 + side_dir * half_w + normal_world * half_t
	var f1 = p1 + side_dir * half_w + normal_world * half_t
	var f2 = p0 - side_dir * half_w + normal_world * half_t
	var f3 = p1 - side_dir * half_w + normal_world * half_t

	var b0 = p0 + side_dir * half_w - normal_world * half_t
	var b1 = p1 + side_dir * half_w - normal_world * half_t
	var b2 = p0 - side_dir * half_w - normal_world * half_t
	var b3 = p1 - side_dir * half_w - normal_world * half_t

	split_line_mesh.clear_surfaces()
	split_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, split_line_material)

	split_line_mesh.surface_add_vertex(f0); split_line_mesh.surface_add_vertex(f1); split_line_mesh.surface_add_vertex(f2)
	split_line_mesh.surface_add_vertex(f1); split_line_mesh.surface_add_vertex(f3); split_line_mesh.surface_add_vertex(f2)

	split_line_mesh.surface_add_vertex(b2); split_line_mesh.surface_add_vertex(b1); split_line_mesh.surface_add_vertex(b0)
	split_line_mesh.surface_add_vertex(b2); split_line_mesh.surface_add_vertex(b3); split_line_mesh.surface_add_vertex(b1)

	split_line_mesh.surface_add_vertex(b0); split_line_mesh.surface_add_vertex(b1); split_line_mesh.surface_add_vertex(f0)
	split_line_mesh.surface_add_vertex(b1); split_line_mesh.surface_add_vertex(f1); split_line_mesh.surface_add_vertex(f0)

	split_line_mesh.surface_add_vertex(b2); split_line_mesh.surface_add_vertex(f2); split_line_mesh.surface_add_vertex(b3)
	split_line_mesh.surface_add_vertex(b3); split_line_mesh.surface_add_vertex(f2); split_line_mesh.surface_add_vertex(f3)

	split_line_mesh.surface_add_vertex(b0); split_line_mesh.surface_add_vertex(f0); split_line_mesh.surface_add_vertex(b2)
	split_line_mesh.surface_add_vertex(b2); split_line_mesh.surface_add_vertex(f0); split_line_mesh.surface_add_vertex(f2)

	split_line_mesh.surface_add_vertex(b1); split_line_mesh.surface_add_vertex(b3); split_line_mesh.surface_add_vertex(f1)
	split_line_mesh.surface_add_vertex(b3); split_line_mesh.surface_add_vertex(f3); split_line_mesh.surface_add_vertex(f1)

	split_line_mesh.surface_end()

	gizmo.add_mesh(split_line_mesh, split_line_material, Transform3D.IDENTITY)


func compute_triangle_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	return (b - a).cross(c - a).normalized()


func _draw_split_axis_line(gizmo: EditorNode3DGizmo, brush: TileModeller) -> void:
	if active_split_quad_index < 0:
		return

	var bf := brush.brush_form
	var quad := bf.get_quads()[active_split_quad_index]
	if quad.size() != 4:
		return

	var a := bf.positions[quad[0]]
	var b := bf.positions[quad[1]]
	var c := bf.positions[quad[2]]
	var normal_local := (b - a).cross(c - a).normalized()
	var normal_world := (brush.global_transform.basis * normal_local).normalized()

	var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
	var right = axes.right.normalized()
	var down  = axes.down.normalized()

	if right.cross(down).dot(normal_world) < 0.0:
		down = -down

	var center_local := Vector3.ZERO
	for vi in quad:
		center_local += bf.positions[vi]
	center_local /= 4.0
	var center_world := brush.global_transform * center_local

	var p3 := []
	var p2 := []
	for vi in quad:
		var w := brush.global_transform * bf.positions[vi]
		p3.append(w)
		var rel := w - center_world
		p2.append(Vector2(rel.dot(right), rel.dot(down)))

	var viewport := EditorInterface.get_editor_viewport_3d()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return

	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)

	var plane := Plane(normal_world, center_world.dot(normal_world))
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var get_d = func(v: Vector2) -> float:
		return v.y if active_split_axis == "horizontal" else v.x
	var pixels_to_world := bf.pixels_to_world_unit
	var texel_world := 1.0 / pixels_to_world

	var rel_hit = hit - center_world
	var offset := get_d.call(Vector2(rel_hit.dot(right), rel_hit.dot(down)))
	offset = round(offset / texel_world) * texel_world

	var intersections := []

	var min_u := INF
	var max_u := -INF
	var min_v := INF
	var max_v := -INF

	for v in p2:
		min_u = min(min_u, v.x)
		max_u = max(max_u, v.x)
		min_v = min(min_v, v.y)
		max_v = max(max_v, v.y)

	var safe_offset := (
		clamp(offset, min_v + 0.0001, max_v - 0.0001)
		if active_split_axis == "horizontal"
		else clamp(offset, min_u + 0.0001, max_u - 0.0001)
	)

	var uv0: Vector2
	var uv1: Vector2

	if active_split_axis == "horizontal":
		uv0 = Vector2(min_u, safe_offset)
		uv1 = Vector2(max_u, safe_offset)
	else:
		uv0 = Vector2(safe_offset, min_v)
		uv1 = Vector2(safe_offset, max_v)

	var p0 = center_world + right * uv0.x + down * uv0.y
	var p1 = center_world + right * uv1.x + down * uv1.y
	var line_dir = (p1 - p0).normalized()

	var side_dir := normal_world.cross(line_dir).normalized()

	var half_w := 0.005    
	var half_t := 0.003   

	var f0 = p0 + side_dir * half_w + normal_world * half_t
	var f1 = p1 + side_dir * half_w + normal_world * half_t
	var f2 = p0 - side_dir * half_w + normal_world * half_t
	var f3 = p1 - side_dir * half_w + normal_world * half_t
	var b0 = p0 + side_dir * half_w - normal_world * half_t
	var b1 = p1 + side_dir * half_w - normal_world * half_t
	var b2 = p0 - side_dir * half_w - normal_world * half_t
	var b3 = p1 - side_dir * half_w - normal_world * half_t

	split_line_mesh.clear_surfaces()
	split_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, split_line_material)

	split_line_mesh.surface_add_vertex(f0)
	split_line_mesh.surface_add_vertex(f1)
	split_line_mesh.surface_add_vertex(f2)

	split_line_mesh.surface_add_vertex(f1)
	split_line_mesh.surface_add_vertex(f3)
	split_line_mesh.surface_add_vertex(f2)

	split_line_mesh.surface_add_vertex(b2)
	split_line_mesh.surface_add_vertex(b1)
	split_line_mesh.surface_add_vertex(b0)

	split_line_mesh.surface_add_vertex(b2)
	split_line_mesh.surface_add_vertex(b3)
	split_line_mesh.surface_add_vertex(b1)

	split_line_mesh.surface_add_vertex(b0)
	split_line_mesh.surface_add_vertex(b1)
	split_line_mesh.surface_add_vertex(f0)

	split_line_mesh.surface_add_vertex(b1)
	split_line_mesh.surface_add_vertex(f1)
	split_line_mesh.surface_add_vertex(f0)

	split_line_mesh.surface_add_vertex(b2)
	split_line_mesh.surface_add_vertex(f2)
	split_line_mesh.surface_add_vertex(b3)

	split_line_mesh.surface_add_vertex(b3)
	split_line_mesh.surface_add_vertex(f2)
	split_line_mesh.surface_add_vertex(f3)

	split_line_mesh.surface_add_vertex(b0)
	split_line_mesh.surface_add_vertex(f0)
	split_line_mesh.surface_add_vertex(b2)

	split_line_mesh.surface_add_vertex(b2)
	split_line_mesh.surface_add_vertex(f0)
	split_line_mesh.surface_add_vertex(f2)

	split_line_mesh.surface_add_vertex(b1)
	split_line_mesh.surface_add_vertex(b3)
	split_line_mesh.surface_add_vertex(f1)

	split_line_mesh.surface_add_vertex(b3)
	split_line_mesh.surface_add_vertex(f3)
	split_line_mesh.surface_add_vertex(f1)

	split_line_mesh.surface_end()

	gizmo.add_mesh(
		split_line_mesh,
		split_line_material,
		Transform3D.IDENTITY
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

func _point_in_convex_polygon_2d(p: Vector2, poly: Array) -> bool:
	var sign := 0
	for i in range(poly.size()):
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		var cross := (b - a).cross(p - a)
		if abs(cross) < 1e-6:
			continue
		var s := signf(cross)
		if sign == 0:
			sign = s
		elif sign != s:
			return false
	return true

func _find_quad_under_mouse(
	camera: Camera3D,
	brush: TileModeller,
	mouse_pos: Vector2
) -> int:
	var bf := brush.brush_form
	var quads := bf.get_quads()
	if quads.is_empty():
		return -1

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)

	var best_quad := -1
	var best_depth := INF

	for qi in range(quads.size()):
		var quad := quads[qi]
		if quad.size() != 4:
			continue

		var a := bf.positions[quad[0]]
		var b := bf.positions[quad[1]]
		var c := bf.positions[quad[2]]

		var normal_local := (b - a).cross(c - a)
		if normal_local.length_squared() < 1e-8:
			continue

		var normal_world := (brush.global_transform.basis * normal_local).normalized()

		var center_local := Vector3.ZERO
		for v in quad:
			center_local += bf.positions[v]
		center_local /= 4.0
		var center_world := brush.global_transform * center_local

		var plane := Plane(normal_world, center_world.dot(normal_world))
		var hit := plane.intersects_ray(ray_origin, ray_dir)
		if hit == null:
			continue

		var axes := TileEditorPlugin.plane_axes_from_normal_hardcoded(normal_world)
		var right = axes.right.normalized()
		var down  = axes.down.normalized()

		if right.cross(down).dot(normal_world) < 0.0:
			down = -down

		var poly := []
		var center_2d := Vector2.ZERO

		for vi in quad:
			var w := brush.global_transform * bf.positions[vi]
			var rel := w - center_world
			var p2 := Vector2(rel.dot(right), rel.dot(down))
			poly.append(p2)
			center_2d += p2
		center_2d /= 4.0

		poly.sort_custom(func(x, y):
			return atan2(x.y - center_2d.y, x.x - center_2d.x) < atan2(y.y - center_2d.y, y.x - center_2d.x)
		)

		var area := 0.0
		for i in range(4):
			var p0 = poly[i]
			var p1 = poly[(i + 1) % 4]
			area += p0.x * p1.y - p1.x * p0.y
		if area < 0.0:
			poly.reverse()

		var rel_hit = hit - center_world
		var hit_2d := Vector2(rel_hit.dot(right), rel_hit.dot(down))

		if not _point_in_convex_polygon_2d(hit_2d, poly):
			continue

		var depth = (hit - ray_origin).length()
		if depth < best_depth:
			best_depth = depth
			best_quad = qi

	return best_quad


func _quad_long_axis_local(node: BrushForm, quad: Array) -> Vector3:
	var best_len := -1.0
	var best_dir := Vector3.RIGHT

	for i in range(quad.size()):
		var a := node.positions[quad[i]]
		var b := node.positions[quad[(i + 1) % quad.size()]]
		var d := b - a
		var l := d.length()
		if l > best_len and l > 0.000001:
			best_len = l
			best_dir = d / l

	return best_dir

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
