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
		# Skip major lines
		if i % steps == 0:
			continue

		var offset := float(i) * minor

		mesh.surface_add_vertex(origin + right * offset + forward * half_extent * major)
		mesh.surface_add_vertex(origin + right * offset - forward * half_extent * major)

		mesh.surface_add_vertex(origin + forward * offset + right * half_extent * major)
		mesh.surface_add_vertex(origin + forward * offset - right * half_extent * major)

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

	# Mouse ray
	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	# Plane under cursor
	var plane := TileEditorPlugin.get_axis_aligned_plane(camera, cursor.global_position)
	var hit := plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return

	var normal := plane.normal.normalized()

	# 🔑 Same snapping logic as placement
	var snapped := TileEditorPlugin.snap_point_to_plane_grid(
		hit,
		camera,
		normal,
		cursor.global_position,
		Vector2(brush.vertex_snap, brush.vertex_snap)/ Vector2(brush.brush_form.pixels_to_world_unit,brush.brush_form.pixels_to_world_unit)
	)
	var base_orientation := TileEditorPlugin.orientation_index_from_normal(normal)
	var basis := TileEditorPlugin.basis_from_plane(normal,base_orientation)
	# ─────────────────────────────
	# 1️⃣ Optional: large helper plane
	# ─────────────────────────────
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

	var axes = TileEditorPlugin.plane_axes_from_normal_hardcoded(normal)
	var right : Vector3 = axes.right
	var down  : Vector3 = axes.down

	var anchor = brush.tile_corners[0]

	var face_offset = TileEditorPlugin.wall_face_offset(brush,normal)

	var world_pts := PackedVector3Array()

	var half := 1.0
	var preview_offset := basis.x * half + basis.z * half

	var stamp = brush.get_tile_stamp_offsets()
	# Fallback: single tile behavior
	if stamp.is_empty():
		stamp[Vector2i.ZERO] = brush.tile_coord

	for offset in stamp.keys():
		var tile_coord = stamp[offset]
		axes = TileEditorPlugin.plane_axes_from_normal_hardcoded(normal)
		right = axes.right
		down  = axes.down
		var stamp_origin := TileEditorPlugin.get_stamp_origin(snapped, brush, normal)

		var place_pos = stamp_origin + right * offset.x + down  * offset.y
		for c in brush.tile_corners:
			var u = ((c.x - anchor.x) / brush.tile_size.x)
			var v = ((c.y - anchor.y) / brush.tile_size.y)

			world_pts.append(
				(right * u) + (down * v) + place_pos)

	var quad_mesh:ImmediateMesh = build_preview_quad_from_points(brush,world_pts, normal)
	update_preview_material(brush)
	gizmo.add_mesh(quad_mesh, preview_material)


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

	# stored → canonical
	var c := [
		uvs[0],
		uvs[1],
		uvs[3],
		uvs[2],
	]

	match o:
		1: # 90° CW
			c = [c[3], c[0], c[1], c[2]]
		2: # 180°
			c = [c[2], c[3], c[0], c[1]]
		3: # 270° CW
			c = [c[1], c[2], c[3], c[0]]

	# canonical → stored
	return PackedVector2Array([
		c[0], # TL
		c[1], # TR
		c[3], # BL
		c[2], # BR
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
	if brush.select_mode == TileModeller.TileSelectMode.TILES:
		orientation = 0
	if brush.select_mode == TileModeller.TileSelectMode.CORNERS:
		pts = custom_quad_points

	var angle := deg_to_rad(orientation * 90.0)
	var pivot := pts[0]
	var local_axis := normal

	var current_size := pts[0].distance_to(pts[1])
	var target_size = brush.brush_form.get_quad_size(tile_size.x * current_size)
	var scale = target_size / current_size

	for i in range(pts.size()):
		var p := pts[i] - pivot
		p *= scale
		p = p.rotated(local_axis, angle)
		pts[i] = pivot + p

	# ─── UVs (no rotation!) ───
	var uvs := get_preview_quad_uvs(brush)
	if uvs.size() != 4:
		return mesh

	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Triangle 1: 0,1,2
	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[0])
	mesh.surface_add_vertex(pts[0])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[1])
	mesh.surface_add_vertex(pts[1])

	mesh.surface_set_normal(normal)
	mesh.surface_set_uv(uvs[2])
	mesh.surface_add_vertex(pts[2])

	# Triangle 2: 2,3,0
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

	# IMPORTANT: same reorder used in placement
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
	preview_material.albedo_color = Color(1, 1, 1, .5)
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material.blend_mode = BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA
	preview_material.albedo_texture_force_srgb = true
	preview_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	preview_material.texture_filter =BaseMaterial3D.TEXTURE_FILTER_NEAREST



func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	gizmo.get_node_3d().update_gizmos()
