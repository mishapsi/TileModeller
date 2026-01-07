@tool
class_name TileModeller extends Node3D

enum TOOL_MODE {TILE, MOVE_VERTEX, PAINT_VERTEX}

var tool_mode = TOOL_MODE.TILE

var vertex_color:Color = Color.WHITE
@onready var vertex_snap:int = 16 if !brush_form else brush_form.pixels_to_world_unit
var orientation:int = 0
@onready var tile_corners:Array = PackedVector2Array([
	Vector2(0, 0),
	Vector2(tile_size.x, 0), 
	Vector2(tile_size.x, tile_size.y),
	Vector2(0, tile_size.y),
])

@export var brush_form:BrushForm

@export var tileset:TileSet:
	set(value):
		tileset = value
		tileset.changed.connect(func():
			if brush_form:
				brush_form.invalidate_terrain()
			)
@onready var corner_snap = tile_size.x
var tile_coord:Vector2i = Vector2(0,0)
var tile_size:Vector2i :
	get():
		if !tileset:
			return Vector2i.ZERO
		var tileset_source:TileSetAtlasSource = tileset.get_source(active_tileset_source_id)
		return tileset_source.texture_region_size if tileset_source else Vector2i.ZERO

var selected_tiles: Array[Vector2i] = []

var cursor:Marker3D
var _surface_materials: Array[Material] = []

var instance : RID
var base : RID
var body : RID
var shape : RID
const EPS := 0.0001
var active_tileset_source_id: int = 0:
	set(value):
		active_tileset_source_id = value
		tile_corners = PackedVector2Array([
			Vector2(0, 0),
			Vector2(tile_size.x, 0), 
			Vector2(tile_size.x, tile_size.y),
			Vector2(0, tile_size.y),
		])
var tileset_source_materials: Dictionary = {}

func get_material_for_source(source_id: int, tileset: TileSet) -> Material:

	if tileset_source_materials.has(source_id):
		return tileset_source_materials[source_id]

	var src := tileset.get_source(source_id)

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	material.albedo_texture = tileset.get_source(0).texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.vertex_color_is_srgb = true
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	tileset_source_materials[source_id] = material
	return material

enum TileSelectMode {
	TILES,
	CORNERS
}

var select_mode: TileSelectMode = TileSelectMode.TILES:
	set(value):
		select_mode = value
		tile_corners = PackedVector2Array([
			Vector2(0, 0),
			Vector2(tile_size.x, 0), 
			Vector2(tile_size.x, tile_size.y),
			Vector2(0, tile_size.y),
		])
		notify_property_list_changed()
func hash_pos(p: Vector3) -> Vector3i:
	return Vector3i(
		int(p.x / EPS),
		int(p.y / EPS),
		int(p.z / EPS)
	)

func get_tile_stamp_offsets() -> Dictionary:
	if selected_tiles.is_empty():
		return {}
	var min_x := INF
	var min_y := INF

	for t in selected_tiles:
		min_x = min(min_x, t.x)
		min_y = min(min_y, t.y)

	var result := {}

	for t in selected_tiles:
		var offset := Vector2i(t.x - min_x, t.y - min_y)
		result[offset] = t

	return result

func project_uv(p : Vector3, n : Vector3, step : float) -> Vector2:
	var w = n
	
	var uv3d = ((p - w * p.dot(w)) + Vector3.ONE * 0.5) / 1.0
	var uv = Vector2(uv3d.x, uv3d.z)
	
	return uv * step

func get_brush_forms() -> Array[BrushForm]:
	var forms : Array[BrushForm]
	
	forms.append(brush_form)
	return forms

func fix_invalid_indices(indices : Array[int], positions : Array[Vector3]) -> void:
	if indices.size() % 2 == 0 and positions.size() % 3 == 0:
		indices.pop_back()
		indices.pop_back()
		indices.pop_back()
		
		fix_invalid_indices(indices, positions)
	return

func recalculate_normals(
	indices: Array,
	normals: Array,
	positions: Array
) -> void:
	if positions.size() < 3:
		return

	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	var weld_map := {}
	for i in range(positions.size()):
		var key := hash_pos(positions[i])
		if not weld_map.has(key):
			weld_map[key] = []
		weld_map[key].append(i)
	for i in range(0, indices.size(), 3):
		var a = indices[i]
		var b = indices[i + 1]
		var c = indices[i + 2]

		var ab = positions[a] - positions[b]
		var ac = positions[c] - positions[a]

		var face_normal = ab.cross(ac)
		var area = face_normal.length()

		if area < EPS:
			continue

		face_normal = face_normal / area
		var weighted = face_normal * area

		normals[a] += weighted
		normals[b] += weighted
		normals[c] += weighted
	for key in weld_map.keys():
		var sum := Vector3.ZERO
		for idx in weld_map[key]:
			sum += normals[idx]

		sum = sum.normalized()

		for idx in weld_map[key]:
			normals[idx] = sum
func create_mesh_from_forms() -> void:
	RenderingServer.mesh_clear(base)

	var forms := get_brush_forms()
	var surfaces_total := 0

	for form in forms:
		var faces := form.get_quads() # tris + quads
		if faces.is_empty():
			continue

		var batches := {} # source_id -> mesh data

		for face in faces:
			if face.size() < 3:
				continue

			# --- FACE ID RESOLUTION (THIS IS THE IMPORTANT PART) ---
			var face_key := PackedInt32Array(face)
			face_key.sort()

			var face_id := form.quad_face_id_by_key.get(face_key, -1)
			var source_id := form.face_source_by_id.get(face_id, 0)
			# ------------------------------------------------------

			if not batches.has(source_id):
				batches[source_id] = {
					"positions": [],
					"normals": [],
					"uvs": [],
					"colors": [],
					"indices": [],
				}

			var b = batches[source_id]
			var base_index = b.positions.size()

			# Emit vertices
			for v in face:
				b.positions.append(transform * form.positions[v])
				b.normals.append(
					form.normals[v] if v < form.normals.size() else Vector3.UP
				)
				b.uvs.append(
					form.uvs[v] if v < form.uvs.size() else Vector2.ZERO
				)
				b.colors.append(
					form.colors[v] if v < form.colors.size() else Color.WHITE
				)

			# Triangulate
			if face.size() == 3:
				b.indices.append_array([
					base_index + 0,
					base_index + 1,
					base_index + 2,
				])
			elif face.size() == 4:
				b.indices.append_array([
					base_index + 0, base_index + 1, base_index + 2,
					base_index + 1, base_index + 3, base_index + 2,
				])
			else:
				for i in range(1, face.size() - 1):
					b.indices.append_array([
						base_index,
						base_index + i,
						base_index + i + 1,
					])

		# Build surfaces
		for source_id in batches.keys():
			var b = batches[source_id]
			if b.indices.is_empty():
				continue

			if form.recalculated_normals:
				recalculate_normals(
					b.indices,
					b.normals,
					b.positions
				)

			var surface_data := []
			surface_data.resize(ArrayMesh.ARRAY_MAX)

			surface_data[ArrayMesh.ARRAY_VERTEX] = PackedVector3Array(b.positions)
			surface_data[ArrayMesh.ARRAY_NORMAL] = PackedVector3Array(b.normals)
			surface_data[ArrayMesh.ARRAY_TEX_UV] = PackedVector2Array(b.uvs)
			surface_data[ArrayMesh.ARRAY_COLOR]  = PackedColorArray(b.colors)
			surface_data[ArrayMesh.ARRAY_INDEX]  = PackedInt32Array(b.indices)

			RenderingServer.mesh_add_surface_from_arrays(
				base,
				RenderingServer.PRIMITIVE_TRIANGLES,
				surface_data
			)

			var material: StandardMaterial3D
			if tileset_source_materials.has(source_id):
				material = tileset_source_materials[source_id]
			else:
				material = StandardMaterial3D.new()
				material.cull_mode = BaseMaterial3D.CULL_DISABLED
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				material.vertex_color_use_as_albedo = true
				material.vertex_color_is_srgb = true

				var src := tileset.get_source(source_id)
				if src is TileSetAtlasSource and src.texture:
					material.albedo_texture = src.texture

				tileset_source_materials[source_id] = material

			RenderingServer.mesh_surface_set_material(
				base,
				surfaces_total,
				material
			)

			surfaces_total += 1


func _init():
	return

func _ready():
	if !tileset:
		tileset = TileSet.new()

	if !brush_form:
		brush_form = BrushForm.new()
	await get_tree().process_frame

	var child = find_child("Cursor")
	if !child:
		child = Marker3D.new()
		child.name = "Cursor"
		add_child(child)
		child.owner = owner
	cursor = child
	create_mesh_from_forms()

func _process(delta):

	if !brush_form:
		return
	if brush_form.positions.is_empty():
		return
	RenderingServer.instance_set_visible(instance, visible)
	RenderingServer.instance_set_transform(instance, transform)

	if Engine.is_editor_hint():
		create_mesh_from_forms()
	update_gizmos()

func _enter_tree():
	instance = RenderingServer.instance_create()
	base = RenderingServer.mesh_create()
	RenderingServer.instance_set_base(instance, base)
	RenderingServer.instance_set_scenario(instance, get_world_3d().scenario)

func _exit_tree():
	RenderingServer.free_rid(instance)
	RenderingServer.free_rid(base)
