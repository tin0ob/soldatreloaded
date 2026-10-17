package network

import "core:math"

import sa "core:container/small_array"

import "../game"
import "../utils"

// The client's end of the two streams (stream.odin).
//
// The client's view (client_stream_begin_tick): its world's tick is the server tick of
// the frame it shows, and it keeps that `interp` ticks behind the newest snapshot it
// has, so the snapshot of each tick is in hand when the tick comes, whatever the line's
// jitter, and is applied then, with the server's words of that tick. A snapshot that
// comes after its tick has passed is a late one, and raises `interp` for a while; a
// tick with no snapshot steps everyone on. The clock itself runs free and is nudged a
// tick at a time when the frames in hand run consistently over or under.
//
// A playing client's line drives it, and so do the tests.

STREAM_SNAP_DISTANCE :: f32(160) // a correction this far is a placing to the eye: shown at once, not smoothed
STREAM_INTERP_MAX :: 8           // ticks the view keeps behind the newest snapshot, at most
STREAM_INTERP_SETTLE :: 5 * game.TICK_RATE // no late snapshot for this long: a tick less behind
STREAM_VIEW_SNAP :: 8            // a view this far from where it should be jumps there
STREAM_VIEW_WINDOW :: 60         // ticks over which the frames in hand are watched before the clock is nudged
STREAM_VIEW_SLACK :: 2           // frames in hand beyond interp, at the leanest, before the view is nudged forward
STREAM_STEPS_MAX :: 16           // a word is stepped on this far at most: past it, it stands
THING_TOLERANCE :: f32(10)       // a thing's points are taken only when they disagree by more than this

// A snapshot as the client keeps it, for the tick that shows it.
Snap_Frame :: struct {
	using state: Snap_State,
	match:       game.Round,
	tick:        u32,
}

Client_Stream :: struct {
	snaps:        ^[STREAM_RING]Snap_Frame,  // the snapshots received, by tick; large, on the heap
	names:        [game.MAX_PLAYERS]Name,    // the players', as heard
	own:          [STREAM_RING]game.Soldier, // the states sent, by seq
	own_seq:      [STREAM_RING]u32,
	seq:          u32,  // the last state sent
	server_ack:   u32,  // the newest state the server has
	newest:       u32,  // the newest snapshot received (its tick), 0 for none
	applied:      u32,  // the newest snapshot applied to the world (its tick), 0 for none
	interp:       int,  // ticks the view keeps behind the newest: the floor asked for, raised by late snapshots
	late_tick:    u32,  // the newest's tick at the last late snapshot, for settling back down
	grew_tick:    u32,  // and at the last raise, so it is raised a tick a second at most
	level_min:    i32,  // the fewest frames in hand over the window being watched
	window:       int,  // ticks of it left
	word_applied: [game.MAX_PLAYERS]u32, // the newest snapshot tick each soldier was taken from
	pending:      Wire_Pending,          // the server's words heard, each done in the tick of its frame
	last_word:    [game.MAX_PLAYERS]u32, // the snapshot tick each soldier was last heard of in
	// What a correction moved each soldier by, still to be shown: a new word snaps the
	// simulation but the picture glides, the offset easing to nothing over cl_smooth as
	// a critically damped spring does, from rest and without overshoot, so the picture
	// keeps its speed as well as its place at the moment of the word
	// (client_stream_smooth). A correction past STREAM_SNAP_DISTANCE snaps.
	blend:        [game.MAX_PLAYERS]utils.Vec2,
	blend_vel:    [game.MAX_PLAYERS]utils.Vec2, // how fast the offset is closing
	out:          Wire_Queue, // my decisions, for the server
	event_ack:    u32,  // the newest of my words the server has heard
	event_last:   u32,  // the newest of the server's words heard here
	view_at:      u32,  // the tick the next begin_tick shows, its clock passed over, 0 for the clock's: a demo's, as recorded
	round:        u16,  // the round I am in (Msg_Map); snapshots of another are dropped
	stats:        Client_Stream_Stats,
}

// What the client's end has seen of the line, counted: none of it steers the stream.
Client_Stream_Stats :: struct {
	arrived:    u32, // snapshots heard and kept: the loss is the ticks the newest moved on by, less these
	dropped:    u32, // snapshots that couldn't be read
	stale:      u32, // snapshots of another round
	late:       u32, // snapshots that came after the view had passed their tick
	misses:     u32, // ticks the view had no snapshot of, and stepped everyone on
	skipped:    u32, // ticks the view clock was nudged forward
	held:       u32, // and back
	resyncs:    u32, // times it jumped
	applies:    u32, // snapshots applied to the world
	held_back:  u32, // times a soldier I know was held back from a snapshot (Same)
	largest:    int, // the largest snapshot heard, in bytes
	correction: f32, // how far, all told, the applied snapshots moved the others from where stepping had them
}

client_stream_init :: proc(c: ^Client_Stream) {
	c^ = {snaps = new([STREAM_RING]Snap_Frame)}
}

client_stream_destroy :: proc(c: ^Client_Stream) {
	free(c.snaps)
	c^ = {}
}

// A round begins (a join, a new map): nothing heard, nothing sent, this round's from now.
client_stream_reset :: proc(c: ^Client_Stream, round: u16) {
	snaps := c.snaps
	c^ = {snaps = snaps, round = round}
	snaps^ = {}
	wire_queue_init(&c.out)
}

// A thing as heard, onto the client's: what it is and whose, always; where its points
// are, only when they disagree with the client's own by more than a little, and never
// while it is held, since a held thing rides its holder here. A thing that appeared or
// changed kind is taken whole.
@(private = "file")
thing_apply :: proc(t: ^game.Thing, heard: ^game.Thing) {
	fresh := t.kind != heard.kind || t.point_count != heard.point_count
	was := t^
	fields_copy(THING_FIELDS, t, heard)
	if fresh do return
	keep := heard.holder != nil || (utils.length(was.points[0] - heard.points[0]) <= THING_TOLERANCE && utils.length(was.points[1] - heard.points[1]) <= THING_TOLERANCE)
	if keep {
		t.points = was.points
		t.old_points = was.old_points
	}
}

// A snapshot heard: read against its base and kept, with its words, for the tick that
// shows it. `me` is for the bink alone. False if dropped.
client_stream_hear :: proc(c: ^Client_Stream, g: ^game.Game, me: game.Soldier_Id, data: []u8) -> bool {
	b := buffer_reader(data)
	kind: Msg_Kind
	m := new(Msg_Snapshot, context.temp_allocator)
	msg_kind(&b, &kind)
	msg_snapshot_header(&b, &m.header)
	if buffer_ok(&b) && m.round != c.round { // another round's: the Map that begins it hasn't come, or it is over
		c.stats.stale += 1
		return false
	}
	if !buffer_ok(&b) || m.tick <= c.newest {
		c.stats.dropped += 1
		return false
	}
	base: Snap_Base
	against: ^Snap_Base
	if m.base != 0 {
		frame := &c.snaps[m.base % STREAM_RING]
		if frame.tick != m.base {
			c.stats.dropped += 1
			return false
		}
		base = {soldiers = &frame.soldiers, word = &frame.word, things = &frame.things, thing_word = &frame.thing_word, round = &frame.match}
		against = &base
		// the soldiers and things start from the base, where it carried them, so the delta
		// lands on it
		for i in 0 ..< game.MAX_PLAYERS {
			switch frame.word[i] {
			case .State: m.soldiers[i] = frame.soldiers[i]
			case .Rope:  m.soldiers[i].rope = frame.soldiers[i].rope
			case .Gone, .Same:
			}
		}
		for i in 0 ..< game.MAX_THINGS {
			if frame.thing_word[i] == .State do m.things[i] = frame.things[i]
		}
	}
	msg_snapshot_body(&b, m, against)
	if !buffer_ok(&b) {
		c.stats.dropped += 1
		return false
	}

	// the server's words, each once, kept for the tick of their frame
	wire_read_pending(&b, &c.pending)
	if !buffer_done(&b) {
		c.stats.dropped += 1
		return false
	}
	c.event_ack = max(c.event_ack, m.client_event_ack)
	// The server's damage to me binks me as it is heard, not when its tick comes on show:
	// the aim is mine, in my present, and a hit the bullet flown here missed is binked all
	// the same (soldier_hit_spray takes it as the flown one's word when both come).
	for seq in sa.slice(&c.pending.fresh) {
		ruling, is_ruling := c.pending.items[seq % WIRE_PENDING].word.(game.Ruling)
		if !is_ruling do continue
		if damage, is_damage := ruling.(game.Damage); is_damage && damage.target == me && game.weapon_binks(damage.weapon) {
			game.soldier_hit_spray(&g.world, &g.resources, me, damage.attacker, .Told)
		}
	}
	for i in 0 ..< game.MAX_PLAYERS {
		if m.word[i] == .State {
			c.last_word[i] = m.tick
			if m.names[i].length != 0 do c.names[i] = m.names[i]
		} else if m.word[i] == .Rope {
			c.last_word[i] = m.tick // its rope was heard of: it isn't quiet
		} else if m.word[i] == .Same && g.world.soldiers[i].active {
			c.stats.held_back += 1
		}
	}
	c.stats.largest = max(c.stats.largest, len(data))
	// one that comes after the view has passed its tick was too late to show: the view
	// keeps further behind for a while, a tick more each second at most
	if c.applied != 0 && m.tick < g.world.tick {
		c.stats.late += 1
		c.late_tick = m.tick
		if c.interp < STREAM_INTERP_MAX && (c.grew_tick == 0 || m.tick - c.grew_tick > game.TICK_RATE) {
			c.interp += 1
			c.grew_tick = m.tick
		}
	}

	frame := &c.snaps[m.tick % STREAM_RING]
	frame^ = {state = m.state, match = m.match, tick = m.tick}
	c.newest = m.tick
	c.server_ack = max(c.server_ack, m.client_ack)
	c.stats.arrived += 1
	return true
}

// The snapshot in `frame` onto the world, all but the other soldiers: the round, the
// things, `me`, and who is gone.
@(private = "file")
frame_apply :: proc(c: ^Client_Stream, g: ^game.Game, me: game.Soldier_Id, frame: ^Snap_Frame) {
	w := &g.world
	g.round = frame.match // the round is the server's
	for i in 0 ..< game.MAX_PLAYERS {
		s := &w.soldiers[i]
		if frame.word[i] == .Gone {
			if game.Soldier_Id(i) != me do s.active = false
		} else if frame.word[i] == .State && game.Soldier_Id(i) == me {
			// the server's word of me, but my look, loadout and typing are mine
			heard := &frame.soldiers[i]
			placed := heard.vitals.life != s.vitals.life
			look, typing, loadout := s.player.look, s.player.typing, s.loadout
			soldier_take_served(s, heard)
			s.player.look = look
			s.player.typing = typing
			s.loadout = loadout
			// my own half too when placed, or while paused: the server's soldier is the one
			// the pause holds, a little behind where mine had got to, and the game goes on
			// from it for everyone alike
			_, paused := g.round.phase.(game.Paused)
			if placed || paused {
				soldier_take_owned(g.resources.animations, s, heard)
			} else if heard.vitals.dead {
				// dead, my hands are the server's too, as everyone else's are (soldier_apply)
				s.arsenal.primary = heard.arsenal.primary
				s.arsenal.fired = false
			}
			// A loadout picked while dead can reach the server after it has already
			// respawned me with the previous one: my choice arms this new life, and the
			// next client state carries it to the server as well
			if placed && game.weapon_is_primary(loadout.primary) && game.weapon_is_secondary(loadout.secondary) &&
			   (s.arsenal.primary.weapon != loadout.primary || s.arsenal.secondary.weapon != loadout.secondary) {
				game.soldier_arm(&g.resources, s, loadout.primary, loadout.secondary)
			}
		}
	}
	for i in 0 ..< game.MAX_THINGS {
		t := &w.things[i]
		if frame.thing_word[i] == .Gone && t.kind != .None {
			game.thing_kill(t)
		} else if frame.thing_word[i] == .State {
			thing_apply(t, &frame.things[i])
		}
	}
}

// Soldier `i` as its word in `frame` has it, stepped on `steps` ticks on its last keys
// to where the tick on show wants it. The correction goes to the picture, to be shown
// over a little while; a placing, or a jump too far to be a correction, shows at once.
// A dead one takes the served half and its hands alone, as the original never corrects
// a corpse: its body is the corpse here, started from the served vitals.death, and its
// place the corpse's head.
@(private = "file")
soldier_apply :: proc(c: ^Client_Stream, g: ^game.Game, id: game.Soldier_Id, frame: ^Snap_Frame, steps: int, scratch: ^game.Tick_Output) {
	w := &g.world
	s := &w.soldiers[id]
	heard := &frame.soldiers[id]
	placed := heard.vitals.life != s.vitals.life
	before := s.body.pos
	soldier_take_served(s, heard)
	s.remote = true
	if heard.vitals.dead {
		// but its hands are the server's: the kill let the gun go (a dropped gun now, flying
		// on its own), and no shot goes off from a corpse
		s.arsenal.primary = heard.arsenal.primary
		s.arsenal.fired = false
		c.blend[id] = {}
		c.blend_vel[id] = {}
		return
	}
	soldier_take_owned(g.resources.animations, s, heard)
	steps_left := min(steps, STREAM_STEPS_MAX)
	if game.round_standing(&g.round) do steps_left = 0 // the world stands, paused or between rounds: so does the word
	asked := sa.len(w.things_asked)
	for _ in 0 ..< steps_left {
		game.clear_output(scratch) // what the steps would say is said by nobody
		game.soldier_update(w, &g.resources, id, game.soldier_last_command(s, false), nil, scratch)
	}
	sa.resize(&w.things_asked, asked) // nor asked of the things (a parachute steered), as the C game's scratch mail isn't read
	jump := before - s.body.pos
	c.blend[id] = {} if placed else c.blend[id] + jump
	if placed || utils.length(c.blend[id]) > STREAM_SNAP_DISTANCE {
		c.blend[id] = {}
		c.blend_vel[id] = {}
	}
	if !placed do c.stats.correction += utils.length(jump)
}

// A soldier's rope as its Rope word has it: the rest keeps stepping, but the rope is the
// owner's, always fresh.
@(private = "file")
rope_apply :: proc(c: ^Client_Stream, g: ^game.Game, id: game.Soldier_Id, frame: ^Snap_Frame) {
	s := &g.world.soldiers[id]
	fields_copy(ROPE_FIELDS, &s.rope, &frame.soldiers[id].rope)
}

// Every other soldier from its newest word no later than the tick on show, stepped on
// to there, so a word that came late moves nothing that stepping had right; one with no
// newer word keeps stepping as it is. A rope held back from the full state still comes,
// fresh, and is laid over the stepped soldier.
@(private = "file")
soldiers_apply :: proc(c: ^Client_Stream, g: ^game.Game, me: game.Soldier_Id, v: u32) {
	scratch := new(game.Tick_Output, context.temp_allocator)
	for i in 0 ..< game.MAX_PLAYERS {
		id := game.Soldier_Id(i)
		if id == me do continue
		// the newest full state, stepped on to the view
		for t := min(v, c.newest); t > c.word_applied[i] && c.newest - t < STREAM_RING; t -= 1 {
			frame := &c.snaps[t % STREAM_RING]
			if frame.tick != t || frame.word[i] != .State do continue
			soldier_apply(c, g, id, frame, int(v - t), scratch)
			c.word_applied[i] = t
			break
		}
		// a rope newer than that full state, held back from it, still comes fresh
		for t := min(v, c.newest); t > c.word_applied[i] && c.newest - t < STREAM_RING; t -= 1 {
			frame := &c.snaps[t % STREAM_RING]
			if frame.tick != t || frame.word[i] != .Rope do continue
			rope_apply(c, g, id, frame)
			break
		}
	}
}

// Before the client's tick: the view clock set against the newest snapshot, keeping at
// least `interp` ticks behind it; the snapshot of the tick on show applied to the world
// (the round, the things, `me`'s served half, and its owned half only on a new life),
// or with none for that tick the newest before it not yet applied, so the server's word
// never waits on the clock; every other soldier taken from its newest word and stepped
// on to the tick on show, so a word that comes late moves nothing that stepping had
// right; and the server's words due by the tick into the world's inbox.
client_stream_begin_tick :: proc(c: ^Client_Stream, g: ^game.Game, me: game.Soldier_Id, interp: int) {
	if c.newest == 0 do return // nothing heard yet: the world stands as the round left it
	interp_set(c, interp)
	view_clock_step(c, &g.world)
	v := g.world.tick
	frame_on_show_apply(c, g, me, v)
	soldiers_apply(c, g, me, v)
	wire_pending_apply(&c.pending, &g.world, v)
	c.event_last = c.pending.received // what is held here need not come again
}

// How far the view keeps behind the newest snapshot: `interp` at least, the player's
// floor, and more for a while after late snapshots, settling a tick closer once they
// have been on time long enough.
@(private = "file")
interp_set :: proc(c: ^Client_Stream, interp: int) {
	floor := clamp(interp, 0, STREAM_INTERP_MAX)
	c.interp = max(c.interp, floor)
	if c.interp > floor && c.newest - c.late_tick > STREAM_INTERP_SETTLE { // quiet long enough: a tick closer
		c.interp -= 1
		c.late_tick = c.newest
	}
}

// The view clock: the tick the world shows. The frames in hand are the newest's tick less
// the view's; the view wants `interp` of them at the leanest moment of each window. Far
// off, it jumps; else at a window's end it is nudged a tick back when it ran short, or
// forward by what it never needed, with a frame or so of slack so that a line whose
// jitter is about a tick is not nudged to and fro. Each nudge is a frame shown twice or
// passed over, smoothed as a correction is. A demo playing passes the clock over: the
// tick shown is the one it showed.
@(private = "file")
view_clock_step :: proc(c: ^Client_Stream, w: ^game.World) {
	if c.view_at != 0 {
		w.tick = c.view_at
		c.view_at = 0
		return
	}
	level := i32(c.newest) - i32(w.tick)
	if level > STREAM_VIEW_SNAP + i32(c.interp) || level < -STREAM_VIEW_SNAP {
		w.tick = c.newest - u32(c.interp) if c.newest > u32(c.interp) else 0
		level = i32(c.interp)
		c.window = 0
		c.stats.resyncs += 1
	}
	if c.window <= 0 {
		c.level_min = level
		c.window = STREAM_VIEW_WINDOW
		return
	}
	c.level_min = min(c.level_min, level)
	c.window -= 1
	if c.window != 0 do return
	if c.level_min < i32(c.interp) {
		w.tick -= 1
		c.stats.held += 1
	} else if c.level_min >= i32(c.interp) + STREAM_VIEW_SLACK {
		ahead := u32(c.level_min - i32(c.interp))
		w.tick += ahead
		c.stats.skipped += ahead
	}
}

// The frame of tick `v` onto the world; with none for it (lost, late, or the view ahead
// of the line after the server stood still a while), the newest before it not yet
// applied, so the server's word of me, the round and the things (a placing, a death, a
// capture) waits on the line and not on the clock, as everyone else's word does.
@(private = "file")
frame_on_show_apply :: proc(c: ^Client_Stream, g: ^game.Game, me: game.Soldier_Id, v: u32) {
	if c.snaps[v % STREAM_RING].tick != v && v > c.applied do c.stats.misses += 1
	for t := min(v, c.newest); t > c.applied && c.newest - t < STREAM_RING; t -= 1 {
		frame := &c.snaps[t % STREAM_RING]
		if frame.tick != t do continue
		frame_apply(c, g, me, frame)
		c.stats.applies += 1
		c.applied = t
		return
	}
}

// After the client's tick: its own decisions among the tick's events, for the server.
client_stream_collect :: proc(c: ^Client_Stream, g: ^game.Game, me: game.Soldier_Id) {
	wire_collect(&c.out, &g.output, g.world.tick - 1, me) // the tick just run
}

// Each frame: the offsets ease away, nine tenths of a correction gone `seconds` after
// it (none at all with 0). `dt` is the frame's seconds.
client_stream_smooth :: proc(c: ^Client_Stream, dt: f32, seconds: f32) {
	for i in 0 ..< game.MAX_PLAYERS {
		if seconds <= 0 {
			c.blend[i] = {}
			c.blend_vel[i] = {}
			continue
		}
		// A critically damped spring, in closed form so any frame's dt is exact: from an
		// offset x and a closing speed v, x(t) = (x + (v + wx) t) e^-wt. With w = 3.89 /
		// over, an offset at rest is nine tenths gone after `over`.
		w := 3.89 / seconds
		decay := math.exp(-w * dt)
		x, v := c.blend[i], c.blend_vel[i]
		b := v + x * w
		c.blend[i] = (x + b * dt) * decay
		c.blend_vel[i] = (v - b * (w * dt)) * decay
		if utils.length(c.blend[i]) < 0.05 && utils.length(c.blend_vel[i]) < 1.0 {
			c.blend[i] = {}
			c.blend_vel[i] = {}
		}
	}
}

// The client's state, its soldier `me` as it stands and its decisions pending, into
// `buf`: the bytes, or nothing.
client_stream_state :: proc(c: ^Client_Stream, me: ^game.Soldier, buf: []u8) -> []u8 {
	seq := c.seq + 1
	base: ^game.Soldier
	base_seq: u32
	if c.server_ack != 0 && seq - c.server_ack <= STREAM_WHOLE_AFTER && c.own_seq[c.server_ack % STREAM_RING] == c.server_ack {
		base = &c.own[c.server_ack % STREAM_RING]
		base_seq = c.server_ack
	}

	b := buffer_writer(buf)
	kind := Msg_Kind.Client_State
	m := Msg_Client_State{round = c.round, seq = seq, base = base_seq, ack = c.newest, event_ack = c.event_last, life = me.vitals.life, owned = me^, typing = me.player.typing}
	msg_kind(&b, &kind)
	msg_client_state_header(&b, &m.header)
	msg_client_state_body(&b, &m, base)
	wire_write(&b, &c.out, c.event_ack, nil, WIRE_PER_PACKET)
	if !buffer_ok(&b) do return nil

	c.own[seq % STREAM_RING] = me^
	c.own_seq[seq % STREAM_RING] = seq
	c.seq = seq
	return buffer_written(&b)
}

// Nothing heard of the soldier in `slot` for STREAM_RELEASE_TICKS of snapshots.
client_stream_quiet :: proc(c: ^Client_Stream, slot: game.Soldier_Id) -> bool {
	return c.last_word[slot] == 0 || c.newest - c.last_word[slot] > STREAM_RELEASE_TICKS
}
