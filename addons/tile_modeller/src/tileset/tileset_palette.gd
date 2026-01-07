extends EditorInspectorPlugin

var selecting := false
var select_start_tile := Vector2i.ZERO
var select_end_tile := Vector2i.ZERO
var dragging_corner := false
var active_tile := Vector2i.ZERO
var active_corner := -1
var hover_corner := -1
var atlas_zoom := 1.0
const ATLAS_ZOOM_MIN := 0.25
const ATLAS_ZOOM_MAX := 8.0

func build_atlas_view(
	brush: TileModeller,
	source_id: int
) -> Dictionary:

	var src := brush.tileset.get_source(source_id) as TileSetAtlasSource
	if src == null or src.texture == null:
		return {}

	var atlas_size: Vector2i = src.texture.get_size()
	var tile_size: Vector2i = brush.tile_size

	# TextureRect
	var tex := TextureRect.new()
	tex.texture = src.texture
	tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.custom_minimum_size = Vector2(atlas_size) * atlas_zoom

	# Input + draw hookup (same as before)
	tex.gui_input.connect(func(event):
		match brush.select_mode:
			brush.TileSelectMode.TILES:
				_handle_tile_selection(event, brush, tex, atlas_size, tile_size)
			brush.TileSelectMode.CORNERS:
				_handle_corner_edit(event, brush, tex, atlas_size, tile_size)
	)

	tex.draw.connect(func():
		var draw_rect := get_texture_rect(tex)
		var scale := draw_rect.size / Vector2(atlas_size)
		match brush.select_mode:
			brush.TileSelectMode.TILES:
				_draw_tile_selection(tex, brush, draw_rect, Vector2(tile_size), scale)
			brush.TileSelectMode.CORNERS:
				_draw_corner_selection(tex, brush, draw_rect, Vector2(tile_size), scale)
	)

	# Checker background
	var checker := create_checker_background(16)
	checker.custom_minimum_size = Vector2(atlas_size) * atlas_zoom
	checker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	checker.add_child(tex)

	# Scroll container
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(256, 256)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.add_child(checker)

	return {
		"scroll": scroll,
		"tex": tex,
		"checker": checker,
		"atlas_size": atlas_size,
	}



func mouse_to_tile(
	pos: Vector2,
	tex: TextureRect,
	atlas_size: Vector2i,
	tile_size: Vector2i
) -> Vector2i:
	var draw_rect := get_texture_rect(tex)
	var local := pos - draw_rect.position
	var atlas_pos := local / draw_rect.size * Vector2(atlas_size)

	return Vector2i(
		int(atlas_pos.x / tile_size.x),
		int(atlas_pos.y / tile_size.y)
	)

func mouse_to_atlas_pixel(
	pos: Vector2,
	tex: TextureRect,
	atlas_size: Vector2i
) -> Vector2:
	var draw_rect := get_texture_rect(tex)
	var local := pos - draw_rect.position
	return local / draw_rect.size * Vector2(atlas_size)


func _can_handle(object: Object) -> bool:
	return object is TileModeller

func create_checker_background(tile_px := 16) -> Control:
	var bg := Control.new()

	bg.draw.connect(func():
		var rect := bg.size
		var c1 := Color(0.18, 0.18, 0.18)
		var c2 := Color(0.24, 0.24, 0.24)

		var cols := int(ceil(rect.x / tile_px))
		var rows := int(ceil(rect.y / tile_px))

		for y in range(rows):
			for x in range(cols):
				var color := c1 if ((x + y) & 1) == 0 else c2
				bg.draw_rect(
					Rect2(x * tile_px, y * tile_px, tile_px, tile_px),
					color,
					true
				)
	)

	return bg

func _parse_begin(object: Object) -> void:

	var brush := object as TileModeller
	if brush == null or brush.tileset == null:
		return

	# --------------------------------------------------
	# Header
	# --------------------------------------------------
	var title := Label.new()
	title.text = "Tile Picker"
	add_custom_control(title)
	add_custom_control(HSeparator.new())

	# --------------------------------------------------
	# Zoom Controls
	# --------------------------------------------------
	var zoom_row := HBoxContainer.new()
	zoom_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var zoom_label := Label.new()
	zoom_label.text = "Zoom"
	zoom_row.add_child(zoom_label)

	var zoom_slider := HSlider.new()
	zoom_slider.min_value = ATLAS_ZOOM_MIN
	zoom_slider.max_value = ATLAS_ZOOM_MAX
	zoom_slider.step = 0.05
	zoom_slider.value = atlas_zoom
	zoom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_row.add_child(zoom_slider)

	var zoom_reset := Button.new()
	zoom_reset.text = "1:1"
	zoom_row.add_child(zoom_reset)

	# --------------------------------------------------
	# Atlas Tabs
	# --------------------------------------------------
	var tabs := TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var atlas_views := {}            # source_id -> view dict
	var tab_index_to_source := []    # index -> source_id

	var tileset := brush.tileset
	var source_count := tileset.get_source_count()

	for i in range(source_count):
		var source_id := tileset.get_source_id(i)
		var src := tileset.get_source(source_id)

		if not (src is TileSetAtlasSource):
			continue

		var view := build_atlas_view(brush, source_id)
		if view.is_empty():
			continue

		atlas_views[source_id] = view
		tabs.add_child(view.scroll)
		tab_index_to_source.append(source_id)


		var tab_name = src.texture.resource_path.get_file().get_basename()
		if tab_name.is_empty():
			tab_name = "Source %d" % source_id
		tabs.set_tab_title(tabs.get_child_count() - 1, tab_name)
	# Restore active tab
	if brush.active_tileset_source_id != -1:
		for i in range(tab_index_to_source.size()):
			if tab_index_to_source[i] == brush.active_tileset_source_id:
				tabs.current_tab = i
				break

	add_custom_control(tabs)
	tabs.tab_changed.connect(func(tab_idx):
		if tab_idx >= 0 and tab_idx < tab_index_to_source.size():
			brush.active_tileset_source_id = tab_index_to_source[tab_idx]
			brush.notify_property_list_changed()
	)

	# --------------------------------------------------
	# Select Mode + Zoom (same row)
	# --------------------------------------------------
	var mode_row := HBoxContainer.new()
	mode_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var mode_label := Label.new()
	mode_label.text = "Select Mode"
	mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_child(mode_label)

	var mode_dropdown := OptionButton.new()
	mode_dropdown.add_item("Tiles", TileModeller.TileSelectMode.TILES)
	mode_dropdown.add_item("Corners", TileModeller.TileSelectMode.CORNERS)
	mode_dropdown.select(brush.select_mode)
	mode_row.add_child(mode_dropdown)

	mode_row.add_child(zoom_row)
	add_custom_control(mode_row)

	# --------------------------------------------------
	# Corner snapping (only when in CORNERS mode)
	# --------------------------------------------------
	if brush.select_mode == TileModeller.TileSelectMode.CORNERS:
		var snap_row := HBoxContainer.new()

		var snap_label := Label.new()
		snap_label.text = "Snapping"
		snap_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		snap_row.add_child(snap_label)

		var snap_spin := SpinBox.new()
		snap_spin.min_value = 1
		snap_spin.step = 1
		snap_spin.value = brush.corner_snap
		snap_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		snap_spin.value_changed.connect(func(v):
			brush.corner_snap = int(v)
		)

		snap_row.add_child(snap_spin)
		add_custom_control(snap_row)

	add_custom_control(HSeparator.new())

	# --------------------------------------------------
	# Callbacks
	# --------------------------------------------------
	mode_dropdown.item_selected.connect(func(idx):
		brush.select_mode = mode_dropdown.get_item_id(idx)
		brush.notify_property_list_changed()
		for view in atlas_views.values():
			view.tex.queue_redraw()
	)

	zoom_slider.value_changed.connect(func(v):
		atlas_zoom = v
		for view in atlas_views.values():
			var size := Vector2(view.atlas_size) * atlas_zoom
			view.tex.custom_minimum_size = size
			view.checker.custom_minimum_size = size
			view.tex.queue_redraw()
			view.checker.queue_redraw()
	)

	zoom_reset.pressed.connect(func():
		atlas_zoom = 1.0
		zoom_slider.value = 1.0
		for view in atlas_views.values():
			var size := Vector2(view.atlas_size)
			view.tex.custom_minimum_size = size
			view.checker.custom_minimum_size = size
			view.tex.queue_redraw()
			view.checker.queue_redraw()
	)

func _draw_tile_selection(tex, brush, draw_rect, tile_size_f, scale):
	for tile in brush.selected_tiles:
		var rect := Rect2(
			draw_rect.position + Vector2(tile) * tile_size_f * scale,
			tile_size_f * scale
		)

		tex.draw_rect(rect, Color(0.3, 0.8, 1.0, 0.25), true)
		tex.draw_rect(rect.grow(0.5), Color(0.3, 0.8, 1.0), false, 2)

func _draw_corner_selection(tex, brush, draw_rect, tile_size_f, scale):
	var corners = brush.tile_corners

	for tile in brush.selected_tiles:
		var pts := PackedVector2Array()
		for c in corners:
			pts.append(
				draw_rect.position
				+ (Vector2(tile) * tile_size_f + c) * scale
			)

		for i in range(4):
			tex.draw_line(
				pts[i],
				pts[(i + 1) % 4],
				Color(1.0, 0.85, 0.3),
				2.0
			)

		for i in pts.size():
			var color := Color.YELLOW
			var radius := 3.0

			if i == hover_corner:
				color = Color.ORANGE
				radius = 5.0

			if dragging_corner and i == active_corner:
				color = Color.RED
				radius = 5.0

			tex.draw_circle(pts[i], radius, color)

func _handle_tile_selection(event, brush, tex, atlas_size, tile_size):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			selecting = true
			select_start_tile = mouse_to_tile(
				event.position,
				tex,
				atlas_size,
				tile_size
			)
			select_end_tile = select_start_tile
			brush.tile_corners
		else:
			selecting = false

			brush.selected_tiles.clear()

			var min_x = min(select_start_tile.x, select_end_tile.x)
			var max_x = max(select_start_tile.x, select_end_tile.x)
			var min_y = min(select_start_tile.y, select_end_tile.y)
			var max_y = max(select_start_tile.y, select_end_tile.y)

			for y in range(min_y, max_y + 1):
				for x in range(min_x, max_x + 1):
					brush.selected_tiles.append(Vector2i(x, y))

			# Optional: set primary tile
			brush.tile_coord = select_start_tile

			brush.notify_property_list_changed()
			tex.queue_redraw()

	elif event is InputEventMouseMotion and selecting:
		select_end_tile = mouse_to_tile(
			event.position,
			tex,
			atlas_size,
			tile_size
		)
		brush.selected_tiles.clear()

		var min_x = min(select_start_tile.x, select_end_tile.x)
		var max_x = max(select_start_tile.x, select_end_tile.x)
		var min_y = min(select_start_tile.y, select_end_tile.y)
		var max_y = max(select_start_tile.y, select_end_tile.y)

		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				brush.selected_tiles.append(Vector2i(x, y))

		# Optional: set primary tile
		brush.tile_coord = select_start_tile
		tex.queue_redraw()


func get_texture_rect(tex: TextureRect) -> Rect2:
	var tex_size: Vector2 = tex.texture.get_size()
	var view_size: Vector2 = tex.size

	var scale := min(
		view_size.x / tex_size.x,
		view_size.y / tex_size.y
	)

	var draw_size = tex_size * scale
	var offset = (view_size - draw_size) * 0.5 # <-- center it

	return Rect2(Vector2.ZERO, draw_size)

func mouse_to_tile_pixel(
	pos: Vector2,
	tex: TextureRect,
	atlas_size: Vector2i,
	tile_size: Vector2i
) -> Vector2:
	var draw_rect := get_texture_rect(tex)
	var local := pos - draw_rect.position
	var atlas_pos := local / draw_rect.size * Vector2(atlas_size)

	return Vector2(
		fmod(atlas_pos.x, tile_size.x),
		fmod(atlas_pos.y, tile_size.y)
	)

func find_nearest_corner(pixel: Vector2, tile_size: Vector2i) -> int:
	var corners := [
		Vector2(0, 0),
		Vector2(tile_size.x, 0),
		Vector2(tile_size.x, tile_size.y),
		Vector2(0, tile_size.y)
	]

	var best := 0
	var best_dist := INF
	for i in range(4):
		var d := pixel.distance_squared_to(corners[i])
		if d < best_dist:
			best_dist = d
			best = i
	return best
func _handle_corner_edit(event, brush, tex, atlas_size, tile_size):
	if brush.selected_tiles.is_empty():
		return

	# --- Mouse Down ---
	if event is InputEventMouseButton:
		if event.pressed:
			var draw_rect := get_texture_rect(tex)
			var scale := draw_rect.size / Vector2(atlas_size)

			var handles := get_corner_screen_positions(
				active_tile,
				brush.tile_corners,
				draw_rect,
				Vector2(tile_size),
				scale
			)

			active_corner = pick_corner_screen(event.position, handles, scale)
			if active_corner != -1:
				dragging_corner = true

		else:
			dragging_corner = false
			active_corner = -1

	# --- Mouse Drag ---
	elif event is InputEventMouseMotion and dragging_corner:
		var atlas_pixel := mouse_to_atlas_pixel(event.position, tex, atlas_size)
		var tile_origin := Vector2(active_tile) * Vector2(tile_size)
		var pixel := atlas_pixel - tile_origin

		if brush.corner_snap > 0:
			pixel.x = round(pixel.x / brush.corner_snap) * brush.corner_snap
		else:
			pixel.x = round(pixel.x)

		if brush.corner_snap > 0:
			pixel.y = round(pixel.y / brush.corner_snap) * brush.corner_snap
		else:
			pixel.y = round(pixel.y)

		brush.tile_corners[active_corner] = pixel
		tex.queue_redraw()

	if event is InputEventMouseMotion and not dragging_corner:
		var hover_tile := mouse_to_tile(
			event.position,
			tex,
			atlas_size,
			tile_size
		)

		if not brush.selected_tiles.has(hover_tile):
			hover_corner = -1
			tex.queue_redraw()
			return

		var draw_rect := get_texture_rect(tex)
		var scale := draw_rect.size / Vector2(atlas_size)

		var corners = brush.tile_corners

		var handles := get_corner_screen_positions(
			hover_tile,
			corners,
			draw_rect,
			Vector2(tile_size),
			scale
		)

		hover_corner = pick_corner_screen(event.position, handles, scale)
		active_tile = hover_tile  # <-- keep state in sync
		tex.queue_redraw()

func get_corner_screen_positions(
	tile: Vector2i,
	corners: Array,
	draw_rect: Rect2,
	tile_size: Vector2,
	scale: Vector2
) -> Array:
	var result := []
	for c in corners:
		result.append(
			draw_rect.position
			+ (Vector2(tile) * tile_size + c) * scale
		)
	return result

func pick_corner_screen(
	mouse_pos: Vector2,
	handles: Array,
	scale: Vector2
) -> int:
	var radius := get_handle_pick_radius(scale)
	var max_dist_sq := radius * radius

	var best := -1
	var best_dist := INF

	for i in handles.size():
		var d := mouse_pos.distance_squared_to(handles[i])
		if d < max_dist_sq and d < best_dist:
			best_dist = d
			best = i

	return best

func get_handle_pick_radius(scale: Vector2) -> float:
	# 6 px at 1:1, grows when zoomed out
	return max(6.0, 12.0 / scale.x)
