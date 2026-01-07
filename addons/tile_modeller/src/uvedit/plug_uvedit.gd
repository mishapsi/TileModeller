extends EditorInspectorPlugin

static var pressing = false
var center_drag := false
var drag_start_uvs := {}
var drag_start_mouse := Vector2.ZERO

func _can_handle(object: Object) -> bool:
	return object is Brush

func draw_dash_dot_line(
	canvas: CanvasItem,
	from: Vector2,
	to: Vector2,
	color: Color,
	width := 2.0,
	dash_len := 10.0,
	gap_len := 6.0,
	dot_len := 2.0
) -> void:
	var dir := to - from
	var len := dir.length()
	if len <= 0.0:
		return

	dir /= len
	var t := 0.0
	var state := 0 # 0=dash, 1=gap, 2=dot, 3=gap

	while t < len:
		var seg_len := 0.0
		match state:
			0: seg_len = dash_len
			1: seg_len = gap_len
			2: seg_len = dot_len
			3: seg_len = gap_len

		var t2 := min(t + seg_len, len)

		if state == 0 or state == 2:
			canvas.draw_line(
				from + dir * t,
				from + dir * t2,
				color,
				width,
				true
			)

		t = t2
		state = (state + 1) % 4

func build_uv_islands(object: BrushForm) -> Array:
	var adj := {}

	# Build adjacency from triangle indices
	for i in range(0, object.indices.size(), 3):
		var a = object.indices[i]
		var b = object.indices[i + 1]
		var c = object.indices[i + 2]

		for pair in [[a,b], [b,c], [c,a]]:
			if not adj.has(pair[0]):
				adj[pair[0]] = []
			adj[pair[0]].append(pair[1])

			if not adj.has(pair[1]):
				adj[pair[1]] = []
			adj[pair[1]].append(pair[0])

	# Flood fill islands
	var visited := {}
	var islands := []

	for idx in adj.keys():
		if visited.has(idx):
			continue

		var stack := [idx]
		var island := []

		while stack.size() > 0:
			var v = stack.pop_back()
			if visited.has(v):
				continue

			visited[v] = true
			island.append(v)

			for n in adj[v]:
				if not visited.has(n):
					stack.append(n)

		islands.append(island)

	return islands

var island_drag := false
var dragged_island: Array = []
func _parse_begin(object: Object) -> void:
	if not (object is BrushForm):
		return

	var UV_selecteds: Array[int] = []
	# --- UI header ---
	var title := Label.new()
	title.text = "UV Editor"
	add_custom_control(title)
	add_custom_control(HSeparator.new())

	# --- Grid snapping ---
	var grid_size := SpinBox.new()
	grid_size.prefix = "Grid:"
	grid_size.step = 0.01
	grid_size.value = 0.25
	add_custom_control(grid_size)

	if object.uvs.size() <= 2:
		return
	var src = object.tileset.get_source(0)
	var atlas_src: TileSetAtlasSource = src as TileSetAtlasSource
	if atlas_src == null or atlas_src.texture == null:
		push_warning("TileSet source is not a TileSetAtlasSource with a texture.")
		return

	var atlas_size := Vector2(atlas_src.texture.get_size()) # ✅ THIS is the atlas size

	# --- UV viewport ---
	var tex := TextureRect.new()
	tex.texture = atlas_src.texture
	tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
	tex.set_anchor(SIDE_BOTTOM, 1.0)
	tex.set_anchor(SIDE_RIGHT, 1.0)

	# --------------------------------------------------
	# UV ISLAND BUILDING
	# --------------------------------------------------
	var build_uv_islands = func(object: BrushForm) -> Array[int]:
		var adj := {}

		# Build adjacency from triangle indices
		for i in range(0, object.indices.size(), 3):
			var a = object.indices[i]
			var b = object.indices[i + 1]
			var c = object.indices[i + 2]

			for pair in [[a,b], [b,c], [c,a]]:
				if not adj.has(pair[0]):
					adj[pair[0]] = []
				adj[pair[0]].append(pair[1])

				if not adj.has(pair[1]):
					adj[pair[1]] = []
				adj[pair[1]].append(pair[0])

		# Flood fill islands
		var visited := {}
		var islands := []

		for idx in adj.keys():
			if visited.has(idx):
				continue

			var stack := [idx]
			var island := []

			while stack.size() > 0:
				var v = stack.pop_back()
				if visited.has(v):
					continue

				visited[v] = true
				island.append(v)

				for n in adj[v]:
					if not visited.has(n):
						stack.append(n)

			islands.append(island)

		return islands


	# --------------------------------------------------
	# DRAW
	# --------------------------------------------------
	tex.draw.connect(func():
		var active_uvs := get_active_uv_indices(object)
		if active_uvs.is_empty():
			return # draw nothing if no active quads

		var size := tex.size
		var islands := build_uv_islands(object)

		# Triangles
		for i in range(0, object.indices.size(), 3):
			var a = object.indices[i]
			var b = object.indices[i + 1]
			var c = object.indices[i + 2]

			# Only draw triangles fully belonging to active quads
			if not (active_uvs.has(a) and active_uvs.has(b) and active_uvs.has(c)):
				continue

			tex.draw_line(object.uvs[a] * size, object.uvs[b] * size, Color.GREEN_YELLOW, 1, true)
			tex.draw_line(object.uvs[b] * size, object.uvs[c] * size, Color.GREEN_YELLOW, 1, true)
			tex.draw_line(object.uvs[c] * size, object.uvs[a] * size, Color.GREEN_YELLOW, 1, true)

		# UV points
		var seen := {}
		for idx in active_uvs.keys():
			if seen.has(idx):
				continue
			seen[idx] = true
			tex.draw_arc(object.uvs[idx] * size, 5, 0, TAU, 24, Color(1,0.3,0.2), 2, true)

		# Grid
		var step := max(grid_size.value, 0.0001)
		for i in range(int(1.0 / step) + 1):
			var t = i * step * size.x
			draw_dash_dot_line(tex, Vector2(t,0), Vector2(t,size.y), Color(1,1,1,0.15))
			draw_dash_dot_line(tex, Vector2(0,t), Vector2(size.x,t), Color(1,1,1,0.15))

		# Island centers
		for island in islands:
			var valid := false
			for idx in island:
				if active_uvs.has(idx):
					valid = true
					break
			if not valid:
				continue

	)

	# --------------------------------------------------
	# INPUT
	# --------------------------------------------------
	tex.gui_input.connect(func(event):
		var active_uvs := get_active_uv_indices(object)
		if active_uvs.is_empty():
			return

		var size := tex.size
		var islands := build_uv_islands(object)

		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				pressing = true
				UV_selecteds.clear()
				center_drag = false
				island_drag = false

				# Island hit test
				for island in islands:
					var filtered := []
					for idx in island:
						if active_uvs.has(idx):
							filtered.append(idx)

					if filtered.is_empty():
						continue

					var center := Vector2.ZERO
					for idx in filtered:
						center += object.uvs[idx]
					center /= filtered.size()

					if (center * size).distance_to(event.position) < 10:
						center_drag = true
						island_drag = true
						dragged_island = filtered.duplicate()
						drag_start_mouse = event.position
						drag_start_uvs.clear()
						for idx in filtered:
							drag_start_uvs[idx] = object.uvs[idx]
						return


				# Single UV selection
				var best := -1
				var best_d := 12.5
				var seen := {}
				for idx in object.indices:
					if seen.has(idx):
						continue
					seen[idx] = true
					var d = (object.uvs[idx] * size).distance_to(event.position)
					if d < best_d:
						best_d = d
						best = idx
				if best != -1:
					UV_selecteds.append(best)

			else:
				pressing = false
				center_drag = false
				island_drag = false
				dragged_island.clear()

		if event is InputEventMouseMotion and pressing:
			var step := max(grid_size.value, 0.0001)
			if island_drag:
				var delta_uv = (event.position - drag_start_mouse) / size
				delta_uv = (delta_uv / step).round() * step
				for idx in dragged_island:
					object.uvs[idx] = drag_start_uvs[idx] + delta_uv
			elif UV_selecteds.size() == 1:
				var uv = event.position / size
				uv = (uv / step).round() * step
				object.uvs[UV_selecteds[0]] = uv

		tex.queue_redraw()
	)

	add_custom_control(tex)
	add_custom_control(HSeparator.new())

func get_active_uv_indices(object: BrushForm) -> Dictionary:
	var allowed := {}

	if object.active_quad_indices.is_empty():
		return allowed

	var quads := object.get_quads()
	for qi in object.active_quad_indices:
		if qi < 0 or qi >= quads.size():
			continue
		for v in quads[qi]:
			allowed[v] = true

	return allowed
