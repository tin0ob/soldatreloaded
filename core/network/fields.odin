package network

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "../game"
import res "../resources"
import "../utils"

// A struct on the wire, field by field, whole or as a delta against a baseline: one bit
// per field, then the fields that changed. Which fields, and how wide, is read once from
// the struct's `net` tags into a table that drives one routine:
//
//   pos:     utils.Vec2      `net:"owned"`          rides in the owned half
//   held:    Maybe(Thing_Id) `net:"served"`         in the served half
//   loadout: Loadout         `net:"served loadout"` a struct: every field of it, in both
//   ammo:    i32             `net:"owned 10"`       a number is the width on the wire
//
// A field inside a tagged struct takes the struct's groups unless it has its own. A
// struct field without a tag is looked through for tagged fields. Widths are generous:
// a delta sends only what changed, and a value that does not fit its width goes bad in
// a test rather than on the wire (net_bits). fields_of(T, "") is every field of a
// struct whatever its tags: a message's payload.

Field :: struct {
	name:   string,
	offset: uintptr,
	size:   int,        // in memory
	kind:   Field_Kind,
	bits:   int,        // on the wire, for the integers
	max:    u32,        // Unsigned, Maybe: the largest value allowed; 0 for any
	tag:    uintptr,    // Maybe: where its tag is
	tag_size: int,      // and how many bytes it takes
}

Field_Kind :: enum {
	Unsigned,  // an integer, an enum, a bit_set: `bits` wide, up to `max`
	Signed,    // two's complement in `bits`
	Bool,
	F32,
	Vec2,
	Rgba,
	Maybe,     // Maybe(T) of an integer or an enum, never negative: 0 for nil, else the value and one
	Animation, // res.Animation_State: the id and the frame; the rest is each machine's own
}

Field_Table :: []Field

// The soldier's halves (soldier.odin's tags), its loadout, a thing, a look, the weapons'
// numbers, and the round as the wire carries it (stream.odin's Round_Wire).
SOLDIER_OWNED_FIELDS: Field_Table
SOLDIER_SERVED_FIELDS: Field_Table
SOLDIER_LOADOUT_FIELDS: Field_Table
ROPE_FIELDS: Field_Table
THING_FIELDS: Field_Table
LOOK_FIELDS: Field_Table
WEAPONS_FIELDS: Field_Table
ROUND_FIELDS: Field_Table

@(init, private = "file")
tables_init :: proc "contextless" () {
	context = runtime.default_context()
	SOLDIER_OWNED_FIELDS = fields_of(game.Soldier, "owned")
	SOLDIER_SERVED_FIELDS = fields_of(game.Soldier, "served")
	SOLDIER_LOADOUT_FIELDS = fields_of(game.Soldier, "loadout")
	ROPE_FIELDS = fields_of(game.Rope, "")
	THING_FIELDS = fields_of(game.Thing, "served")
	LOOK_FIELDS = fields_of(game.Look, "")
	WEAPONS_FIELDS = fields_of(Msg_Weapons, "")
	ROUND_FIELDS = fields_of(Round_Wire, "")
}

// The fields of `id` in `group`, or all of them for "". Kept for the program's life.
fields_of :: proc(id: typeid, group: string, allocator := context.allocator) -> Field_Table {
	fields := make([dynamic]Field, allocator)
	collect(&fields, id, group, 0, "", "")
	return fields[:]
}

@(private = "file")
collect :: proc(fields: ^[dynamic]Field, id: typeid, want: string, base: uintptr, prefix: string, inherited: string) {
	for f in reflect.struct_fields_zipped(id) {
		groups, bits := parse_tag(f.tag)
		if groups == "" do groups = inherited
		name := f.name if prefix == "" else fmt.aprintf("%s.%s", prefix, f.name)
		add(fields, f.type, want, base + f.offset, name, groups, bits)
	}
}

// `net:"owned served 16"`: the groups, and a number for the width.
@(private = "file")
parse_tag :: proc(tag: reflect.Struct_Tag) -> (groups: string, bits: int) {
	text, _ := reflect.struct_tag_lookup(tag, "net")
	rest := text
	for token in strings.split_iterator(&rest, " ") {
		if n, ok := strconv.parse_int(token); ok {
			bits = n
		} else {
			groups = text
		}
	}
	return
}

@(private = "file")
has_group :: proc(groups, want: string) -> bool {
	rest := groups
	for token in strings.split_iterator(&rest, " ") {
		if token == want do return true
	}
	return false
}

@(private = "file")
add :: proc(fields: ^[dynamic]Field, info: ^runtime.Type_Info, want: string, offset: uintptr, name, groups: string, bits: int) {
	included := want == "" || has_group(groups, want)
	switch info.id {
	case utils.Vec2:
		if included do append(fields, Field{name = name, offset = offset, size = size_of(utils.Vec2), kind = .Vec2})
		return
	case utils.Rgba:
		if included do append(fields, Field{name = name, offset = offset, size = size_of(utils.Rgba), kind = .Rgba})
		return
	case res.Animation_State:
		if included do append(fields, Field{name = name, offset = offset, size = size_of(res.Animation_State), kind = .Animation})
		return
	}
	#partial switch v in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Struct:
		collect(fields, info.id, want, offset, name, groups)
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			add(fields, v.elem, want, offset + uintptr(i * v.elem_size), fmt.aprintf("%s[%d]", name, i), groups, bits)
		}
	case runtime.Type_Info_Enumerated_Array: // [Weapon]T, in the enum's order
		for i in 0 ..< v.count {
			add(fields, v.elem, want, offset + uintptr(i * v.elem_size), fmt.aprintf("%s[%d]", name, i), groups, bits)
		}
	case:
		if included do append(fields, leaf(info, offset, name, bits))
	}
}

// One value as the wire carries it; a kind the wire doesn't carry is a mistake in a tag.
@(private = "file")
leaf :: proc(info: ^runtime.Type_Info, offset: uintptr, name: string, bits: int) -> Field {
	field := Field{name = name, offset = offset, size = info.size, bits = bits}
	#partial switch v in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Integer:
		field.kind = .Signed if v.signed else .Unsigned
		if field.bits == 0 do field.bits = min(info.size * 8, 64 if field.kind == .Unsigned else 32)
	case runtime.Type_Info_Enum:
		field.kind = .Unsigned
		field.max = enum_max(v)
		field.bits = bits_for(field.max)
	case runtime.Type_Info_Bit_Set:
		field.kind = .Unsigned
		field.bits = info.size * 8
	case runtime.Type_Info_Boolean:
		field.kind = .Bool
	case runtime.Type_Info_Float:
		assert(info.size == 4, "only f32 goes on the wire")
		field.kind = .F32
	case runtime.Type_Info_Union:
		assert(len(v.variants) == 1 && !v.no_nil, fmt.tprintf("%s: only a Maybe goes on the wire, not a %v", name, info.id))
		inner := leaf(v.variants[0], offset, name, bits)
		assert(inner.kind == .Unsigned || inner.kind == .Signed, fmt.tprintf("%s: only a Maybe of an integer or an enum goes on the wire, not of a %v", name, v.variants[0].id))
		field.kind = .Maybe
		field.size = inner.size
		field.tag = v.tag_offset
		field.tag_size = v.tag_type.size
		assert(int(field.tag) >= field.size, fmt.tprintf("%s: a Maybe's tag is expected after its value", name)) // field_bytes spans both
		field.max = inner.max + 1 if inner.max != 0 else u32(1) << uint(min(inner.bits, 31))
	case:
		panic(fmt.tprintf("%s: a %v can't go on the wire", name, info.id))
	}
	return field
}

@(private = "file")
enum_max :: proc(v: runtime.Type_Info_Enum) -> (highest: u32) {
	for value in v.values do highest = max(highest, u32(value))
	return
}

// ---------------------------------------------------------------------------------
// The table at work

@(private = "file")
load_uint :: proc(at: rawptr, size: int) -> (v: u64) {
	mem.copy(&v, at, size) // little-endian: the low bytes are the value
	return
}

@(private = "file")
store_uint :: proc(at: rawptr, size: int, v: u64) {
	v := v
	mem.copy(at, &v, size)
}

// One field, written or read, at `at` in the struct.
@(private = "file")
field_serialize :: proc(b: ^Buffer, f: ^Field, at: rawptr) {
	switch f.kind {
	case .Unsigned:
		v := load_uint(at, f.size)
		if f.bits > 32 {
			net_u64(b, &v)
		} else {
			x := u32(v)
			net_bits(b, &x, f.bits)
			if f.max != 0 && x > f.max do b.bad = true
			v = u64(x)
		}
		store_uint(at, f.size, v)
	case .Signed:
		// sign-extend from the memory width, then the wire's
		shift := uint(64 - f.size * 8)
		v := i32(i64(load_uint(at, f.size) << shift) >> shift)
		net_signed(b, &v, f.bits)
		store_uint(at, f.size, u64(i64(v)))
	case .Bool:
		net_bool(b, (^bool)(at))
	case .F32:
		net_f32(b, (^f32)(at))
	case .Vec2:
		net_vec2(b, (^utils.Vec2)(at))
	case .Rgba:
		for &channel in (^utils.Rgba)(at) do net_u8(b, &channel)
	case .Maybe:
		tag_at := rawptr(uintptr(at) + f.tag)
		v := u32(load_uint(at, f.size)) + 1 if load_uint(tag_at, f.tag_size) != 0 else 0
		net_range(b, &v, f.max)
		if b.reading {
			store_uint(tag_at, f.tag_size, 1 if v != 0 else 0)
			store_uint(at, f.size, u64(v - 1) if v != 0 else 0)
		}
	case .Animation:
		state := (^res.Animation_State)(at)
		net_enum(b, &state.id)
		frame := state.frame
		net_signed(b, &frame, 8)
		state.frame = frame
	}
}

// What of a field is compared and copied: all of it, but an animation's id and frame;
// a Maybe's value and its tag, so nil and a 0 are told apart.
@(private = "file")
field_bytes :: proc(f: ^Field, at: rawptr) -> []u8 {
	size := f.size
	#partial switch f.kind {
	case .Animation: size = int(offset_of(res.Animation_State, count))
	case .Maybe:     size = int(f.tag) + f.tag_size
	}
	return ([^]u8)(at)[:size]
}

// The struct `state` on the wire by `fields`: every field, or, with a `base`, one bit
// per field and only the fields that differ from it. Reading with a base takes the
// unchanged fields from it. Fields the table does not name are left alone.
fields_serialize :: proc(b: ^Buffer, fields: Field_Table, state: rawptr, base: rawptr) {
	for &f in fields {
		at := rawptr(uintptr(state) + f.offset)
		if base != nil {
			from := rawptr(uintptr(base) + f.offset)
			changed := !b.reading && mem.compare(field_bytes(&f, at), field_bytes(&f, from)) != 0
			net_bool(b, &changed)
			if !changed {
				if b.reading do copy(field_bytes(&f, at), field_bytes(&f, from))
				continue
			}
		}
		field_serialize(b, &f, at)
	}
}

// Every field of the table from `src` into `dst`; the rest of `dst` left alone.
fields_copy :: proc(fields: Field_Table, dst, src: rawptr) {
	for &f in fields {
		copy(field_bytes(&f, rawptr(uintptr(dst) + f.offset)), field_bytes(&f, rawptr(uintptr(src) + f.offset)))
	}
}

// Whether two structs agree on every field of the table.
fields_equal :: proc(fields: Field_Table, a, b: rawptr) -> bool {
	for &f in fields {
		if mem.compare(field_bytes(&f, rawptr(uintptr(a) + f.offset)), field_bytes(&f, rawptr(uintptr(b) + f.offset))) != 0 do return false
	}
	return true
}
