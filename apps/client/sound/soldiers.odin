package sound

import sim "../../../core/game"
import res "../../../core/resources"

// Each soldier against how it was the tick before: the sounds its animations and its
// weapon make (the play sites of Sprites.pas and Control.pas), and its own voices kept
// up or let go of.

@(private = "file", rodata)
RELOAD_SOUNDS := #partial [res.Weapon]string {
	.Desert_Eagles = "deserteagle-reload.wav",
	.MP5           = "mp5-reload.wav",
	.AK74          = "ak74-reload.wav",
	.Steyr_AUG     = "steyraug-reload.wav",
	.Ruger77       = "ruger77-reload.wav",
	.M79           = "m79-reload.wav",
	.Barrett       = "barretm82-reload.wav",
	.Minimi        = "m249-reload.wav",
	.Minigun       = "minigun-reload.wav",
	.USSOCOM       = "colt1911-reload.wav",
}

// The sound of the weapon being drawn; any other, "changeweapon.wav".
@(private = "file", rodata)
DRAW_SOUNDS := #partial [res.Weapon]string {
	.USSOCOM  = "changespin.wav",
	.Knife    = "knife.wav",
	.Chainsaw = "chainsaw-d.wav",
}

// Hard ground's steps, then soft ground's (the map's `steps`), four of each.
@(private = "file", rodata)
STEPS := [2][4]string {
	{"step.wav", "step2.wav", "step3.wav", "step4.wav"},
	{"step5.wav", "step6.wav", "step7.wav", "step8.wav"},
}

soldier_sounds :: proc(s: ^Sound, game: ^sim.Game, id: sim.Soldier_Id) {
	now := &game.world.soldiers[id]
	was := s.before[id]
	s.before[id] = now^
	voices := &s.reserved[id]
	if !now.active || now.vitals.dead {
		if was.active && !was.vitals.dead {
			for &r in voices do reserved_stop(s, &r)
		}
		return
	}
	fresh := !was.active || was.vitals.dead // a new life: nothing to compare with
	at := now.body.pos
	buttons := now.controls.buttons
	weapon := now.arsenal.primary
	tick := game.world.tick
	body, legs := now.pose.body, now.pose.legs
	body_was, legs_was := was.pose.body, was.pose.legs

	// jets: the rocket loop while jetting, except during a jet-assisted backflip
	backflip :=
		.Jet in buttons &&
		((legs.id == .Jump_Side && ((now.body.direction == -1 && .Right in buttons) || (now.body.direction == 1 && .Left in buttons))) ||
				(legs.id == .Roll_Back && .Jump in buttons))
	if !backflip {
		if .Jet in buttons && now.body.jet_fuel > 0 && now.gear == .Jets {
			reserved_play(s, &voices[.Jets], "rocketz.wav", at)
		} else {
			reserved_stop(s, &voices[.Jets])
		}
	}

	// the rope: its throw's sound a second in, or as it lands — not on every press, so a
	// quick throw and retract stays quiet
	if now.rope.phase == .Throwing {
		if was.rope.phase != .Throwing {
			s.rope_ticks[id] = 1
		} else if s.rope_ticks[id] < sim.TICK_RATE {
			s.rope_ticks[id] += 1
			if s.rope_ticks[id] == sim.TICK_RATE do play_at(s, "rope-sound.mp3", at)
		}
	} else if now.rope.phase == .Attached && was.rope.phase == .Throwing {
		play_at(s, "rope-sound.mp3", at) // it landed
	}

	// the chainsaw: its idle rattle every 15 ticks, the cutting loop while the trigger is held
	fire := .Fire in buttons && now.vitals.cease_fire < 0
	if weapon.weapon == .Chainsaw {
		if tick % 15 == 0 {
			if weapon.ammo == 0 {
				reserved_play(s, &voices[.Gattling], "chainsaw-o.wav", at)
			} else {
				play_at(s, "chainsaw-m.wav", at)
			}
		}
		if .Fire in buttons && weapon.ammo > 0 do reserved_play(s, &voices[.Gattling], "chainsaw-r.wav", at)
	}

	// wind-ups: the first tick of one shows as the start-up count stepping down from full
	firing_allowed :=
		(weapon.weapon == .Chainsaw || !one_of(body.id, {.Roll, .Roll_Back, .Melee, .Change})) &&
		(body.id != .Hands_Up_Aim || body.frame == 11)
	if firing_allowed && !fresh && was.arsenal.primary.weapon == weapon.weapon {
		startup := game.resources.weapons[weapon.weapon].stats.start_up_time
		law_ready :=
			now.body.on_ground &&
			(one_of(legs.id, {.Crouch_Run, .Crouch_Run_Back}) || (legs.id == .Crouch && legs.frame > 13) || (legs.id == .Prone && legs.frame > 23))
		if fire {
			if startup > 0 && was.arsenal.primary.startup_count == startup && weapon.startup_count == startup - 1 {
				reserved_stop(s, &voices[.Gattling2])
				#partial switch weapon.weapon {
				case .Barrett: reserved_play(s, &voices[.Gattling], "law-start.wav", at)
				case .Minigun: reserved_play(s, &voices[.Gattling], "minigun-start.wav", at)
				case .LAW:     if law_ready do reserved_play(s, &voices[.Gattling], "law-start.wav", at)
				}
			}
		} else {
			reserved_stop(s, &voices[.Gattling])
			if startup > 0 && was.arsenal.primary.startup_count < startup && weapon.startup_count == startup {
				if weapon.weapon == .Minigun {
					reserved_play(s, &voices[.Gattling2], "minigun-end.wav", at)
				} else if weapon.weapon == .LAW && law_ready {
					reserved_play(s, &voices[.Gattling2], "law-end.wav", at)
				}
			}
		}
	} else if firing_allowed && !fire {
		reserved_stop(s, &voices[.Gattling])
	}

	// reloading: the clip's sound starts with the reload and pauses while the soldier
	// rolls, changes weapons or throws a grenade
	if weapon.ammo == 0 {
		was_weapon := was.arsenal.primary
		started := fresh || was_weapon.ammo != 0 || was_weapon.weapon != weapon.weapon || weapon.reload_count > was_weapon.reload_count
		if started do reserved_play(s, &voices[.Reload], RELOAD_SOUNDS[weapon.weapon], at)
		busy := one_of(body.id, {.Roll, .Roll_Back, .Melee, .Change, .Throw, .Throw_Weapon})
		if weapon.weapon == .Chainsaw || !busy do reserved_pause(s, &voices[.Reload], false)
	}
	if !fresh {
		if began(body_was, body, .Change) || began(body_was, body, .Throw) do reserved_pause(s, &voices[.Reload], true)
		if began(body_was, body, .Throw_Weapon) do reserved_stop(s, &voices[.Reload])
	}
	if crossed(body_was, body, .Reload, 7) do reserved_play(s, &voices[.Reload], "spas12-reload.wav", at)

	// the weapon change: the sound of the one being drawn; and a gun thrown
	if crossed(body_was, body, .Change, 2) {
		name := DRAW_SOUNDS[now.arsenal.secondary.weapon]
		play_at(s, name if name != "" else "changeweapon.wav", at)
	}
	if crossed(body_was, body, .Throw_Weapon, 2) do play_at(s, "throwgun.wav", at)

	// melee: a knife's stab or a rifle's butt
	if crossed(body_was, body, .Punch, 11) && weapon.weapon == .Knife do play_at(s, "slash.wav", at)
	if crossed(body_was, body, .Melee, 12) do play_at(s, "slash.wav", at)

	// the grenade's pin, from about where the hand is
	if crossed(body_was, body, .Throw, 15) && now.arsenal.grenades > 0 && now.vitals.cease_fire < 0 {
		play_at(s, "grenade-pullout.wav", at - {0, 2})
	}

	if fresh do return

	// the antics (the IDLE block of Control.pas): the tobacco's "stuff" as the chew steps
	// over its 17th frame, the match struck as the cigar's ninth passes with the cigar in
	// the mouth, a victory's roar, the piss, the mercy's plea (and the minigun's spin-up
	// with it), and at its 20th frame the blade, the saw or the bare hand on the head, on
	// the gattling voice as the original has them
	antics := &now.antics
	if crossed(body_was, body, .Smoke, 17) && antics.idle_antic == sim.ANTIC_TOBACCO do play_at(s, "stuff.wav", at)
	if crossed(body_was, body, .Cigar, 9) && antics.cigar == 5 do play_at(s, "match.wav", at)
	if began(body_was, body, .Victory) do play_at(s, "roar.wav", at)
	if began(body_was, body, .Piss) do play_at(s, "piss.wav", at)
	mercy_now := one_of(body.id, {.Mercy, .Mercy2})
	mercy_then := one_of(body_was.id, {.Mercy, .Mercy2})
	if mercy_now && !mercy_then {
		play_at(s, "mercy.wav", at)
		if weapon.weapon == .Minigun do play_at(s, "minigun-start.wav", at)
	}
	if mercy_now && mercy_then && crossed(body_was, body, body.id, 20) {
		#partial switch weapon.weapon {
		case .Knife:    reserved_play(s, &voices[.Gattling], "slash.wav", at)
		case .Chainsaw: reserved_play(s, &voices[.Gattling], "chainsaw-r.wav", at)
		case .Punch:    reserved_play(s, &voices[.Gattling], "dead-hit.wav", at)
		}
	}

	// legs: going prone, standing up, rolling, jumping, crouching, stopping
	if legs.id == .Prone && !one_of(legs_was.id, {.Prone, .Prone_Move, .Get_Up}) do play_at(s, "goprone.wav", at)
	if began(legs_was, legs, .Get_Up) do play_at(s, "standup.wav", at)
	if one_of(legs.id, {.Roll, .Roll_Back}) && !one_of(legs_was.id, {.Roll, .Roll_Back}) {
		play_at(s, "roll.wav", at)
		reserved_pause(s, &voices[.Reload], true)
	}
	if one_of(legs.id, {.Jump, .Jump_Side}) && !one_of(legs_was.id, {.Jump, .Jump_Side}) && was.body.on_ground {
		play_at(s, "jump.wav", at)
	}
	if legs.id == .Crouch && !one_of(legs_was.id, {.Crouch, .Crouch_Run, .Crouch_Run_Back}) && now.body.on_ground {
		play_at(s, "crouch.wav", at)
	}
	if began(legs_was, legs, .Stand) && now.body.on_ground && .Left not_in buttons && .Right not_in buttons {
		play_at(s, "stop.wav", at)
	}

	// footsteps, while touching the ground
	if now.body.on_ground {
		running := one_of(legs.id, {.Run, .Run_Back})
		if running && (crossed(legs_was, legs, legs.id, 16) || crossed(legs_was, legs, legs.id, 32)) {
			polymap := game.world.polymap
			if polymap.weather == 1 {
				play_at(s, "water-step.wav", at)
			} else {
				play_at(s, pick(s, STEPS[0 if polymap.steps == 0 else 1][:]), at)
			}
		}
		crouching := one_of(legs.id, {.Crouch_Run, .Crouch_Run_Back})
		if crouching && (crossed(legs_was, legs, legs.id, 15) || crossed(legs_was, legs, legs.id, 1)) {
			if sim.rng_below(&s.rng, 2) == 0 {
				play_at(s, "crouch-move.wav", at)
			} else if sim.rng_below(&s.rng, 2) == 0 {
				play_at(s, "crouch-movel.wav", at)
			}
		}
		if crossed(legs_was, legs, .Prone_Move, 8) do play_at(s, "prone-move.wav", at)
	}

	// the sniper view (Control.pas): the scope as it begins and as it is back, and its
	// running while the aim distance moves, every 27 ticks
	aim, aim_was := now.aim.distance, was.aim.distance
	if aim_was >= sim.DEFAULT_AIM_DISTANCE && aim < sim.DEFAULT_AIM_DISTANCE {
		play_at(s, "scope.wav", at)
	} else if aim_was < sim.DEFAULT_AIM_DISTANCE && aim >= sim.DEFAULT_AIM_DISTANCE {
		play_at(s, "scope.wav" if weapon.weapon == .Barrett && weapon.fire_count == 0 else "scopeback.wav", at)
	}
	if aim != aim_was && tick % 27 == 0 do play_at(s, "scoperun.wav", at)

	// landing, by how fast the soldier was falling
	if now.body.on_ground && !was.body.on_ground {
		fall := abs(was.body.velocity.y)
		if fall > 2.2 && fall < 3.4 do play_at(s, "fall.wav", at)
		if fall > 3.5 do play_at(s, "fall-hard.wav", at)
	}
}

// Whether an animation went past `frame` between two ticks. A restart of the same
// animation (the frame going backwards) counts the frames after the wrap.
@(private = "file")
crossed :: proc(was, now: res.Animation_State, id: res.Animation_Id, frame: i32) -> bool {
	if now.id != id do return false
	if was.id != id do return now.frame >= frame && now.frame <= frame + 1
	if now.frame >= was.frame do return was.frame < frame && frame <= now.frame
	return frame > was.frame || frame <= now.frame
}

// Whether an animation started this tick.
@(private = "file")
began :: proc(was, now: res.Animation_State, id: res.Animation_Id) -> bool {
	return now.id == id && was.id != id
}

@(private = "file")
one_of :: proc(id: res.Animation_Id, ids: bit_set[res.Animation_Id]) -> bool {
	return id in ids
}
