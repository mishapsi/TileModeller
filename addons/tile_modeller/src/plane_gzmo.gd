extends EditorNode3DGizmoPlugin


enum AxisDir { X_POS, X_NEG, Y_POS, Y_NEG, Z_POS, Z_NEG }

var preview_material := StandardMaterial3D.new()
var major_grid_material := StandardMaterial3D.new()
var minor_grid_material := StandardMaterial3D.new()
var custom_quad_points:Array

func _init():
	major_grid_material.albedo_color = Color(0.2, 0.8, 1.0, 1.0)
	major_grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	major_grid_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	minor_grid_material.albedo_color = Color(0.3, 0.5, .5, 1.0)
	minor_grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	minor_grid_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	preview_material.albedo_color = Color(0, 1, 0, .35)
	preview_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		
func create_minor_grid(
	normal: Vector3,
	origin: Vector3,
	major := 1.0,
	minor := 0.25,
	half_extent := 10
) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var base_orientation := TileEditorPlugin.orientation_index_from_normal(normal)
	var axes = TileEditorPlugin.plane_axes_from_normal_hardcoded(normal)
	var right = axes.right
	var forward = axes.down

	var steps := int(major / minor)
	var range := half_extent * steps

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, minor_grid_material)

	for i in range(-range, range + 1):

		var offset := float(i) * minor

		mesh.surface_add_vertex(origin + right * offset + forward * half_extent * major)
		mesh.surface_add_vertex(origin + right * offset - forward * half_extent * major)

		mesh.surface_add_vertex(origin + forward * offset + right * half_extent * major)
		mesh.surface_add_vertex(origin + forward * offset - right * half_extent * major)
		mesh.surface_set_color(Color.WHITE)

	mesh.surface_end()
	return mesh

func create_major_grid(
	normal: Vector3,
	origin: Vector3,
	major := 1.0,
	half_extent := 10
) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()

	var base_orientation := TileEditorPlugin.orientation_index_from_normal(normal)
	var axes = TileEditorPlugin.plane_axes_from_normal_hardcoded(normal)

	var right = axes.right
	var forward = axes.down
	
	mesh.surface_begin(Mesh.PRIMITIVE_LINES,major_grid_material)

	for i in range(-half_extent, half_extent + 1):
		var offset := float(i) * major

		mesh.surface_add_vertex(origin + right * offset + forward * half_extent * major)
		mesh.surface_add_vertex(origin + right * offset - forward * half_extent * major)

		mesh.surface_add_vertex(origin + forward * offset + right * half_extent * major)
		mesh.surface_add_vertex(origin + forward * offset - right * half_extent * major)

	mesh.surface_end()
	return mesh

func _get_gizmo_name() -> String:
	return "Plane"

func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	return "PLANE"

func _has_gizmo(node: Node3D) -> bool:
	return node is TileModeller

func get_preview_material(brush) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	return mat

func _redraw(gizmo: EditorNode3DGizmo):

	gizmo.clear()
	var brush:TileModeller = gizmo.get_node_3d()
	if brush.brush_form == null:
		return
	if brush.tileset == null:
		return
	if brush.tileset.get_source_count() == 0:
		return
	var selected = EditorInterface.get_selection().get_selected_nodes()
	if selected.is_empty():
		return
	selected = selected[0]
	var cursor = brush.cursor

	var viewport := EditorInterface.get_editor_viewport_3d()
	var camera := viewport.get_camera_3d()
	if camera == null:
		return

	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	var plane := TileEditorPlugin.get_axis_aligned_plane(camera, cursor.global_position)
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var normal := plane.normal.normalized()

	var snapped := TileEditorPlugin.snap_point_to_plane_grid(
		hit,
		camera,
		normal,
		cursor.global_position,
		Vector2(brush.vertex_snap, brush.vertex_snap)/ Vector2(brush.brush_form.pixels_to_world_unit,brush.brush_form.pixels_to_world_unit)
	)
	var base_orientation := TileEditorPlugin.orientation_index_from_normal(normal)
	var basis := TileEditorPlugin.basis_from_plane(normal,base_orientation)

	if brush.tool_mode not in [TileModeller.TOOL_MODE.QUAD_SPLIT]:
		var minor := create_minor_grid(
			normal,
			cursor.global_position,
			1.0,
			0.25,
			2
		)

		var major := create_major_grid(
			normal,
			cursor.global_position,
			1.0,
			1
		)

		gizmo.add_mesh(minor, minor_grid_material, Transform3D.IDENTITY)
		gizmo.add_mesh(major, major_grid_material, Transform3D.IDENTITY)
	if brush.tool_mode in [TileModeller.TOOL_MODE.TILE] and brush.select_mode == TileModeller.TileSelectMode.TILES:
		var stamp = brush.get_tile_stamp_offsets()

		if stamp.is_empty():
			stamp[Vector2i.ZERO] = brush.tile_coord

		var preview_mesh := ImmediateMesh.new()
		preview_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

		for offset in stamp.keys():
			var tile_coord = stamp[offset]
			_append_tile_preview_quad(
				preview_mesh,
				brush,
				offset,
				tile_coord,
				snapped,
				normal,
				basis
			)

		preview_mesh.surface_end()
		update_preview_material(brush)
		gizmo.add_mesh(preview_mesh, preview_material)
	else:
		var quad_mesh:ImmediateMesh = build_preview_quad_from_points(brush,custom_quad_points, normal)
		update_preview_material(brush)
		gizmo.add_mesh(quad_mesh, preview_material)

func _append_tile_preview_quad(
	mesh: ImmediateMesh,
	brush: TileModeller,
	offset: Vector2i,
	tile_coord: Vector2,
	snapped: Vector3,
	normal: Vector3,
	basis: Basis
) -> void:
	var axes = TileEditorPlugin.plane_axes_from_normal_hardcoded(normal)
	var right: Vector3 = axes.right
	var down: Vector3  = axes.down

	var stamp_origin := TileEditorPlugin.get_stamp_origin(snapped, brush, normal)
	var tile_step_world := float(brush.tile_size.x) / float(brush.brush_form.pixels_to_world_unit)

	var rot_offset: Vector2i
	match brush.orientation & 3:
		0:
			rot_offset = offset
		1:
			rot_offset = Vector2i(-offset.y, offset.x)
		2:
			rot_offset = Vector2i(-offset.x, -offset.y)
		3:
			rot_offset = Vector2i(offset.y, -offset.x)

	var place_pos :=\
		stamp_origin\
		+ right * (rot_offset.x * tile_step_world)\
		+ down  * (rot_offset.y * tile_step_world)

	place_pos += TileEditorPlugin.wall_face_offset2(normal, right, down, brush)

	var u_axis: Vector3 = basis.x.normalized()
	var v_axis: Vector3 = basis.z.normalized()

	var pts := [
		place_pos,                                       
		place_pos + u_axis * tile_step_world,                 
		place_pos + v_axis * tile_step_world,                  
		place_pos + u_axis * tile_step_world + v_axis * tile_step_world, 
	]

	var pivot = (pts[0] + pts[1] + pts[2] + pts[3]) * 0.25
	var angle := deg_to_rad(brush.orientation * 90.0)

	for i in range(4):
		var p = pts[i] - pivot
		p = p.rotated(normal, angle)
		pts[i] = pivot + p

	# UVs for this tile
	var uvs := get_preview_quad_uvs_for_tile(brush, tile_coord, basis)
	if uvs.size() != 4:
		return

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[0]); mesh.surface_add_vertex(pts[0])
	mesh.surface_set_uv(uvs[1]); mesh.surface_add_vertex(pts[1])
	mesh.surface_set_uv(uvs[2]); mesh.surface_add_vertex(pts[2])

	mesh.surface_set_uv(uvs[1]); mesh.surface_add_vertex(pts[1])
	mesh.surface_set_uv(uvs[2]); mesh.surface_add_vertex(pts[2])
	mesh.surface_set_uv(uvs[3]); mesh.surface_add_vertex(pts[3])

func get_preview_quad_uvs_for_tile(
	brush: TileModeller,
	tile_coord: Vector2,
	basis: Basis
) -> PackedVector2Array:
	var source_id := brush.active_tileset_source_id
	if brush.tileset == null or not brush.tileset.has_source(source_id):
		return PackedVector2Array()

	var atlas_src := brush.tileset.get_source(source_id) as TileSetAtlasSource
	if atlas_src == null or atlas_src.texture == null:
		return PackedVector2Array()

	var atlas_size := Vector2(atlas_src.texture.get_size())
	var tile_size := Vector2(brush.tile_size)

	var uv_rect := Rect2(tile_coord * tile_size, tile_size)

	var uv_min := uv_rect.position / atlas_size
	var uv_max := (uv_rect.position + uv_rect.size) / atlas_size

	var u_axis := (basis * Vector3.RIGHT).normalized()
	var v_axis := (basis * Vector3.BACK).normalized()
	var n_axis := basis * Vector3.UP

	if u_axis.cross(v_axis).dot(n_axis) < 0.0:
		u_axis = -u_axis
		v_axis = -v_axis

	var is_wall_surface = func(n: Vector3) -> bool:
		n = n.normalized()
		return abs(n.y) < 0.99

	var should_flip_wall_uv = func(n: Vector3) -> bool:
		n = n.normalized()
		if abs(n.y) > 0.99:
			return false
		return n.x < 0.0 or n.z < 0.0

	var quad_world := float(brush.tile_size.x) / float(brush.brush_form.pixels_to_world_unit)

	var corners := [
		Vector3(0, 0, 0),
		Vector3(quad_world, 0, 0),
		Vector3(0, 0, quad_world),
		Vector3(quad_world, 0, quad_world),
	]

	var out_uvs := PackedVector2Array()

	for c in corners:

		var rel = basis * c

		var u = rel.dot(u_axis) / quad_world
		var v = rel.dot(v_axis) / quad_world

		u = 1.0 - u
		v = 1.0 - v

		if is_wall_surface.call(n_axis):
			var tmp = u
			u = v
			v = 1.0 - tmp

			if should_flip_wall_uv.call(n_axis):
				u = 1.0 - u
				v = 1.0 - v

		out_uvs.append(Vector2(
			lerp(uv_min.x, uv_max.x, u),
			lerp(uv_min.y, uv_max.y, v)
		))

	return out_uvs


func get_selected_tile_uv_data(brush: TileModeller):
	if brush.tileset == null:
		return null

	var source_id = brush.active_tileset_source_id
	var tile_id = brush.tile_coord

	var source := brush.tileset.get_source(source_id)
	if source == null or not source is TileSetAtlasSource:
		return null

	var atlas := source as TileSetAtlasSource
	var texture := atlas.get_texture()
	var region := atlas.get_tile_texture_region(tile_id)

	return {
		"texture": texture,
		"region": region,
		"atlas_size": texture.get_size()
	}

func region_to_uvs(region: Rect2, atlas_size: Vector2) -> PackedVector2Array:
	var uv0 := region.position / atlas_size
	var uv1 := (region.position + Vector2(region.size.x, 0)) / atlas_size
	var uv2 := (region.position + region.size) / atlas_size
	var uv3 := (region.position + Vector2(0, region.size.y)) / atlas_size

	return PackedVector2Array([uv0, uv1, uv2, uv3])
func tile_corners_to_uvs(
	brush: TileModeller,
	atlas_size: Vector2
) -> PackedVector2Array:
	var uvs := PackedVector2Array()

	for c in brush.tile_corners:
		uvs.append(c / atlas_size)

	return uvs

func rotate_quad_uvs(
	uvs: PackedVector2Array,
	orientation: int
) -> PackedVector2Array:
	var o := orientation % 4
	if o == 0:
		return uvs

	var c := [
		uvs[0],
		uvs[1],
		uvs[3],
		uvs[2],
	]

	match o:
		1:
			c = [c[3], c[0], c[1], c[2]]
		2:
			c = [c[2], c[3], c[0], c[1]]
		3:
			c = [c[1], c[2], c[3], c[0]]

	return PackedVector2Array([
		c[0],
		c[1],
		c[3],
		c[2],
	])

func build_preview_quad_from_points(
	brush: TileModeller,
	points: PackedVector3Array,
	normal: Vector3
) -> Mesh:
	var mesh := ImmediateMesh.new()

	var pts := points

	var tile_size := Vector2(brush.tile_size)

	var orientation := brush.orientation
	if pts.is_empty():
		return mesh
	var angle := deg_to_rad(orientation * 90.0)
	var pivot: Vector3

	if brush.select_mode == TileModeller.TileSelectMode.TILES:
		pivot = Vector3.ZERO
		for p in pts:
			pivot += p
		pivot /= pts.size()
	else:
		pivot = pts[0]

	var local_axis := normal

	var current_size := pts[0].distance_to(pts[1])
	var target_size = brush.brush_form.get_quad_size(tile_size.x * current_size)
	var scale = target_size / current_size

	for i in range(pts.size()):
		var p = pts[i] - pivot
		p *= scale
		p = p.rotated(local_axis, angle)
		pts[i] = pivot + p

	# ─── UVs (no rotation!) ───
	var uvs := get_preview_quad_uvs(brush)
	if uvs.size() != 4:
		return mesh

	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[0])
	mesh.surface_add_vertex(pts[0])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[1])
	mesh.surface_add_vertex(pts[1])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[2])
	mesh.surface_add_vertex(pts[2])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[2])
	mesh.surface_add_vertex(pts[2])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[3])
	mesh.surface_add_vertex(pts[3])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[0])
	mesh.surface_add_vertex(pts[0])

	mesh.surface_end()
	return mesh


func get_preview_quad_uvs(brush: TileModeller) -> PackedVector2Array:
	var source_id := brush.active_tileset_source_id
	if brush.tileset == null or not brush.tileset.has_source(source_id):
		return PackedVector2Array()

	var atlas_src := brush.tileset.get_source(source_id) as TileSetAtlasSource
	if atlas_src == null or atlas_src.texture == null:
		return PackedVector2Array()

	var atlas_size := Vector2(atlas_src.texture.get_size())

	var quad_uvs_raw := generate_custom_quad_uvs(
		brush.tile_coord,
		brush.tile_corners,
		Vector2(brush.tile_size),
		atlas_size
	)

	return PackedVector2Array([
		quad_uvs_raw[0],
		quad_uvs_raw[1],
		quad_uvs_raw[2],
		quad_uvs_raw[3],
	])




func generate_custom_quad_uvs(
	tile_coord: Vector2,
	tile_corners: Array,
	tile_size: Vector2,
	atlas_size: Vector2
) -> Array:

	var uvs := []

	for c in tile_corners:
		var px = tile_coord * tile_size + c
		uvs.append(px / atlas_size)
	return uvs


func update_preview_material(brush: TileModeller):
	var uv_data = get_selected_tile_uv_data(brush)
	if uv_data == null:
		return

	preview_material.albedo_texture = uv_data.texture
	preview_material.albedo_color = Color(.5, 1.25, 1.5, .25)

	preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	preview_material.emission_enabled = false
	preview_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	preview_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST



func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	gizmo.get_node_3d().update_gizmos()
