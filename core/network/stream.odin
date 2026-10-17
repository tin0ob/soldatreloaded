package network

import "../game"
import res "../resources"

// The two streams: the client's state every tick, the server's snapshot every tick,
// both unreliable and both delta-compressed against the newest the other side
// acknowledged, the acknowledgement riding in the packet going the other way. Both ends
// of both streams are here (stream_server.odin, stream_client.odin), so a test can
// drive either.
//
// Client state: the owned half of the client's soldier, numbered; the server takes it
// as written after its checks. It is a delta against the client's own earlier state the
// server last acknowledged, which both keep in a ring; whole when there is none young
// enough.
//
// Snapshot: numbered by the server's tick. For every slot a word: no soldier, the
// soldier's halves, or nothing this time (held back to fit the datagram; the client
// keeps stepping it). A soldier's halves are a delta against the snapshot the client
// last acknowledged, if that snapshot carried the soldier, and whole otherwise; the
// server deltas against what it sent, out of its history, and the client against what
// it received. The round (its phase, clock and scores) is a delta against the round the
// same base carried, as the C game's match is. The client applies the served half of
// everyone and the owned half of everyone but itself, and its own only on a new life: a
// placing.
//
// Between words, everyone steps a soldier heard of on its last keys
// (soldier_last_command), one-shot buttons cleared so a throw is not thrown again;
// after STREAM_RELEASE_TICKS of silence the keys are let go and it falls and stops.

STREAM_RING :: 32          // states kept for deltas, each side
STREAM_WHOLE_AFTER :: 24   // a baseline older than this many states or ticks: whole
STREAM_RELEASE_TICKS :: 30 // no word for this long: the keys are let go

// ---------------------------------------------------------------------------------
// The messages

// Each stream's message is a header and a body. The header says what the body is a delta
// against, so a reader reads the header, finds that base, and reads the body against it.

// The client state's header.
Client_State_Header :: struct {
	round:     u16, // the round it is of (Msg_Map); another round's is dropped
	seq:       u32, // this state's number, the client's count from 1
	base:      u32, // the state it is a delta against, 0 for whole
	ack:       u32, // the newest snapshot (its tick) the client has, 0 for none
	event_ack: u32, // the newest of the server's words the client has heard
	life:      u8,  // the life the soldier is on here: the word of an older life is not taken
}

Msg_Client_State :: struct {
	using header: Client_State_Header,
	owned:        game.Soldier, // the owned half, and the loadout, ride in a Soldier
	typing:       bool,         // the player is at the chat prompt: the dots over its head
	// then the client's own decisions since the server's acknowledgement (wire_write)
}

msg_client_state_header :: proc(b: ^Buffer, h: ^Client_State_Header) {
	net_u16(b, &h.round)
	net_u32(b, &h.seq)
	net_u32(b, &h.base)
	net_u32(b, &h.ack)
	net_u32(b, &h.event_ack)
	net_u8(b, &h.life)
}

// The half; `base` is the soldier the delta is against, nil for whole; in reading, the
// fields it holds that didn't change are taken from it. The words follow, written and
// read with wire_write and wire_read.
msg_client_state_body :: proc(b: ^Buffer, m: ^Msg_Client_State, base: ^game.Soldier) {
	fields_serialize(b, SOLDIER_OWNED_FIELDS, &m.owned, base)
	fields_serialize(b, SOLDIER_LOADOUT_FIELDS, &m.owned, base)
	net_bool(b, &m.typing)
}

Snap_Word :: enum u8 {
	Gone,  // no soldier in the slot
	State, // the soldier's halves follow
	Same,  // nothing this time: keep stepping it
	Rope,  // the rope's fields follow, the rest stays as the client steps it
}

// What a snapshot says of the soldiers and the things: a word for each slot, and its
// state where the word is State.
Snap_State :: struct {
	word:       [game.MAX_PLAYERS]Snap_Word,
	soldiers:   [game.MAX_PLAYERS]game.Soldier,
	thing_word: [game.MAX_THINGS]Snap_Word,
	things:     [game.MAX_THINGS]game.Thing,
}

// The snapshot's header.
Snapshot_Header :: struct {
	round:            u16, // the round it is of (Msg_Map); another round's is dropped
	tick:             u32, // the snapshot's number
	base:             u32, // the snapshot it is a delta against, 0 for whole
	client_ack:       u32, // the newest client state (its seq) the server has from this client
	client_event_ack: u32, // the newest of the client's words the server has heard
}

Msg_Snapshot :: struct {
	using header: Snapshot_Header,
	match:        game.Round,
	using state:  Snap_State,
	names:        [game.MAX_PLAYERS]Name, // sent with a soldier that goes whole
	// then the server's words since the client's acknowledgement (wire_write)
}

// What a snapshot is a delta against: the soldiers and things of the acknowledged
// snapshot and the words it carried, by reference, since the server keeps them apart
// (the soldiers and things in the game's history, the words in what it sent); nil for
// whole. A slot the base did not carry (not State) goes whole, and a soldier that goes
// whole brings its name.
Snap_Base :: struct {
	soldiers:   ^[game.MAX_PLAYERS]game.Soldier,
	word:       ^[game.MAX_PLAYERS]Snap_Word,
	things:     ^[game.MAX_THINGS]game.Thing,
	thing_word: ^[game.MAX_THINGS]Snap_Word,
	round:      ^game.Round, // the round as that snapshot carried it
}

msg_snapshot_header :: proc(b: ^Buffer, h: ^Snapshot_Header) {
	net_u16(b, &h.round)
	net_u32(b, &h.tick)
	net_u32(b, &h.base)
	net_u32(b, &h.client_ack)
	net_u32(b, &h.client_event_ack)
}

// The round, the soldiers with their names, the things. The words follow, written and
// read with wire_write and wire_read_pending.
msg_snapshot_body :: proc(b: ^Buffer, m: ^Msg_Snapshot, base: ^Snap_Base) {
	net_round(b, &m.match, base.round if base != nil else nil)
	for &word, i in m.word {
		net_enum(b, &word)
		switch word {
		case .Gone, .Same:
		case .State:
			against := &base.soldiers[i] if base != nil && base.word[i] == .State else nil
			fields_serialize(b, SOLDIER_SERVED_FIELDS, &m.soldiers[i], against)
			fields_serialize(b, SOLDIER_OWNED_FIELDS, &m.soldiers[i], against)
			if against == nil do net_string(b, &m.names[i]) // a soldier going whole brings its name
		case .Rope:
			against := &base.soldiers[i] if base != nil && (base.word[i] == .State || base.word[i] == .Rope) else nil
			fields_serialize(b, ROPE_FIELDS, &m.soldiers[i].rope, &against.rope if against != nil else nil)
		}
	}
	for &word, i in m.thing_word {
		net_enum(b, &word)
		if word != .State do continue
		against := &base.things[i] if base != nil && base.thing_word[i] == .State else nil
		fields_serialize(b, THING_FIELDS, &m.things[i], against)
	}
}

// The round as the wire carries it: its phase flat, the ended phase's winner and
// countdown beside it (none while playing or paused), so a field table can take it.
Round_Wire :: struct {
	phase:     Round_Wire_Phase,
	winner:    res.Team,
	countdown: i32 `net:"16"`, // ticks the scores still stand, once ended
	time_left: i32 `net:"32"`,
	captures:  [res.Team]i32 `net:"16"`,
}

Round_Wire_Phase :: enum u8 {
	Playing,
	Paused,
	Ended,
}

round_wire :: proc(round: game.Round) -> (w: Round_Wire) {
	w.time_left, w.captures = round.time_left, round.captures
	switch p in round.phase {
	case game.Playing: w.phase = .Playing
	case game.Paused:  w.phase = .Paused
	case game.Ended:   w.phase, w.winner, w.countdown = .Ended, p.winner, p.countdown
	}
	return
}

round_unwire :: proc(w: Round_Wire) -> (round: game.Round) {
	round.time_left, round.captures = w.time_left, w.captures
	switch w.phase {
	case .Playing: round.phase = game.Playing{}
	case .Paused:  round.phase = game.Paused{}
	case .Ended:   round.phase = game.Ended{winner = w.winner, countdown = w.countdown}
	}
	return
}

// The round: its phase, its clock and the scores; a delta against `base` (the round the
// base snapshot carried), as the soldiers are, or whole without one. Most ticks only the
// clock has moved.
net_round :: proc(b: ^Buffer, round: ^game.Round, base: ^game.Round) {
	w := round_wire(round^)
	from: Round_Wire
	against: rawptr
	if base != nil {
		from = round_wire(base^)
		against = &from
		if b.reading do w = from
	}
	fields_serialize(b, ROUND_FIELDS, &w, against)
	if b.reading do round^ = round_unwire(w)
}

// ---------------------------------------------------------------------------------
// The halves taken

// The owned half of `src` onto `dst`, the animations' speed set from the anims as the
// fields cannot.
soldier_take_owned :: proc(animations: ^res.Animations, dst, src: ^game.Soldier) {
	fields_copy(SOLDIER_OWNED_FIELDS, dst, src)
	dst.pose.legs.speed = animations[dst.pose.legs.id].speed
	dst.pose.body.speed = animations[dst.pose.body.id].speed
}

soldier_take_served :: proc(dst, src: ^game.Soldier) {
	fields_copy(SOLDIER_SERVED_FIELDS, dst, src)
}
