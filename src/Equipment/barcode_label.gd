class_name BarcodeLabel
extends RefCounted

## Standardized parcel label per Label_Specification_18x18: one human-readable string
## [code]Turbo_G5XXXXX_Z[/code] plus FOUR identical 18x18 2D codes.
##
## Unlike a cosmetic pattern, these codes are REALLY DECODABLE: the 5-char payload is
## bit-encoded into the module grid with a checksum, so [method decode_grid] /
## [method decode_image] can recover it FROM PIXELS with no prior knowledge — that is what
## lets the CameraTunnel optically "read" a parcel it has never seen (see camera_tunnel.gd).
##
## Grid (18x18): col 0 + bottom row = solid finder "L"; top row + right col = timing
## pattern; the inner 16x16 carries 32 payload bits + 8 checksum bits (row-major), the
## rest is value-derived filler so it still looks like a dense Data-Matrix symbol.

const VENDOR: String = "G"
const VERSION: String = "5"
const SUFFIX: String = "Z"
const ALNUM: String = "abcdefghijklmnopqrstuvwxyz0123456789"  # base-36
const MODULES: int = 18
const N_CODES: int = 4
const DATA_BITS: int = 32
const CHECK_BITS: int = 8


## Returns {string, code, value}. value = base-36 of the 5 X chars (< 36^5, fits 26 bits).
static func generate() -> Dictionary:
	var code: String = ""
	var value: int = 0
	for i: int in 5:
		var idx: int = randi() % ALNUM.length()
		code += ALNUM[idx]
		value = value * 36 + idx
	var full: String = "Turbo_%s%s%s_%s" % [VENDOR, VERSION, code, SUFFIX]
	return {"string": full, "code": code, "value": value}


## value (0..36^5-1) -> "Turbo_G5XXXXX_Z" string.
static func value_to_string(value: int) -> String:
	var code: String = ""
	var v: int = value
	for i: int in 5:
		code = ALNUM[v % 36] + code
		v /= 36
	return "Turbo_%s%s%s_%s" % [VENDOR, VERSION, code, SUFFIX]


static func _checksum(value: int) -> int:
	return (value & 0xFF) ^ ((value >> 8) & 0xFF) ^ ((value >> 16) & 0xFF) ^ ((value >> 24) & 0xFF)


## Build the 18x18 module grid (Array of 18 rows, each Array of 18 bool) encoding [param value].
static func make_grid(value: int) -> Array:
	var g: Array = []
	for r: int in MODULES:
		var row: Array = []
		for c: int in MODULES:
			row.append(false)
		g.append(row)
	# finder "L": left column + bottom row solid
	for r: int in MODULES:
		g[r][0] = true
	for c: int in MODULES:
		g[MODULES - 1][c] = true
	# timing: top row + right column alternating
	for c: int in MODULES:
		g[0][c] = (c % 2 == 0)
	for r: int in MODULES:
		g[r][MODULES - 1] = (r % 2 == 1)
	# payload bits (value + checksum), row-major in inner 16x16
	var bits: Array = []
	for i: int in DATA_BITS:
		bits.append((value >> i) & 1)
	var cs: int = _checksum(value)
	for i: int in CHECK_BITS:
		bits.append((cs >> i) & 1)
	# filler is seeded BY THE VALUE, so every distinct parcel renders a visibly distinct
	# symbol (not just the 40 payload modules changing). Decode only reads the payload cells.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = value
	var idx: int = 0
	for r: int in range(1, MODULES - 1):
		for c: int in range(1, MODULES - 1):
			if idx < bits.size():
				g[r][c] = bits[idx] == 1
				idx += 1
			else:
				g[r][c] = rng.randf() < 0.5
	return g


## Decode a sampled 18x18 bool grid back to the value, or -1 if the finder/checksum fails.
static func decode_grid(g: Array) -> int:
	if g.size() != MODULES:
		return -1
	for r: int in MODULES:
		if not bool(g[r][0]):
			return -1
	for c: int in MODULES:
		if not bool(g[MODULES - 1][c]):
			return -1
	var bits: Array = []
	for r: int in range(1, MODULES - 1):
		for c: int in range(1, MODULES - 1):
			bits.append(1 if bool(g[r][c]) else 0)
	var value: int = 0
	for i: int in DATA_BITS:
		value |= bits[i] << i
	var cs: int = 0
	for i: int in CHECK_BITS:
		cs |= bits[DATA_BITS + i] << i
	if cs != _checksum(value):
		return -1
	return value


## Sample one code from an image: [param ox],[param oy] = top-left px of the code, [param cell]
## = px per module. Returns the decoded value or -1. (Used by the optical camera read.)
static func decode_image(img: Image, ox: int, oy: int, cell: float) -> int:
	if img == null:
		return -1
	var g: Array = []
	var w: int = img.get_width()
	var h: int = img.get_height()
	for r: int in MODULES:
		var row: Array = []
		for c: int in MODULES:
			var px: int = int(ox + (c + 0.5) * cell)
			var py: int = int(oy + (r + 0.5) * cell)
			if px < 0 or py < 0 or px >= w or py >= h:
				return -1
			row.append(img.get_pixel(px, py).get_luminance() < 0.5)
		g.append(row)
	return decode_grid(g)


## Builds the label albedo: four identical decodable codes on white.
static func make_texture(value: int) -> ImageTexture:
	var grid: Array = make_grid(value)
	var scale: int = 4
	var block: int = MODULES * scale
	var gap: int = 6
	var margin: int = 6
	var w: int = margin * 2 + N_CODES * block + (N_CODES - 1) * gap
	var h: int = margin * 2 + block
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	for b: int in N_CODES:
		var ox: int = margin + b * (block + gap)
		for my: int in MODULES:
			for mx: int in MODULES:
				if bool(grid[my][mx]):
					for py: int in scale:
						for px: int in scale:
							img.set_pixel(ox + mx * scale + px, margin + my * scale + py, Color.BLACK)
	return ImageTexture.create_from_image(img)
