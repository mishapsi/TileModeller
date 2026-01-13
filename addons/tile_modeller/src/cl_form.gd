@tool
class_name BrushForm
extends Resource
@export var pixels_to_world_unit:int = 32

@export var reset_vertex_colors = false:
	set(value):
		colors.clear()
		for i in indices:
			colors.append(Color.WHITE)
enum Topology {
	TRIANGLES = RenderingServer.PrimitiveType.PRIMITIVE_TRIANGLES,
	TRIANGLE_STRIP = RenderingServer.PrimitiveType.PRIMITIVE_TRIANGLE_STRIP,
	LINES = RenderingServer.PrimitiveType.PRIMITIVE_LINES,
	LINE_STRIP = RenderingServer.PrimitiveType.PRIMITIVE_LINE_STRIP,
	POINTS = RenderingServer.PrimitiveType.PRIMITIVE_POINTS,
}

@export var primitive : Topology = Topology.TRIANGLES

@export_subgroup("data")
@export var positions : Array[Vector3]
@export var normals : Array[Vector3]
@export var uvs : Array[Vector2]
@export var indices : Array[int]
@export var colors    : Array[Color]
@export var face_source_by_id := {} 
@export var quad_face_id_by_key := {}

var _next_face_id := 1


@export_subgroup("surface") 
@export var recalculated_normals : bool = true 

var active_quad_indices: Array[int] = []
var active_vertex_indices: Array[int] = []


const POS_EPS := 0.0001

const PEERING_TO_BITMASK := {
	TileSet.CELL_NEIGHBOR_TOP_SIDE: 1,
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE: 2,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE: 4,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE: 8,
	TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER: 16,
	TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER: 32,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER: 64,
	TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER: 128,
}

const BITMASK_DIRS := {
	"N":  TileSet.CELL_NEIGHBOR_TOP_SIDE,
	"E":  TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	"S":  TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	"W":  TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	"NE": TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	"SE": TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	"SW": TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	"NW": TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
}

const CARDINAL_KEYS := ["N", "E", "S", "W","NE", "SE", "SW", "NW"]

const GRID_DIRS_2D := {
	"N":  Vector2i(0, 1),
	"E":  Vector2i(-1, 0),
	"S":  Vector2i(0, -1),
	"W":  Vector2i(1, 0),
	"NE": Vector2i(-1, 1),
	"SE": Vector2i(-1, -1),
	"SW": Vector2i(1, -1),
	"NW": Vector2i(1, 1),
}

const GRID_DIRS_2D_WALLS_NEG := {
	"N":  Vector2i(0, -1),
	"E":  Vector2i(1, 0),
	"S":  Vector2i(0, 1),
	"W":  Vector2i(-1, 0),
	"NE": Vector2i(1, -1),
	"SE": Vector2i(1, 1),
	"SW": Vector2i(-1, 1),
	"NW": Vector2i(-1, -1),
}

const GRID_DIRS_2D_WALLS_POS := {
	"N":  Vector2i(0, 1),
	"E":  Vector2i(-1, 0),
	"S":  Vector2i(0, -1),
	"W":  Vector2i(1, 0),
	"NE": Vector2i(-1, 1),
	"SE": Vector2i(-1, -1),
	"SW": Vector2i(1, -1),
	"NW": Vector2i(1, 1),
}

func _alloc_face_id() -> int:
	var id := _next_face_id
	_next_face_id += 1
	return id

func get_quad_size(pixels:float):
	return pixels/pixels_to_world_unit

var _terrain_uv_lookup := {} 

func build_terrain_peering_uv_map(
	tileset: TileSet,
	source_id: int,
	terrain_set: int
) -> void:
	_terrain_uv_lookup.clear()

	if tileset == null or not tileset.has_source(source_id):
		return

	var atlas := tileset.get_source(source_id)
	if not (atlas is TileSetAtlasSource) or atlas.texture == null:
		return

	var region = atlas.texture_region_size
	if region.x <= 0 or region.y <= 0:
		return

	var tex_size := Vector2i(atlas.texture.get_size())
	var grid := Vector2i(tex_size.x / region.x, tex_size.y / region.y)

	for y in grid.y:
		for x in grid.x:
			var coords := Vector2i(x, y)
			if not atlas.has_tile(coords):
				continue

			var td = atlas.get_tile_data(coords, 0)
			if td == null or td.terrain_set != terrain_set or td.terrain < 0:
				continue

			var terrain_id = td.terrain
			var bitmask := 0

			for p in PEERING_TO_BITMASK:
				if td.get_terrain_peering_bit(p) == terrain_id:
					bitmask |= PEERING_TO_BITMASK[p]

			if not _terrain_uv_lookup.has(terrain_id):
				_terrain_uv_lookup[terrain_id] = {}

			if _terrain_uv_lookup[terrain_id].has(bitmask):
				continue

			_terrain_uv_lookup[terrain_id][bitmask] = Rect2(
				coords.x * region.x,
				coords.y * region.y,
				region.x,
				region.y
			)

func resolve_terrain_uv_for_bitmask(
	terrain_id: int,
	bitmask: int
) -> Rect2:
	var terrain := _terrain_uv_lookup.get(terrain_id)
	if terrain == null:
		return Rect2()

	if terrain.has(bitmask):
		return terrain[bitmask]
	var best := -1
	var best_score := -1

	for m in terrain:
		if (bitmask & m) == m:
			var s := count_set_bits(m)
			if s > best_score:
				best_score = s
				best = m

	if best >= 0:
		return terrain[best]

	return terrain.get(0, Rect2())

func count_set_bits(v: int) -> int:
	var c := 0
	while v:
		c += v & 1
		v >>= 1
	return c

func compute_triangle_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	return (b - a).cross(c - a).normalized()

func is_triangle_degenerate(a: Vector3, b: Vector3, c: Vector3, eps := 1e-6) -> bool:
	return (b - a).cross(c - a).length_squared() < eps

func triangle_faces_normal(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal: Vector3,
	eps := 0.999
) -> bool:
	return compute_triangle_normal(a, b, c).dot(normal.normalized()) > eps

func _pos_key(p: Vector3, eps := 0.1) -> Vector3i:
	return Vector3i(
		int(round(p.x / eps)),
		int(round(p.y / eps)),
		int(round(p.z / eps))
	)

func pos_eq(a: Vector3, b: Vector3) -> bool:
	return a.distance_squared_to(b) < POS_EPS

func rotate_dir_2d(dir: Vector2i, orientation: int) -> Vector2i:
	match orientation & 3:
		0:
			return dir
		1:
			return Vector2i(dir.y, -dir.x)
		2:
			return Vector2i(-dir.x, -dir.y)
		3:
			return Vector2i(-dir.y, dir.x)
	return dir

func stable_plane_axes_from_normal(n: Vector3) -> Array[Vector3]:
	n = n.normalized()

	var up := Vector3.UP
	if abs(n.dot(up)) > 0.99:
		up = Vector3.RIGHT

	var right := up.cross(n).normalized()
	var down  := n.cross(right).normalized()

	if right.dot(Vector3.RIGHT) > 0:
		right = -right
		down  = -down

	return [right, down]

func rotate_axes_in_plane(right: Vector3, down: Vector3, orientation: int) -> Array:
	match orientation & 3:
		0:
			return [right, down]
		1:
			return [-down, right]
		2:
			return [-right, -down]
		3:
			return [down, -right]
	return [right, down]

func plane_orientation_offset(n: Vector3) -> int:
	n = n.normalized()

	if abs(n.y) > 0.99:
		return 0

	return 1

func orientation_index_from_normal(n: Vector3) -> int:
	n = n.normalized()

	if abs(n.x) > abs(n.y) and abs(n.x) > abs(n.z):
		return 1 if n.x > 0.0 else 3
	elif abs(n.y) > abs(n.z):
		return 3 if n.y > 0.0 else 1
	else:
		return 3 if n.z > 0.0 else 3


func is_wall_surface(n: Vector3) -> bool:
	n = n.normalized()
	return abs(n.y) < 0.99

func should_flip_wall_uv(n: Vector3) -> bool:
	n = n.normalized()

	if abs(n.y) > 0.99:
		return false

	return n.x < 0.0 or n.z < 0.0

func rotate_grid_dirs_2d(
	dirs: Dictionary,
	orientation: int
) -> Dictionary:
	var o := orientation & 3
	if o == 0:
		return dirs.duplicate()

	var result := {}

	for key in dirs.keys():
		var v: Vector2i = dirs[key]
		var r := v

		match o:
			1: r = Vector2i(v.y, -v.x)
			2: r = Vector2i(-v.x, -v.y)
			3: r = Vector2i(-v.y, v.x)

		for k in GRID_DIRS_2D.keys():
			if GRID_DIRS_2D[k] == r:
				result[k] = r
				break

	return result

func compute_neighbor_peering_offsets(
	normal: Vector3,
	orientation: int,
	tile_size:int
) -> Dictionary:
	var axes := stable_plane_axes_from_normal(normal)

	var plane_rot := plane_orientation_offset(normal)
	var final_orientation := (orientation + plane_rot) & 3

	var rotated := rotate_axes_in_plane(axes[0], axes[1], final_orientation)

	var right = rotated[0]
	var down  = rotated[1]

	var result := {}

	for key in GRID_DIRS_2D.keys():
		var dir2d = GRID_DIRS_2D[key]
		if plane_rot == 1:
			if !should_flip_wall_uv(normal):
				dir2d = GRID_DIRS_2D_WALLS_NEG[key]
			else:
				dir2d = GRID_DIRS_2D_WALLS_POS[key]
		var offset = (right * dir2d.x + down * dir2d.y) * get_quad_size(tile_size)

		result[key] = {
			"offset": offset,
			"bit": PEERING_TO_BITMASK[BITMASK_DIRS[key]]
		}

	return result


func neighbor_has_matching_terrain(
	origin: Vector3,
	offset: Vector3,
	normal: Vector3,
	_basis: Basis,
	tile_size: Vector2,
	atlas_size: Vector2,
	atlas_src: TileSetAtlasSource,
	terrain_set: int,
	terrain_id: int
) -> bool:
	var QUAD_LOCAL := [
		Vector3(0, 0, 0),
		Vector3(get_quad_size(tile_size.x), 0, 0),
		Vector3(0, 0, get_quad_size(tile_size.x)),
		Vector3(get_quad_size(tile_size.x), 0, get_quad_size(tile_size.x)),
	]
	var local := QUAD_LOCAL

	var np := []
	for v in local:
		np.append(origin + offset + _basis * v)

	var nt := [
		[np[0], np[1], np[2]],
		[np[1], np[3], np[2]],
	]

	for tri in nt:
		var ti := find_triangle_by_vertices(tri)
		if ti == -1:
			continue

		var i0 := indices[ti]
		var i1 := indices[ti + 1]
		var i2 := indices[ti + 2]

		var coords := get_tile_coords_from_triangle_uvs(
			uvs[i0], uvs[i1], uvs[i2],
			tile_size,
			atlas_size
		)

		if _tile_matches_terrain(atlas_src, coords, terrain_set, terrain_id):
			if triangle_faces_normal(
				positions[i0],
				positions[i1],
				positions[i2],
				normal
			):
				return true

	return false

func get_tile_coords_from_triangle_uvs(
	u0: Vector2, u1: Vector2, u2: Vector2,
	tile_size: Vector2,
	atlas_size: Vector2
) -> Vector2i:
	var umin := Vector2(
		min(u0.x, min(u1.x, u2.x)),
		min(u0.y, min(u1.y, u2.y))
	)

	var eps := Vector2(0.001, 0.001) / atlas_size
	umin += eps

	var px := umin.x * atlas_size.x
	var py := umin.y * atlas_size.y

	return Vector2i(
		floori(px / tile_size.x),
		floori(py / tile_size.y)
	)


func _tile_matches_terrain(
	atlas_src: TileSetAtlasSource,
	coords: Vector2i,
	terrain_set: int,
	terrain_id: int
) -> bool:
	if not atlas_src.has_tile(coords):
		return false

	var td := atlas_src.get_tile_data(coords, 0)
	if td == null:
		return false

	return td.terrain_set == terrain_set and td.terrain == terrain_id

func terrain_id_from_fallback_tile(
	atlas_src: TileSetAtlasSource,
	terrain_set: int,
	fallback_tile_coord: Vector2
) -> int:
	var coords := Vector2i(fallback_tile_coord)

	if not atlas_src.has_tile(coords):
		return -1

	var td := atlas_src.get_tile_data(coords, 0)
	if td == null:
		return -1

	if td.terrain_set != terrain_set:
		return -1

	return td.terrain

func generate_quad_uvs(
	origin: Vector3,
	_basis: Basis,
	uv_rect: Rect2,
	atlas_size: Vector2,
	tile_size:Vector2
) -> Array:

	var u_axis := (_basis * Vector3.RIGHT).normalized()
	var v_axis := (_basis * Vector3.BACK).normalized()
	var n_axis := _basis * Vector3.UP

	if u_axis.cross(v_axis).dot(n_axis) < 0.0:
		u_axis = -u_axis
		v_axis = -v_axis

	var uv_min := uv_rect.position / atlas_size
	var uv_max := (uv_rect.position + uv_rect.size) / atlas_size

	var corners := [
		Vector3(0, 0, 0),
		Vector3(get_quad_size(tile_size.x), 0, 0),
		Vector3(0, 0, get_quad_size(tile_size.x)),
		Vector3(get_quad_size(tile_size.x), 0, get_quad_size(tile_size.x)),
	]
	var uvs := []

	for c in corners:
		var world = origin + _basis * c
		var rel = world - origin

		var u = rel.dot(u_axis) / get_quad_size(tile_size.x)
		var v = rel.dot(v_axis) / get_quad_size(tile_size.x)
		u = 1.0 - u
		v = 1.0 - v

		if is_wall_surface(n_axis):
			var tmp = u
			u = v
			v = 1.0 - tmp

			if should_flip_wall_uv(n_axis):
				u = 1.0 - u
				v = 1.0 - v


		var uv := Vector2(
			lerp(uv_min.x, uv_max.x, u),
			lerp(uv_min.y, uv_max.y, v)
		)

		uvs.append(uv)

	return uvs

func place_quad_undoable(
	origin: Vector3,
	normal: Vector3,
	_basis: Basis,
	source_id:int,
	fallback_tile_coord: Vector2,
	tile_size: Vector2,
	tileset: TileSet,
	brush_orientation,
) -> void:

	var undo_redo := EditorInterface.get_editor_undo_redo()

	if not _quad_painting:
		begin_quad_paint()

	undo_redo.create_action(
		"Paint Quads",
		UndoRedo.MERGE_ENDS
	)

	undo_redo.add_do_method(
		self,
		"_place_quad_internal",
		origin,
		normal,
		_basis,
		source_id,
		fallback_tile_coord,
		tile_size,
		tileset,
		brush_orientation
	)
	undo_redo.add_undo_method(
		self,
		"_set_mesh_state",
		_quad_paint_before_state
	)

	undo_redo.commit_action()

func _place_quad_internal(
	origin: Vector3,
	normal: Vector3,
	_basis: Basis,
	source_id:int,
	fallback_tile_coord: Vector2,
	tile_size: Vector2,
	tileset: TileSet,
	brush_orientation: int,
) -> void:
	var terrain_set := 0

	if not tileset.has_source(source_id):
		return

	var atlas_src := tileset.get_source(source_id) as TileSetAtlasSource
	if atlas_src == null or atlas_src.texture == null:
		return

	var atlas_size := Vector2(atlas_src.texture.get_size())

	var terrain_id := terrain_id_from_fallback_tile(
		atlas_src,
		terrain_set,
		fallback_tile_coord
	)

	var has_terrain := terrain_id >= 0
	var base_orientation := 0
	if has_terrain:
		base_orientation = orientation_index_from_normal(normal)
	var quad_orientation = brush_orientation

	var orientation = (base_orientation+quad_orientation)
	ensure_terrain_peering_uv_map(tileset, 0, 0)
	var QUAD_LOCAL := [
		Vector3(0, 0, 0),
		Vector3(get_quad_size(tile_size.x), 0, 0),
		Vector3(0, 0, get_quad_size(tile_size.x)),
		Vector3(get_quad_size(tile_size.x), 0, get_quad_size(tile_size.x)),
	]
	var local := QUAD_LOCAL
	var p := []
	for v in local:
		p.append(origin + _basis * v)

	if !has_terrain:
		var _orientation = (base_orientation + quad_orientation)
		var angle := deg_to_rad(_orientation * 90.0)

		var center := Vector3.ZERO
		for v in p:
			center += v
		center /= p.size()

		var axis := normal.normalized()

		for i in p.size():
			var local_p = p[i] - center
			
			local_p = local_p.rotated(axis, angle)
			p[i] = center + local_p

	var tris := [
		[p[0], p[1], p[2]],
		[p[1], p[3], p[2]],
	]

	var bitmask := 0

	if has_terrain:
		var neighbors := compute_neighbor_peering_offsets(normal, orientation, tile_size.x)

		for key in neighbors.keys():
			var off = neighbors[key].offset
			var bit = neighbors[key].bit

			var np := []
			for v in local:
				np.append(origin + off + _basis * v)

			var nt := [
				[np[0], np[1], np[2]],
				[np[1], np[3], np[2]],
			]

			for tri in nt:
				var ti := find_triangle_by_vertices(tri)
				if ti == -1:
					continue

				var i0 := indices[ti]
				var i1 := indices[ti + 1]
				var i2 := indices[ti + 2]

				var coords := get_tile_coords_from_triangle_uvs(
					uvs[i0], uvs[i1], uvs[i2],
					tile_size,
					atlas_size
				)

				if _tile_matches_terrain(atlas_src, coords, terrain_set, terrain_id):
					if triangle_faces_normal(
						positions[i0],
						positions[i1],
						positions[i2],
						normal
					):
						bitmask |= bit

	var uv_rect := Rect2()

	if has_terrain:
		uv_rect = resolve_terrain_uv_for_bitmask(terrain_id, bitmask)


	if uv_rect == Rect2():
		uv_rect = Rect2(fallback_tile_coord * tile_size, tile_size)

	var uv_min := uv_rect.position / atlas_size
	var uv_max := (uv_rect.position + uv_rect.size) / atlas_size

	var quad_uvs := generate_quad_uvs(
		origin,
		_basis,
		uv_rect,
		atlas_size,
		tile_size
	)

	var tri_uvs := [
		[quad_uvs[0], quad_uvs[1], quad_uvs[2]],
		[quad_uvs[1], quad_uvs[3], quad_uvs[2]],
	]

	for i in range(0, indices.size() - 2, 3):
		var ex := [
			positions[indices[i]],
			positions[indices[i + 1]],
			positions[indices[i + 2]],
		]

		if find_triangle_by_vertices(tris[0]) == i:
			uvs[indices[i]]     = tri_uvs[0][0]
			uvs[indices[i + 1]] = tri_uvs[0][1]
			uvs[indices[i + 2]] = tri_uvs[0][2]
		elif find_triangle_by_vertices(tris[1]) == i:
			uvs[indices[i]]     = tri_uvs[1][0]
			uvs[indices[i + 1]] = tri_uvs[1][1]
			uvs[indices[i + 2]] = tri_uvs[1][2]
		else:
			continue

		if has_terrain:
			refresh_neighbor_uvs(origin, normal, _basis, tile_size, atlas_size, atlas_src, terrain_set, orientation)
			update_quad_uvs_at(origin, normal, _basis, tile_size, atlas_size, atlas_src, terrain_set, orientation)
		return

	var base := positions.size()

	for v in p:
		positions.append(v)
		normals.append(_basis * Vector3.UP)
		colors.append(Color.WHITE)

	uvs.append_array(quad_uvs)

	indices.append_array([
		base + 0, base + 1, base + 2,
		base + 1, base + 3, base + 2
	])

	uvs[base + 0] = quad_uvs[0]
	uvs[base + 1] = quad_uvs[1]
	uvs[base + 2] = quad_uvs[2]
	uvs[base + 3] = quad_uvs[3]
	invalidate_triangle_lookup()
	if has_terrain:
		refresh_neighbor_uvs(origin, normal, _basis, tile_size, atlas_size, atlas_src, terrain_set, orientation)
		update_quad_uvs_at(origin, normal, _basis, tile_size, atlas_size, atlas_src, terrain_set, orientation)

	var quad_verts := PackedInt32Array([
		base + 0,
		base + 1,
		base + 2,
		base + 3,
	])

	var quad_key := quad_verts.duplicate()
	quad_key.sort()

	var face_id: int

	if quad_face_id_by_key.has(quad_key):
		face_id = quad_face_id_by_key[quad_key]
	else:
		face_id = _alloc_face_id()
		quad_face_id_by_key[quad_key] = face_id
	face_source_by_id[face_id] = source_id

	return

func place_custom_quad_undoable(
	brush:TileModeller,
	world_points: PackedVector3Array,
	normal: Vector3,
	_basis: Basis,
	source_id:int,
	fallback_tile_coord: Vector2,
	tile_size: Vector2,
	tileset: TileSet,
	brush_tile_corners:Array,
	brush_orientation:int,
) -> void:
	
	var undo_redo := EditorInterface.get_editor_undo_redo()

	if not _quad_painting:
		begin_quad_paint()

	undo_redo.create_action(
		"Paint Custom Quad",
		UndoRedo.MERGE_ENDS
	)

	undo_redo.add_do_method(
		self,
		"_place_custom_quad_internal",
		brush,
		world_points,
		normal,
		_basis,
		source_id,
		fallback_tile_coord,
		tile_size,
		tileset,
		brush_tile_corners,
		brush_orientation
	)

	undo_redo.add_undo_method(
		self,
		"_set_mesh_state",
		_quad_paint_before_state
	)

	undo_redo.commit_action()

func quad_extent_along_axis(points: PackedVector3Array, axis: Vector3) -> float:
	var min_d := INF
	var max_d := -INF
	for p in points:
		var d := p.dot(axis)
		min_d = min(min_d, d)
		max_d = max(max_d, d)
	return max_d - min_d
	
func _place_custom_quad_internal(
	brush:TileModeller,
	world_points: PackedVector3Array,
	normal: Vector3,
	_basis: Basis,
	source_id: int,
	fallback_tile_coord: Vector2,
	tile_size: Vector2,
	tileset: TileSet,
	tile_corners: Array,
	brush_orientation: int,
) -> void:

	if not tileset.has_source(source_id):
		return

	var atlas_src := tileset.get_source(source_id) as TileSetAtlasSource
	if atlas_src == null or atlas_src.texture == null:
		return

	var p := [
		world_points[0],
		world_points[1],
		world_points[3],
		world_points[2],
	]

	var pivot: Vector3
	if brush.select_mode == TileModeller.TileSelectMode.TILES:
		pivot = Vector3.ZERO
		for v in p:
			pivot += v
		pivot /= p.size()
	else:
		pivot = p[0]

	var current_size = p[0].distance_to(p[1])
	if current_size < 1e-8:
		return

	var target_size = brush.brush_form.get_quad_size(tile_size.x * current_size)
	var scale = target_size / current_size

	for i in range(p.size()):
		var v = p[i] - pivot
		v *= scale
		p[i] = pivot + v

	var atlas_size := Vector2(atlas_src.texture.get_size())

	var quad_uvs_raw := generate_custom_quad_uvs(
		fallback_tile_coord,
		tile_corners,
		tile_size,
		atlas_size
	)

	var quad_uvs := [
		quad_uvs_raw[0],
		quad_uvs_raw[1],
		quad_uvs_raw[3],
		quad_uvs_raw[2],
	]

	var base := positions.size()

	for v in p:
		positions.append(v)
		normals.append(normal)
		colors.append(Color.WHITE)

	uvs.append_array(quad_uvs)

	indices.append_array([
		base + 0, base + 1, base + 2,
		base + 1, base + 3, base + 2
	])

	var quad_verts := PackedInt32Array([
		base + 0,
		base + 1,
		base + 2,
		base + 3,
	])

	var quad_key := quad_verts.duplicate()
	quad_key.sort()

	var face_id: int
	if quad_face_id_by_key.has(quad_key):
		face_id = quad_face_id_by_key[quad_key]
	else:
		face_id = _alloc_face_id()
		quad_face_id_by_key[quad_key] = face_id

	face_source_by_id[face_id] = source_id

	invalidate_triangle_lookup()


func reorder_quad_for_your_indices(
	q3: Array,
	q2: Array,
	quv: Array,
	segs_intersect,
	normal_world: Vector3
) -> Dictionary:
	var tri_quality = func(a: Vector2, b: Vector2, c: Vector2) -> float:
		var ab := b - a
		var bc := c - b
		var ca := a - c

		var lab2 := ab.length_squared()
		var lbc2 := bc.length_squared()
		var lca2 := ca.length_squared()

		var maxl2 := max(lab2, max(lbc2, lca2))
		if maxl2 < 1e-12:
			return 0.0

		var area2 := abs(ab.cross(c - a))
		return (area2 * area2) / maxl2

	var build_candidate = func(loop_idx: Array, use_diag_02: bool) -> Array:
		var v0 = loop_idx[0]
		var v1 = loop_idx[1]
		var v2 = loop_idx[2]
		var v3 = loop_idx[3]
		if use_diag_02:
			return [v1, v0, v2, v3]
		else:
			return [v0, v1, v3, v2]

	var best_score := -INF
	var best_perm := PackedInt32Array()

	var base_loop := [0, 1, 2, 3]

	for rot in range(4):

		var loop := []
		for k in range(4):
			loop.append(base_loop[(k + rot) % 4])

		for use_diag_02 in [true, false]:
			var perm := build_candidate.call(loop, use_diag_02)
			var p2 := [q2[perm[0]], q2[perm[1]], q2[perm[2]], q2[perm[3]]]

			if segs_intersect.call(p2[0], p2[1], p2[3], p2[2]):
				continue

			var q_t0 := tri_quality.call(p2[0], p2[1], p2[2])
			var q_t1 := tri_quality.call(p2[1], p2[3], p2[2])

			var score := min(q_t0, q_t1)

			var t0n := compute_triangle_normal(q3[perm[0]], q3[perm[1]], q3[perm[2]])
			var t1n := compute_triangle_normal(q3[perm[1]], q3[perm[3]], q3[perm[2]])
			if t0n.dot(normal_world) < 0.0 or t1n.dot(normal_world) < 0.0:
				continue

			if score > best_score:
				best_score = score
				best_perm = PackedInt32Array(perm)

	if best_perm.size() != 4:
		return {"p3": q3, "uv": quv}

	return {
		"p3": [q3[best_perm[0]], q3[best_perm[1]], q3[best_perm[2]], q3[best_perm[3]]],
		"uv": [quv[best_perm[0]], quv[best_perm[1]], quv[best_perm[2]], quv[best_perm[3]]]
	}


func split_quad(
	quad_index: int,
	axis: String,
	offset_world: float,
	normal_world: Vector3,
	right_world: Vector3,
	down_world: Vector3
) -> void:
	var quads := get_quads()
	if quad_index < 0 or quad_index >= quads.size():
		return

	var quad := quads[quad_index]
	if quad.size() != 4:
		return

	var orig_quad_key := make_quad_key(quad)
	var orig_face_id := quad_face_id_by_key.get(orig_quad_key, -1)
	var orig_source_id := -1
	if orig_face_id != -1:
		orig_source_id = face_source_by_id.get(orig_face_id, -1)

	if right_world.cross(down_world).dot(normal_world) < 0.0:
		down_world = -down_world

	var get_d = func(v: Vector2) -> float:
		return v.y if axis == "horizontal" else v.x

	var segs_intersect = func(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
		var orient = func(p: Vector2, q: Vector2, r: Vector2) -> float:
			return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)

		var on_seg = func(p: Vector2, q: Vector2, r: Vector2) -> bool:
			return (
				min(p.x, r.x) - 1e-8 <= q.x and q.x <= max(p.x, r.x) + 1e-8 and
				min(p.y, r.y) - 1e-8 <= q.y and q.y <= max(p.y, r.y) + 1e-8
			)

		var o1 := orient.call(a, b, c)
		var o2 := orient.call(a, b, d)
		var o3 := orient.call(c, d, a)
		var o4 := orient.call(c, d, b)

		if (o1 > 0.0 and o2 < 0.0 or o1 < 0.0 and o2 > 0.0) and (o3 > 0.0 and o4 < 0.0 or o3 < 0.0 and o4 > 0.0):
			return true

		if abs(o1) < 1e-8 and on_seg.call(a, c, b): return true
		if abs(o2) < 1e-8 and on_seg.call(a, d, b): return true
		if abs(o3) < 1e-8 and on_seg.call(c, a, d): return true
		if abs(o4) < 1e-8 and on_seg.call(c, b, d): return true
		return false



	var reorder_tri_to_face_normal = func(t3: Array, tuv: Array) -> Dictionary:
		if compute_triangle_normal(t3[0], t3[1], t3[2]).dot(normal_world) < 0.0:
			return {"p3": [t3[0], t3[2], t3[1]], "uv": [tuv[0], tuv[2], tuv[1]]}
		return {"p3": t3, "uv": tuv}

	var add_quad = func(points: Array, q_uvs: Array) -> void:
		var base := positions.size()

		for i in range(4):
			positions.append(points[i])
			normals.append(normal_world)
			colors.append(Color.WHITE)
			uvs.append(q_uvs[i])

		indices.append_array([
			base + 0, base + 1, base + 2,
			base + 1, base + 3, base + 2
		])

		if orig_face_id != -1:
			var quad_verts := PackedInt32Array([
				base + 0,
				base + 1,
				base + 2,
				base + 3,
			])
			var key := make_quad_key(quad_verts)

			quad_face_id_by_key[key] = orig_face_id
			if orig_source_id != -1:
				face_source_by_id[orig_face_id] = orig_source_id

	var add_tri = func(points: Array, t_uvs: Array) -> void:
		var base := positions.size()
		for i in range(3):
			positions.append(points[i])
			normals.append(normal_world)
			colors.append(Color.WHITE)
			uvs.append(t_uvs[i])
		indices.append_array([base + 0, base + 1, base + 2])

	var p3_raw := []
	var uv_raw := []
	for vi in quad:
		p3_raw.append(positions[vi])
		uv_raw.append(uvs[vi])

	var center3 := Vector3.ZERO
	for v in p3_raw:
		center3 += v
	center3 /= 4.0

	var p2_raw := []
	for v in p3_raw:
		var rel = v - center3
		p2_raw.append(Vector2(rel.dot(right_world), rel.dot(down_world)))

	var center2 := Vector2.ZERO
	for c in p2_raw:
		center2 += c
	center2 /= 4.0

	var order := []
	for i in range(4):
		order.append({"i": i, "a": atan2(p2_raw[i].y - center2.y, p2_raw[i].x - center2.x)})

	var sort_angle = func(a, b): return a.a < b.a
	order.sort_custom(sort_angle)

	var p3 := []
	var p2 := []
	var puv := []
	for e in order:
		p3.append(p3_raw[e.i])
		p2.append(p2_raw[e.i])
		puv.append(uv_raw[e.i])

	if compute_triangle_normal(p3[0], p3[1], p3[2]).dot(normal_world) < 0.0:
		p3.reverse()
		p2.reverse()
		puv.reverse()

	var dmin := INF
	var dmax := -INF
	for v in p2:
		var d := get_d.call(v)
		dmin = min(dmin, d)
		dmax = max(dmax, d)
	if offset_world <= dmin or offset_world >= dmax:
		return

	var polyA_3 := []
	var polyA_2 := []
	var polyA_uv := []

	var polyB_3 := []
	var polyB_2 := []
	var polyB_uv := []

	var push_to = func(is_a: bool, v3: Vector3, v2: Vector2, vuv: Vector2) -> void:
		if is_a:
			polyA_3.append(v3); polyA_2.append(v2); polyA_uv.append(vuv)
		else:
			polyB_3.append(v3); polyB_2.append(v2); polyB_uv.append(vuv)

	for i in range(4):
		var j := (i + 1) % 4

		var a3: Vector3 = p3[i]
		var b3: Vector3 = p3[j]
		var a2: Vector2 = p2[i]
		var b2: Vector2 = p2[j]
		var auv: Vector2 = puv[i]
		var buv: Vector2 = puv[j]

		var da = get_d.call(a2) - offset_world
		var db = get_d.call(b2) - offset_world

		var a_in_A = da <= 0.0
		push_to.call(a_in_A, a3, a2, auv)

		if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
			var denom = (get_d.call(b2) - get_d.call(a2))
			if abs(denom) < 1e-8:
				continue

			var t = (offset_world - get_d.call(a2)) / denom
			t = clamp(t, 0.0, 1.0)

			var i3 := a3.lerp(b3, t)
			var i2 := a2.lerp(b2, t)
			var iuv := auv.lerp(buv, t)

			push_to.call(true,  i3, i2, iuv)
			push_to.call(false, i3, i2, iuv)

	if polyA_3.size() < 3 or polyB_3.size() < 3:
		return

	var emit_poly = func(q3: Array, q2: Array, quv: Array) -> void:
		var n := q3.size()

		if n == 3:
			var t = reorder_tri_to_face_normal.call(q3, quv)
			add_tri.call(t.p3, t.uv)
			return

		if n == 4:
			var q = reorder_quad_for_your_indices(q3, q2, quv, segs_intersect, normal_world)
			add_quad.call(q.p3, q.uv)
			return

		if n == 5:
			var c2 := Vector2.ZERO
			for v in q2: c2 += v
			c2 /= 5.0

			var ord := []
			for i in range(5):
				ord.append({"i": i, "a": atan2(q2[i].y - c2.y, q2[i].x - c2.x)})

			var sort_a = func(a, b): return a.a < b.a
			ord.sort_custom(sort_a)

			var p3o := []
			var p2o := []
			var uvo := []
			for e in ord:
				p3o.append(q3[e.i])
				p2o.append(q2[e.i])
				uvo.append(quv[e.i])

			if compute_triangle_normal(p3o[0], p3o[1], p3o[2]).dot(normal_world) < 0.0:
				p3o.reverse(); p2o.reverse(); uvo.reverse()

			var q3a := [p3o[0], p3o[1], p3o[2], p3o[3]]
			var q2a := [p2o[0], p2o[1], p2o[2], p2o[3]]
			var uva := [uvo[0], uvo[1], uvo[2], uvo[3]]

			var t3b := [p3o[0], p3o[3], p3o[4]]
			var uvb := [uvo[0], uvo[3], uvo[4]]

			var q = reorder_quad_for_your_indices(q3a, q2a, uva,segs_intersect, normal_world)
			add_quad.call(q.p3, q.uv)

			var t = reorder_tri_to_face_normal.call(t3b, uvb)
			add_tri.call(t.p3, t.uv)
			return

		push_warning("split_quad: unsupported polygon size %d" % n)

	delete_quad(quad_index)

	emit_poly.call(polyA_3, polyA_2, polyA_uv)
	emit_poly.call(polyB_3, polyB_2, polyB_uv)

	invalidate_triangle_lookup()
	rebuild_quad_source_by_key()
	notify_property_list_changed()

func flip_quad_diagonal_undoable(quad_index: int) -> void:
	var undo_redo := EditorInterface.get_editor_undo_redo()
	var before_state = _get_mesh_state()

	undo_redo.create_action("Flip Quad Diagonal", UndoRedo.MERGE_ENDS)

	undo_redo.add_do_method(self, "flip_quad_diagonal", quad_index)
	undo_redo.add_undo_method(self, "_set_mesh_state", before_state)

	undo_redo.commit_action()
func flip_quad_diagonal(quad_index: int) -> void:
	var quads := get_quads()
	if quad_index < 0 or quad_index >= quads.size():
		return

	var quad := quads[quad_index]
	if quad.size() != 4:
		return

	var orig_key := make_quad_key(quad)
	var face_id := quad_face_id_by_key.get(orig_key, -1)
	var source_id := face_source_by_id.get(face_id, -1)

	var qpos: Array = []
	var quv: Array = []
	var qn := normals[quad[0]]

	for vi in quad:
		qpos.append(positions[vi])
		quv.append(uvs[vi])

	var qset := {}
	for vi in quad:
		qset[vi] = true

	var tri_a := PackedInt32Array()
	var tri_b := PackedInt32Array()

	for t in range(0, indices.size(), 3):
		var a := indices[t]
		var b := indices[t + 1]
		var c := indices[t + 2]

		if qset.has(a) and qset.has(b) and qset.has(c):
			if tri_a.is_empty():
				tri_a = PackedInt32Array([a, b, c])
			elif tri_b.is_empty():
				tri_b = PackedInt32Array([a, b, c])
				break

	if tri_a.is_empty() or tri_b.is_empty():
		return

	var shared := []
	for x in tri_a:
		for y in tri_b:
			if x == y:
				shared.append(x)

	if shared.size() != 2:
		return

	var diag0 = shared[0]
	var diag1 = shared[1]

	var other := []
	for vi in quad:
		if vi != diag0 and vi != diag1:
			other.append(vi)

	if other.size() != 2:
		return

	var od0 = other[0]
	var od1 = other[1]

	var reorder_tri = func(i0: int, i1: int, i2: int) -> PackedInt32Array:
		var n := compute_triangle_normal(
			positions[i0],
			positions[i1],
			positions[i2]
		)
		if n.dot(qn) < 0.0:
			return PackedInt32Array([i0, i2, i1])
		return PackedInt32Array([i0, i1, i2])

	delete_quad(quad_index)

	var base := positions.size()
	for i in range(4):
		positions.append(qpos[i])
		normals.append(qn)
		colors.append(Color.WHITE)
		uvs.append(quv[i])

	var map := {}
	for i in range(4):
		map[quad[i]] = base + i

	var t1 := reorder_tri.call(map[od0], map[diag0], map[od1])
	var t2 := reorder_tri.call(map[od0], map[od1], map[diag1])

	indices.append_array([
		t1[0], t1[1], t1[2],
		t2[0], t2[1], t2[2]
	])

	if face_id != -1:
		var new_quad := PackedInt32Array([
			base + 0,
			base + 1,
			base + 2,
			base + 3
		])
		var new_key := make_quad_key(new_quad)
		quad_face_id_by_key[new_key] = face_id
		if source_id != -1:
			face_source_by_id[face_id] = source_id

	invalidate_triangle_lookup()
	rebuild_quad_source_by_key()
	notify_property_list_changed()



func split_quad_along_texel_undoable(
	quad_index: int,
	axis: String,
	texel_coord: float,
	normal_world: Vector3,
	right_world: Vector3,
	down_world: Vector3
) -> void:
	var undo_redo := EditorInterface.get_editor_undo_redo()

	var before_state = _get_mesh_state()

	undo_redo.create_action(
		"Split Quad",
		UndoRedo.MERGE_ENDS
	)

	undo_redo.add_do_method(
		self,
		"split_quad_along_texel",
		quad_index,
		axis,
		texel_coord,
		normal_world,
		right_world,
		down_world
	)

	undo_redo.add_undo_method(
		self,
		"_set_mesh_state",
		before_state
	)

	undo_redo.commit_action()


func split_quad_along_texel(
	quad_index: int,
	axis: String,         
	texel_coord: float,   
	normal_world: Vector3,
	right_world: Vector3,
	down_world: Vector3
) -> void:
	var quads := get_quads()
	if quad_index < 0 or quad_index >= quads.size():
		return

	var quad := quads[quad_index]
	if quad.size() != 4:
		return
	var orig_quad_key := make_quad_key(quad)
	var orig_face_id := quad_face_id_by_key.get(orig_quad_key, -1)
	var orig_source_id := -1
	if orig_face_id != -1:
		orig_source_id = face_source_by_id.get(orig_face_id, -1)

	if right_world.cross(down_world).dot(normal_world) < 0.0:
		down_world = -down_world

	var get_d_uv = func(uv: Vector2) -> float:
		return uv.y if axis == "horizontal" else uv.x

	var segs_intersect = func(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
		var orient = func(p: Vector2, q: Vector2, r: Vector2) -> float:
			return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)

		var on_seg = func(p: Vector2, q: Vector2, r: Vector2) -> bool:
			return (
				min(p.x, r.x) - 1e-8 <= q.x and q.x <= max(p.x, r.x) + 1e-8 and
				min(p.y, r.y) - 1e-8 <= q.y and q.y <= max(p.y, r.y) + 1e-8
			)

		var o1 := orient.call(a, b, c)
		var o2 := orient.call(a, b, d)
		var o3 := orient.call(c, d, a)
		var o4 := orient.call(c, d, b)

		if ((o1 > 0.0 and o2 < 0.0) or (o1 < 0.0 and o2 > 0.0)) and ((o3 > 0.0 and o4 < 0.0) or (o3 < 0.0 and o4 > 0.0)):
			return true

		if abs(o1) < 1e-8 and on_seg.call(a, c, b): return true
		if abs(o2) < 1e-8 and on_seg.call(a, d, b): return true
		if abs(o3) < 1e-8 and on_seg.call(c, a, d): return true
		if abs(o4) < 1e-8 and on_seg.call(c, b, d): return true
		return false

	var reorder_tri_to_face_normal = func(t3: Array, tuv: Array) -> Dictionary:
		if compute_triangle_normal(t3[0], t3[1], t3[2]).dot(normal_world) < 0.0:
			return {"p3": [t3[0], t3[2], t3[1]], "uv": [tuv[0], tuv[2], tuv[1]]}
		return {"p3": t3, "uv": tuv}

	var add_quad = func(points: Array, q_uvs: Array) -> void:
		var base := positions.size()

		for i in range(4):
			positions.append(points[i])
			normals.append(normal_world)
			colors.append(Color.WHITE)
			uvs.append(q_uvs[i])

		indices.append_array([
			base + 0, base + 1, base + 2,
			base + 1, base + 3, base + 2
		])

		if orig_face_id != -1:
			var quad_verts := PackedInt32Array([
				base + 0,
				base + 1,
				base + 2,
				base + 3,
			])
			var key := make_quad_key(quad_verts)

			quad_face_id_by_key[key] = orig_face_id
			if orig_source_id != -1:
				face_source_by_id[orig_face_id] = orig_source_id

	var add_tri = func(points: Array, t_uvs: Array) -> void:
		var base := positions.size()
		for i in range(3):
			positions.append(points[i])
			normals.append(normal_world)
			colors.append(Color.WHITE)
			uvs.append(t_uvs[i])
		indices.append_array([base + 0, base + 1, base + 2])
	var p3_raw := []
	var uv_raw := []
	for vi in quad:
		p3_raw.append(positions[vi])
		uv_raw.append(uvs[vi])

	var uv_center := Vector2.ZERO
	for uv in uv_raw:
		uv_center += uv
	uv_center /= 4.0

	var order := []
	for i in range(4):
		order.append({"i": i, "a": atan2(uv_raw[i].y - uv_center.y, uv_raw[i].x - uv_center.x)})

	var sort_angle = func(a, b): return a.a < b.a
	order.sort_custom(sort_angle)

	var p3 := []
	var puv := []
	for e in order:
		p3.append(p3_raw[e.i])
		puv.append(uv_raw[e.i])

	if compute_triangle_normal(p3[0], p3[1], p3[2]).dot(normal_world) < 0.0:
		p3.reverse()
		puv.reverse()

	var center3 := Vector3.ZERO
	for v in p3:
		center3 += v
	center3 /= 4.0

	var p2 := []
	for v in p3:
		var rel = v - center3
		p2.append(Vector2(rel.dot(right_world), rel.dot(down_world)))

	var dmin := INF
	var dmax := -INF

	for uv in uv_raw:
		var d := get_d_uv.call(uv)
		dmin = min(dmin, d)
		dmax = max(dmax, d)

	var eps := 1e-6
	if texel_coord <= dmin + eps or texel_coord >= dmax - eps:
		print("test (texel outside quad span)", texel_coord, dmin, dmax)
		return

	var polyA_3 := []
	var polyA_2 := []
	var polyA_uv := []

	var polyB_3 := []
	var polyB_2 := []
	var polyB_uv := []

	var push_to = func(is_a: bool, v3: Vector3, v2: Vector2, uv: Vector2) -> void:
		if is_a:
			polyA_3.append(v3); polyA_2.append(v2); polyA_uv.append(uv)
		else:
			polyB_3.append(v3); polyB_2.append(v2); polyB_uv.append(uv)

	for i in range(4):
		var j := (i + 1) % 4

		var a3 = p3[i]
		var b3 = p3[j]
		var a2 = p2[i]
		var b2 = p2[j]
		var auv = puv[i]
		var buv = puv[j]

		var da = get_d_uv.call(auv) - texel_coord
		var db = get_d_uv.call(buv) - texel_coord

		var a_in_A = da <= 0.0
		push_to.call(a_in_A, a3, a2, auv)

		if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
			var denom = get_d_uv.call(buv) - get_d_uv.call(auv)
			if abs(denom) < 1e-8:
				continue

			var t = (texel_coord - get_d_uv.call(auv)) / denom
			t = clamp(t, 0.0, 1.0)

			var iuv = auv.lerp(buv, t)
			var i3 = a3.lerp(b3, t)
			var i2 = a2.lerp(b2, t)

			push_to.call(true,  i3, i2, iuv)
			push_to.call(false, i3, i2, iuv)

	if polyA_3.size() < 3 or polyB_3.size() < 3:

		return

	var emit_poly = func(q3: Array, q2: Array, quv: Array) -> void:
		var n := q3.size()

		if n == 3:
			var t = reorder_tri_to_face_normal.call(q3, quv)
			add_tri.call(t.p3, t.uv)
			return

		if n == 4:
			var q = reorder_quad_for_your_indices(q3, q2, quv, segs_intersect, normal_world)
			add_quad.call(q.p3, q.uv)
			return

		if n == 5:
			var c2 := Vector2.ZERO
			for v in q2:
				c2 += v
			c2 /= 5.0

			var ord := []
			for k in range(5):
				ord.append({"i": k, "a": atan2(q2[k].y - c2.y, q2[k].x - c2.x)})

			var sort_a = func(a, b): return a.a < b.a
			ord.sort_custom(sort_a)

			var p3o := []
			var p2o := []
			var uvo := []
			for e in ord:
				p3o.append(q3[e.i])
				p2o.append(q2[e.i])
				uvo.append(quv[e.i])

			if compute_triangle_normal(p3o[0], p3o[1], p3o[2]).dot(normal_world) < 0.0:
				p3o.reverse(); p2o.reverse(); uvo.reverse()

			var q3a := [p3o[0], p3o[1], p3o[2], p3o[3]]
			var q2a := [p2o[0], p2o[1], p2o[2], p2o[3]]
			var uva := [uvo[0], uvo[1], uvo[2], uvo[3]]

			var t3b := [p3o[0], p3o[3], p3o[4]]
			var uvb := [uvo[0], uvo[3], uvo[4]]

			var q = reorder_quad_for_your_indices(q3a, q2a, uva, segs_intersect, normal_world)
			add_quad.call(q.p3, q.uv)

			var t = reorder_tri_to_face_normal.call(t3b, uvb)
			add_tri.call(t.p3, t.uv)
			return

		push_warning("split_quad_along_texel: unsupported polygon size %d" % n)
	delete_quad(quad_index)

	emit_poly.call(polyA_3, polyA_2, polyA_uv)
	emit_poly.call(polyB_3, polyB_2, polyB_uv)

	invalidate_triangle_lookup()
	rebuild_quad_source_by_key()
	notify_property_list_changed()


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



func refresh_neighbor_uvs(
	origin: Vector3,
	normal: Vector3,
	_basis: Basis,
	tile_size: Vector2,
	atlas_size: Vector2,
	atlas_src: TileSetAtlasSource,
	terrain_set: int,
	orientation: int
) -> void:
	var neighbors := compute_neighbor_peering_offsets(normal, orientation, tile_size.x)

	var to_update := []

	for key in CARDINAL_KEYS:
		to_update.append(origin + neighbors[key].offset)

	for pos in to_update:
		update_quad_uvs_at(
			pos,
			normal,
			_basis,
			tile_size,
			atlas_size,
			atlas_src,
			terrain_set,
			orientation
		)

func _tri_corner_of_pos(pos: Vector3, tri: Array, eps := 0.0001) -> int:
	for k in range(3):
		if pos.distance_to(tri[k]) <= eps:
			return k
	return -1

func update_quad_uvs_at(
	origin: Vector3,
	normal: Vector3,
	_basis: Basis,
	tile_size: Vector2,
	atlas_size: Vector2,
	atlas_src: TileSetAtlasSource,
	terrain_set: int,
	orientation: int
) -> void:
	
	var QUAD_LOCAL := [
		Vector3(0, 0, 0),
		Vector3(get_quad_size(tile_size.x), 0, 0),
		Vector3(0, 0, get_quad_size(tile_size.x)),
		Vector3(get_quad_size(tile_size.x), 0, get_quad_size(tile_size.x)),
	]
	var local := QUAD_LOCAL

	var p := []
	for v in local:
		p.append(origin + _basis * v)

	var tris := [
		[p[0], p[1], p[2]],
		[p[1], p[3], p[2]],
	]

	var tri_index := -1
	for tri in tris:
		tri_index = find_triangle_by_vertices(tri)
		if tri_index != -1:
			break

	if tri_index == -1:
		return

	var i0 := indices[tri_index]
	var i1 := indices[tri_index + 1]
	var i2 := indices[tri_index + 2]

	var tile_coords := get_tile_coords_from_triangle_uvs(
		uvs[i0], uvs[i1], uvs[i2],
		tile_size,
		atlas_size
	)

	var terrain_id := terrain_id_from_fallback_tile(
		atlas_src,
		terrain_set,
		tile_coords
	)

	if terrain_id < 0:
		return

	var neighbors := compute_neighbor_peering_offsets(normal, orientation, tile_size.x)
	var bitmask := 0

	var present := {}

	for key in CARDINAL_KEYS:
		present[key] = false

		var off = neighbors[key].offset
		var bit = neighbors[key].bit

		if neighbor_has_matching_terrain(origin, off, normal, _basis, tile_size, atlas_size, atlas_src, terrain_set, terrain_id):
			bitmask |= bit
			present[key] = true

	var terrain := _terrain_uv_lookup.get(terrain_id)
	if terrain == null or terrain.is_empty():
		return

	var uv_rect := resolve_terrain_uv_for_bitmask(terrain_id, bitmask)
	if uv_rect == Rect2():
		return


	var uv_min := uv_rect.position / atlas_size
	var uv_max := (uv_rect.position + uv_rect.size) / atlas_size

	var quad_uvs := generate_quad_uvs(
		origin,
		_basis,
		uv_rect,
		atlas_size,
		tile_size
	)



	var tri_uvs := [
		[quad_uvs[0], quad_uvs[1], quad_uvs[2]],
		[quad_uvs[1], quad_uvs[3], quad_uvs[2]],
	]

	var eps := 0.1

	for i in range(0, indices.size() - 2, 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]

		var ex := [positions[a], positions[b], positions[c]]

		var t_match := -1
		if find_triangle_by_vertices(tris[0]) == i:
			t_match = 0
		elif find_triangle_by_vertices(tris[1]) == i:
			t_match = 1
		else:
			continue

		var ca := _tri_corner_of_pos(positions[a], tris[t_match], eps)
		var cb := _tri_corner_of_pos(positions[b], tris[t_match], eps)
		var cc := _tri_corner_of_pos(positions[c], tris[t_match], eps)

		if ca == -1 or cb == -1 or cc == -1:
			continue

		uvs[a] = tri_uvs[t_match][ca]
		uvs[b] = tri_uvs[t_match][cb]
		uvs[c] = tri_uvs[t_match][cc]
	invalidate_triangle_lookup()

func delete_vertex(vertex_index: int) -> void:
	var affected_quad_keys := []
	for quad in get_quads():
		if vertex_index in quad:
			var k := quad.duplicate()
			k.sort()
			affected_quad_keys.append(k)

	var target_key := _pos_key(positions[vertex_index])
	var deleted_vertices := []

	for i in range(positions.size()):
		if _pos_key(positions[i]) == target_key:
			deleted_vertices.append(i)

	var tris_to_remove := []
	var new_tris := []

	for t in range(0, indices.size(), 3):
		var a := indices[t]
		var b := indices[t + 1]
		var c := indices[t + 2]

		if deleted_vertices.has(a) or deleted_vertices.has(b) or deleted_vertices.has(c):
			tris_to_remove.append(t)
	var processed := {}
	for t in tris_to_remove:
		if processed.has(t):
			continue

		var tri_a := indices.slice(t, t + 3)
		var paired := -1

		for t2 in tris_to_remove:
			if t2 == t:
				continue
			var tri_b := indices.slice(t2, t2 + 3)

			var shared := 0
			for v in tri_a:
				if v in tri_b:
					shared += 1

			if shared == 2:
				paired = t2
				break

		processed[t] = true
		if paired != -1:
			processed[paired] = true

		var remaining := []
		for v in tri_a:
			if not deleted_vertices.has(v) and not remaining.has(v):
				remaining.append(v)

		if paired != -1:
			for v in indices.slice(paired, paired + 3):
				if not deleted_vertices.has(v) and not remaining.has(v):
					remaining.append(v)

		if remaining.size() == 3:
			var ra := positions[tri_a[0]]
			var rb := positions[tri_a[1]]
			var rc := positions[tri_a[2]]
			var ref_normal := compute_triangle_normal(ra, rb, rc)

			var ia = remaining[0]
			var ib = remaining[1]
			var ic = remaining[2]

			var na := positions[ia]
			var nb := positions[ib]
			var nc := positions[ic]
			var test_normal := compute_triangle_normal(na, nb, nc)

			if test_normal.dot(ref_normal) < 0.0:
				var tmp = ib
				ib = ic
				ic = tmp

			new_tris.append_array([ia, ib, ic])

	tris_to_remove.sort()
	for i in range(tris_to_remove.size() - 1, -1, -1):
		var t = tris_to_remove[i]
		indices.remove_at(t)
		indices.remove_at(t)
		indices.remove_at(t)

	deleted_vertices.sort()
	for i in range(deleted_vertices.size() - 1, -1, -1):
		var v = deleted_vertices[i]
		positions.remove_at(v)
		normals.remove_at(v)
		uvs.remove_at(v)
		colors.remove_at(v)

	for i in range(indices.size()):
		var shift := 0
		for v in deleted_vertices:
			if indices[i] > v:
				shift += 1
		indices[i] -= shift

	for i in range(new_tris.size()):
		var shift := 0
		for v in deleted_vertices:
			if new_tris[i] > v:
				shift += 1
		new_tris[i] -= shift

	indices.append_array(new_tris)
	invalidate_triangle_lookup()
	rebuild_quad_source_by_key()
	notify_property_list_changed()

func remove_collapsed_triangles() -> void:
	var tris_to_remove := []
	var used_vertices := {}

	for t in range(0, indices.size(), 3):
		var ia := indices[t]
		var ib := indices[t + 1]
		var ic := indices[t + 2]

		var a := positions[ia]
		var b := positions[ib]
		var c := positions[ic]

		if is_triangle_degenerate(a, b, c):
			tris_to_remove.append(t)
		else:
			used_vertices[ia] = true
			used_vertices[ib] = true
			used_vertices[ic] = true

	for i in range(tris_to_remove.size() - 1, -1, -1):
		var t = tris_to_remove[i]
		indices.remove_at(t)
		indices.remove_at(t)
		indices.remove_at(t)

	var removed := []

	for i in range(positions.size() - 1, -1, -1):
		if not used_vertices.has(i):
			positions.remove_at(i)
			normals.remove_at(i)
			uvs.remove_at(i)
			colors.remove_at(i)
			removed.append(i)

	removed.sort()
	for i in range(indices.size()):
		var shift := 0
		for r in removed:
			if indices[i] > r:
				shift += 1
		indices[i] -= shift
	invalidate_triangle_lookup()
	rebuild_quad_source_by_key()


var _tri_lookup := {}
var _tri_lookup_dirty := true
var _terrain_lookup_built_for := {
	"tileset": null,
	"source_id": -1,
	"terrain_set": -1,
}

func invalidate_terrain():
	_terrain_lookup_built_for = {
		"tileset": null,
		"source_id": -1,
		"terrain_set": -1,
	}

func ensure_terrain_peering_uv_map(
	tileset: TileSet,
	source_id: int,
	terrain_set: int
) -> void:
	if (
		_terrain_lookup_built_for.tileset == tileset
		and _terrain_lookup_built_for.source_id == source_id
		and _terrain_lookup_built_for.terrain_set == terrain_set
	):
		return

	build_terrain_peering_uv_map(tileset, source_id, terrain_set)

	_terrain_lookup_built_for.tileset = tileset
	_terrain_lookup_built_for.source_id = source_id
	_terrain_lookup_built_for.terrain_set = terrain_set

func _pkey(p: Vector3) -> Vector3i:
	return _pos_key(p, 1.0)

func _tri_key(a: Vector3, b: Vector3, c: Vector3) -> String:
	var ka := _pkey(a)
	var kb := _pkey(b)
	var kc := _pkey(c)
	var arr := [ka, kb, kc]
	arr.sort()
	return "%s|%s|%s" % [arr[0], arr[1], arr[2]]

func rebuild_triangle_lookup() -> void:
	_tri_lookup.clear()
	for i in range(0, indices.size(), 3):
		var ia := indices[i]
		var ib := indices[i + 1]
		var ic := indices[i + 2]
		var key := _tri_key(positions[ia], positions[ib], positions[ic])
		_tri_lookup[key] = i
	_tri_lookup_dirty = false

func invalidate_triangle_lookup() -> void:
	_tri_lookup_dirty = true

func find_triangle_by_vertices(target: Array) -> int:
	if _tri_lookup_dirty:
		rebuild_triangle_lookup()
	return _tri_lookup.get(_tri_key(target[0], target[1], target[2]), -1)

func _get_mesh_state() -> Dictionary:
	return {
		"positions": positions.duplicate(true),
		"normals": normals.duplicate(true),
		"uvs": uvs.duplicate(true),
		"colors": colors.duplicate(true),
		"indices": indices.duplicate(true),
		"face_source": face_source_by_id.duplicate(true),
		"quad_face": quad_face_id_by_key.duplicate(true)
	}


func _set_mesh_state(state: Dictionary) -> void:
	positions = state.positions.duplicate(true)
	normals   = state.normals.duplicate(true)
	uvs       = state.uvs.duplicate(true)
	colors    = state.colors.duplicate(true)
	indices   = state.indices.duplicate(true)
	face_source_by_id = state.face_source.duplicate(true)
	quad_face_id_by_key = state.quad_face.duplicate(true)
	
	invalidate_triangle_lookup()
	notify_property_list_changed()

func begin_quad_paint():
	if _quad_painting:
		return

	_quad_painting = true
	_quad_paint_before_state = _get_mesh_state()

func end_quad_paint():
	if not _quad_painting:
		return

	_quad_painting = false
	_quad_paint_before_state = {}

var _quad_painting := false
var _quad_paint_before_state := {}

func make_quad_key(quad_verts: PackedInt32Array) -> PackedInt32Array:
	var key := quad_verts.duplicate()
	key.sort()
	return key

func get_quad_verts() -> Array[PackedInt32Array]:
	var result: Array[PackedInt32Array] = []
	var used_tris := {}

	for i in range(0, indices.size(), 3):
		if used_tris.has(i):
			continue

		var tri_a := [
			indices[i],
			indices[i + 1],
			indices[i + 2],
		]

		var paired := -1

		for j in range(i + 3, indices.size(), 3):
			if used_tris.has(j):
				continue

			var tri_b := [
				indices[j],
				indices[j + 1],
				indices[j + 2],
			]

			var shared := 0
			for v in tri_a:
				if v in tri_b:
					shared += 1
			if shared == 2:
				paired = j
				break

		if paired == -1:
			continue

		used_tris[i] = true
		used_tris[paired] = true

		var verts := []
		for v in tri_a:
			if not verts.has(v):
				verts.append(v)
		for v in indices.slice(paired, paired + 3):
			if not verts.has(v):
				verts.append(v)

		if verts.size() != 4:
			continue

		result.append(PackedInt32Array(verts))

	return result


func get_quads() -> Array[PackedInt32Array]:
	var faces: Array[PackedInt32Array] = []
	var used := {}

	for i in range(0, indices.size(), 3):
		if used.has(i):
			continue

		var tri_a := [
			indices[i],
			indices[i + 1],
			indices[i + 2],
		]

		var paired := -1

		for j in range(i + 3, indices.size(), 3):
			if used.has(j):
				continue

			var tri_b := [
				indices[j],
				indices[j + 1],
				indices[j + 2],
			]

			var shared := []
			for v in tri_a:
				if v in tri_b:
					shared.append(v)

			if shared.size() == 2:
				paired = j
				break

		if paired != -1:
			used[i] = true
			used[paired] = true

			var verts := []
			for v in tri_a:
				if not verts.has(v):
					verts.append(v)
			for v in indices.slice(paired, paired + 3):
				if not verts.has(v):
					verts.append(v)

			if verts.size() == 4:
				faces.append(PackedInt32Array(verts))
			else:
				faces.append(PackedInt32Array(tri_a))
				used[i] = true
		else:
			used[i] = true
			faces.append(PackedInt32Array(tri_a))

	return faces


func delete_quad(quad_index: int) -> void:
	var quads := get_quads()
	if quad_index < 0 or quad_index >= quads.size():
		return

	var quad := quads[quad_index]
	var tris_to_remove := []

	for t in range(0, indices.size(), 3):
		var a := indices[t]
		var b := indices[t + 1]
		var c := indices[t + 2]

		var count := 0
		for v in quad:
			if v == a or v == b or v == c:
				count += 1

		if count >= 2:
			tris_to_remove.append(t)
	if tris_to_remove.size() < 2:
		return
	tris_to_remove.sort()
	for i in range(tris_to_remove.size() - 1, -1, -1):
		var t = tris_to_remove[i]
		indices.remove_at(t)
		indices.remove_at(t)
		indices.remove_at(t)
	var used := {}
	for i in indices:
		used[i] = true

	var removed := []
	for i in range(positions.size() - 1, -1, -1):
		if not used.has(i):
			positions.remove_at(i)
			normals.remove_at(i)
			uvs.remove_at(i)
			colors.remove_at(i)
			removed.append(i)
	removed.sort()
	for i in range(indices.size()):
		var shift := 0
		for r in removed:
			if indices[i] > r:
				shift += 1
		indices[i] -= shift
	invalidate_triangle_lookup()
	rebuild_quad_source_by_key()
	notify_property_list_changed()

func _quad_key_from_verts(verts: PackedInt32Array) -> PackedInt32Array:
	var k := verts.duplicate()
	k.sort()
	return k

func rebuild_quad_source_by_key() -> void:
	var new_key_to_face := {}

	var old_faces := []
	for old_key in quad_face_id_by_key.keys():
		old_faces.append({
			"key": old_key,
			"face_id": quad_face_id_by_key[old_key],
		})

	var alive_face_ids := {}

	for face in get_quads():
		var key := _quad_key_from_verts(face)

		var face_id := quad_face_id_by_key.get(key, -1)
		if face_id == -1:
			var best_match := -1
			var best_shared := 0

			for entry in old_faces:
				var shared := 0
				for v in key:
					if v in entry.key:
						shared += 1

				if shared > best_shared:
					best_shared = shared
					best_match = entry.face_id

			if best_shared >= min(2, key.size()):
				face_id = best_match

		if face_id == -1:
			face_id = _alloc_face_id()

		new_key_to_face[key] = face_id
		alive_face_ids[face_id] = true

	quad_face_id_by_key = new_key_to_face

	var to_remove := []
	for face_id in face_source_by_id.keys():
		if not alive_face_ids.has(face_id):
			to_remove.append(face_id)

	for face_id in to_remove:
		face_source_by_id.erase(face_id)



func find_quad_at_position(world_pos: Vector3, eps := 0.25) -> int:
	var quads := get_quads()

	for i in range(quads.size()):
		var quad := quads[i]
		var center := Vector3.ZERO
		for v in quad:
			center += positions[v]
		center /= quad.size()

		if center.distance_to(world_pos) <= eps:
			return i

	return -1

func on_quad_center_clicked(world_pos: Vector3, secondary := false) -> void:
	var quad_index := find_quad_at_position(world_pos)
	if quad_index == -1:
		return

	if not secondary:
		active_quad_indices.clear()
		active_vertex_indices.clear()

		active_quad_indices.append(quad_index)
		active_vertex_indices.append_array(get_quads()[quad_index])
	notify_property_list_changed()
