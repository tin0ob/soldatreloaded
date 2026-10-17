package game

import sa "core:container/small_array"

import res "../resources"
import "../utils"

// What happened in a step, in the order it happened. The referee judges some of them
// (a hit, a suicide) into rulings; the client shows them all: the sparks, the sounds,
// the blood. Nothing in a step reads them back.

Event :: union {
	// for the referee, and the wire (the owner's decisions)
	Hit,
	Suicide,
	Shot_Fired,
	Gun_Thrown,
	Flag_Thrown,
	// for showing
	Fired,
	Bullet_Ended,
	Wall_Hit,
	Ricochet,
	Collider_Hit,
	Grenade_Bounce,
	Blood,
	Explosion,
	Thing_Hit,
	Polygon_Effect,
	Corpse_Landed,
	Antic,
	Flag_Drop,
	Shot_End,
	Rope_Cut,
}

MAX_EVENTS :: 256
MAX_RULINGS :: 256

// What a tick leaves behind: what happened, and what was decided.
Tick_Output :: struct {
	events:  sa.Small_Array(MAX_EVENTS, Event),
	rulings: sa.Small_Array(MAX_RULINGS, Ruling), // without authority, those heard from the server
	judged:  int, // the events judged so far
}

clear_output :: proc(out: ^Tick_Output) {
	out^ = {}
}

emit :: proc(out: ^Tick_Output, event: Event) {
	sa.push_back(&out.events, event)
}

// ---------------------------------------------------------------------------------
// For the referee

// A bullet, blast or blade met a soldier. An amount of 0 is a shove alone.
Hit :: struct {
	shooter:   Soldier_Id,
	target:    Soldier_Id,
	weapon:    res.Weapon,
	amount:    f32,
	part:      u8,         // the skeleton part hit; 0 for a blast
	pos:       utils.Vec2,
	push:      utils.Vec2, // the knockback
	impact:    utils.Vec2, // the blow a death gives the gun it lets go of
	spray:     bool,       // it also disturbs the target's aim
	distance:  f32,        // the bullet's flight, for the killer's readout
	airtime:   i32,
	ricochets: u8,
}

// The owner's decisions, which a client tells the server: every shot it fires, its gun
// thrown, its flag thrown. On the server they are its own soldiers' (the bots').
Shot_Fired :: struct {
	shot: Shot,
}

Gun_Thrown :: struct {
	drop: Gun_Drop,
}

Flag_Thrown :: struct {
	soldier: Soldier_Id,
}

Suicide :: struct {
	soldier: Soldier_Id,
}

// ---------------------------------------------------------------------------------
// For showing

Fired :: struct {
	soldier:  Soldier_Id,
	weapon:   res.Weapon,
	pos:      utils.Vec2,
	velocity: utils.Vec2,
}

Bullet_Ended :: struct {
	bullet: Bullet_Id,
	owner:  Soldier_Id,
	weapon: res.Weapon,
	pos:    utils.Vec2,
	impact: bool,
}

Wall_Hit :: struct {
	bullet:   Bullet_Id,
	weapon:   res.Weapon,
	pos:      utils.Vec2,
	velocity: utils.Vec2,
}

Ricochet :: struct {
	bullet:   Bullet_Id,
	pos:      utils.Vec2,
	velocity: utils.Vec2,
}

Collider_Hit :: struct {
	bullet:   Bullet_Id,
	pos:      utils.Vec2,
	velocity: utils.Vec2,
}

Grenade_Bounce :: struct {
	bullet: Bullet_Id,
	pos:    utils.Vec2,
}

Blood :: struct {
	target:    Soldier_Id,
	pos:       utils.Vec2,
	velocity:  utils.Vec2,
	bloodless: bool, // the hit's sound alone: a thrown knife in a teammate
}

Explosion :: struct {
	owner:    Soldier_Id,
	weapon:   res.Weapon,
	pos:      utils.Vec2,
	velocity: utils.Vec2, // the grenade's or rocket's as it went off, which throws the dirt back
	radius:   f32,
}

Thing_Hit :: struct {
	thing:    Thing_Kind,
	pos:      utils.Vec2,
	velocity: utils.Vec2,
	part:     u8, // the point of it that struck
}

Polygon_Effect :: struct {
	soldier: Soldier_Id,
	polygon: res.Polygon_Type,
	pos:     utils.Vec2,
	spark:   bool,
}

// A corpse struck the map hard enough to be heard.
Corpse_Landed :: struct {
	soldier:  Soldier_Id,
	pos:      utils.Vec2,
	fall:     f32,
	landings: u8,
}

Antic :: struct {
	soldier:  Soldier_Id,
	kind:     Antic_Kind,
	pos:      utils.Vec2,
	velocity: utils.Vec2,
	odds:     u8, // the piss: one in this many ticks shows a drop
	life:     u8, // how long the spark lives
}

Antic_Kind :: enum u8 {
	Spit,
	Cigar_Puff,
	Match,
	Cigar_Throw,
	Piss,
}

// A death let go of the flag its soldier carried, which lies where it fell.
Flag_Drop :: struct {
	soldier: Soldier_Id,
	flag:    Thing_Id,
	pos:     utils.Vec2,
}

// The server's word of where a shot ended, for the clients' own flights of it
// (bullet_shot_end): in a blast of `blast`, or with nil stopped in a body, `target`'s if
// told.
Shot_End :: struct {
	owner:  Soldier_Id,
	shot:   u32, // the owner's number for it
	weapon: res.Weapon,
	pos:    utils.Vec2,
	blast:  Maybe(Explosion_Kind),
	target: Maybe(Soldier_Id),
}

// A rope cut: by its owner's key press, a killing blow, or a bullet that crossed it.
// For the sparks alone; never leaves the machine that made it.
Rope_Cut :: struct {
	soldier: Soldier_Id,
	pos:     utils.Vec2,
}
