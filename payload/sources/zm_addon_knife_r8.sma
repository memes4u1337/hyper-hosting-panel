#include <amxmodx>
#include <fakemeta>
#include <fun>
#include <hamsandwich>

#define PLUGIN  "OLD ZOMBIE - Knife Menu"
#define VERSION "2.1-fastdl-fix"
#define AUTHOR  "BlackCat / OLD ZOMBIE edit"

#define ZV_MAIN          (1<<0)
#define ADMIN_KNIFE_FLAG ADMIN_MENU

// Natives already provided by this server build.
native zp_get_user_zombie(id)
native zv_get_user_flags(id)

enum
{
	KNIFE_NONE = 0,
	KNIFE_KATANA,
	KNIFE_LASER,
	KNIFE_VIP_SKULL,
	KNIFE_ADMIN_FIRE,
	KNIFE_ADMIN_WAR
}

new const KNIFE1_V_MODEL[] = "models/oldz_knife_r8/v_katana.mdl"
new const KNIFE1_P_MODEL[] = "models/oldz_knife_r8/p_katana.mdl"

new const KNIFE2_V_MODEL[] = "models/oldz_knife_r8/v_laser_green.mdl"
new const KNIFE2_P_MODEL[] = "models/oldz_knife_r8/p_laser_green.mdl"

new const KNIFE3_V_MODEL[] = "models/oldz_knife_r8/v_hammer_skull.mdl"
new const KNIFE3_P_MODEL[] = "models/oldz_knife_r8/p_hammer_skull.mdl"

new const KNIFE4_V_MODEL[] = "models/oldz_knife_r8/v_hammer_fire.mdl"
new const KNIFE4_P_MODEL[] = "models/oldz_knife_r8/p_hammer_fire.mdl"

new const KNIFE5_V_MODEL[] = "models/oldz_knife_r8/v_war_hammer_j.mdl"
new const KNIFE5_P_MODEL[] = "models/oldz_knife_r8/p_war_hammer_j.mdl"

new const g_snd_katana[][] =
{
	"oldz_knife_r8/katana_deploy.wav",
	"oldz_knife_r8/katana_hit.wav",
	"oldz_knife_r8/katanad_hit2.wav",
	"oldz_knife_r8/katana_hitwall.wav",
	"oldz_knife_r8/katana_slash.wav",
	"oldz_knife_r8/katana_stab.wav"
}

new const g_snd_laser[][] =
{
	"oldz_knife_r8/laser_sword_draw.wav",
	"oldz_knife_r8/laser_sword_hit1.wav",
	"oldz_knife_r8/laser_sword_hit2.wav",
	"oldz_knife_r8/laser_sword_hitwall.wav",
	"oldz_knife_r8/laser_sword_slash1.wav",
	"oldz_knife_r8/laser_sword_stab.wav"
}

new const g_snd_skull[][] =
{
	"oldz_knife_r8/hammer_draw.wav",
	"oldz_knife_r8/hammer_hit_01.wav",
	"oldz_knife_r8/hammer_hit_02.wav",
	"oldz_knife_r8/hammer_hitwall1.wav",
	"oldz_knife_r8/hammer_slash1.wav",
	"oldz_knife_r8/hammer_stab.wav"
}

new const g_snd_fire[][] =
{
	"oldz_knife_r8/hammer_axe_draw.wav",
	"oldz_knife_r8/hammer_hit_01.wav",
	"oldz_knife_r8/hammer_hit_02.wav",
	"oldz_knife_r8/hammer_hitwall1.wav",
	"oldz_knife_r8/hammer_axe_slash1.wav",
	"oldz_knife_r8/hammer_stab.wav"
}

new const g_snd_war[][] =
{
	"oldz_knife_r8/hammer_axe_draw.wav",
	"oldz_knife_r8/hammer_hit_01.wav",
	"oldz_knife_r8/hammer_hit_02.wav",
	"oldz_knife_r8/hammer_hitwall1.wav",
	"oldz_knife_r8/hammer_axe_slash1.wav",
	"oldz_knife_r8/hammer_stab.wav"
}

new g_selected_knife[33]
new g_cvar_speed[6]
new g_cvar_damage[6]
new g_cvar_knock[6]

public plugin_precache()
{
	precache_model(KNIFE1_V_MODEL)
	precache_model(KNIFE1_P_MODEL)
	precache_model(KNIFE2_V_MODEL)
	precache_model(KNIFE2_P_MODEL)
	precache_model(KNIFE3_V_MODEL)
	precache_model(KNIFE3_P_MODEL)
	precache_model(KNIFE4_V_MODEL)
	precache_model(KNIFE4_P_MODEL)
	precache_model(KNIFE5_V_MODEL)
	precache_model(KNIFE5_P_MODEL)

	for (new i = 0; i < sizeof g_snd_katana; i++) precache_sound(g_snd_katana[i])
	for (new i = 0; i < sizeof g_snd_laser; i++)  precache_sound(g_snd_laser[i])
	for (new i = 0; i < sizeof g_snd_skull; i++)  precache_sound(g_snd_skull[i])
	for (new i = 0; i < sizeof g_snd_fire; i++)   precache_sound(g_snd_fire[i])
	for (new i = 0; i < sizeof g_snd_war; i++)    precache_sound(g_snd_war[i])
}

public plugin_natives()
{
	// Compatibility with plugins that used the old knife addon natives.
	register_native("knife_0", "native_knife_reset", 1)
	register_native("zp_get_user_knife", "native_knife_get", 1)
	register_native("zp_set_user_knife", "native_knife_set", 1)
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)
	register_cvar("oldz_knife_version", VERSION, FCVAR_SERVER)

	register_clcmd("knife_zb", "cmd_knife_menu")
	register_clcmd("say /knife", "cmd_knife_menu")
	register_clcmd("say_team /knife", "cmd_knife_menu")
	register_clcmd("say /knives", "cmd_knife_menu")
	register_clcmd("say_team /knives", "cmd_knife_menu")

	register_event("CurWeapon", "event_cur_weapon", "be", "1=1")
	register_forward(FM_EmitSound, "fw_emit_sound")
	register_forward(FM_PlayerPreThink, "fw_player_prethink")
	RegisterHam(Ham_TakeDamage, "player", "fw_take_damage")

	// Original balance values, cleaned up and made stable.
	g_cvar_speed[KNIFE_KATANA] = register_cvar("oldz_knife1_speed", "275.0")
	g_cvar_damage[KNIFE_KATANA] = register_cvar("oldz_knife1_damage", "2.3")
	g_cvar_knock[KNIFE_KATANA] = register_cvar("oldz_knife1_knockback", "2.0")

	g_cvar_speed[KNIFE_LASER] = register_cvar("oldz_knife2_speed", "235.0")
	g_cvar_damage[KNIFE_LASER] = register_cvar("oldz_knife2_damage", "4.5")
	g_cvar_knock[KNIFE_LASER] = register_cvar("oldz_knife2_knockback", "3.5")

	g_cvar_speed[KNIFE_VIP_SKULL] = register_cvar("oldz_knife3_speed", "260.0")
	g_cvar_damage[KNIFE_VIP_SKULL] = register_cvar("oldz_knife3_damage", "9.9")
	g_cvar_knock[KNIFE_VIP_SKULL] = register_cvar("oldz_knife3_knockback", "2.5")

	g_cvar_speed[KNIFE_ADMIN_FIRE] = register_cvar("oldz_knife4_speed", "275.0")
	g_cvar_damage[KNIFE_ADMIN_FIRE] = register_cvar("oldz_knife4_damage", "10.4")
	g_cvar_knock[KNIFE_ADMIN_FIRE] = register_cvar("oldz_knife4_knockback", "6.0")

	g_cvar_speed[KNIFE_ADMIN_WAR] = register_cvar("oldz_knife5_speed", "290.0")
	g_cvar_damage[KNIFE_ADMIN_WAR] = register_cvar("oldz_knife5_damage", "11.4")
	g_cvar_knock[KNIFE_ADMIN_WAR] = register_cvar("oldz_knife5_knockback", "6.0")
}

public client_putinserver(id)
{
	g_selected_knife[id] = KNIFE_NONE
}

public client_disconnect(id)
{
	g_selected_knife[id] = KNIFE_NONE
}

public native_knife_reset(id)
{
	if (id >= 1 && id <= 32)
		g_selected_knife[id] = KNIFE_NONE

	return 1
}

public native_knife_get(id)
{
	if (id < 1 || id > 32)
		return KNIFE_NONE

	return g_selected_knife[id]
}

public native_knife_set(id, knife)
{
	if (id < 1 || id > 32)
		return 0

	if (knife < KNIFE_NONE || knife > KNIFE_ADMIN_WAR)
		return 0

	if (knife != KNIFE_NONE && !can_use_knife(id, knife))
		return 0

	g_selected_knife[id] = knife
	apply_knife(id)
	return 1
}

public cmd_knife_menu(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	show_knife_menu(id)
	return PLUGIN_HANDLED
}

show_knife_menu(id)
{
	new title[256]
	new vip_status[16], admin_status[16]

	if (is_vip(id))
		copy(vip_status, charsmax(vip_status), "ДОСТУП")
	else
		copy(vip_status, charsmax(vip_status), "НЕТ")

	if (is_admin(id))
		copy(admin_status, charsmax(admin_status), "ДОСТУП")
	else
		copy(admin_status, charsmax(admin_status), "НЕТ")

	formatex(title, charsmax(title),
		"\y==============================^n\r      OLD ZOMBIE \w| \yZM 4.3^n\y==============================^n^n\wМеню ножей^n\dVIP: \w%s \d| ADMIN: \w%s^n",
		vip_status, admin_status)

	new menu = menu_create(title, "knife_menu_handler")

	add_knife_item(menu, id, KNIFE_KATANA, "Катана", "", true)
	add_knife_item(menu, id, KNIFE_LASER, "Лазерный клинок", "", true)
	add_knife_item(menu, id, KNIFE_VIP_SKULL, "Skull Hammer", "VIP", can_use_knife(id, KNIFE_VIP_SKULL))
	add_knife_item(menu, id, KNIFE_ADMIN_FIRE, "Fire Hammer", "ADMIN", can_use_knife(id, KNIFE_ADMIN_FIRE))
	add_knife_item(menu, id, KNIFE_ADMIN_WAR, "War Hammer", "ADMIN", can_use_knife(id, KNIFE_ADMIN_WAR))

	menu_setprop(menu, MPROP_PERPAGE, 0)
	menu_setprop(menu, MPROP_EXITNAME, "\wВыход")
	menu_display(id, menu, 0)
}

stock add_knife_item(menu, id, knife, const name[], const access_name[], bool:allowed)
{
	new text[128], info[4]
	num_to_str(knife, info, charsmax(info))

	if (access_name[0])
	{
		if (g_selected_knife[id] == knife)
			formatex(text, charsmax(text), "\y%s \r[%s] \w[ВЫБРАН]", name, access_name)
		else if (allowed)
			formatex(text, charsmax(text), "\w%s \r[%s]", name, access_name)
		else
			formatex(text, charsmax(text), "\d%s [%s] [НЕТ ДОСТУПА]", name, access_name)
	}
	else
	{
		if (g_selected_knife[id] == knife)
			formatex(text, charsmax(text), "\y%s \w[ВЫБРАН]", name)
		else
			formatex(text, charsmax(text), "\w%s", name)
	}

	menu_additem(menu, text, info)
}

public knife_menu_handler(id, menu, item)
{
	if (item == MENU_EXIT)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}

	new access, callback, info[4], item_name[128]
	menu_item_getinfo(menu, item, access, info, charsmax(info), item_name, charsmax(item_name), callback)

	new knife = str_to_num(info)

	if (!can_use_knife(id, knife))
	{
		if (knife == KNIFE_VIP_SKULL)
			client_print(id, print_chat, "[OLD ZOMBIE | ZM 4.3] Skull Hammer доступен только VIP и администраторам.")
		else
			client_print(id, print_chat, "[OLD ZOMBIE | ZM 4.3] Этот нож доступен только администраторам.")

		menu_destroy(menu)
		show_knife_menu(id)
		return PLUGIN_HANDLED
	}

	g_selected_knife[id] = knife
	apply_knife(id)

	new knife_name[64]
	get_knife_name(knife, knife_name, charsmax(knife_name))
	client_print(id, print_chat, "[OLD ZOMBIE | ZM 4.3] Выбран нож: %s.", knife_name)

	menu_destroy(menu)
	return PLUGIN_HANDLED
}

public event_cur_weapon(id)
{
	if (!is_user_alive(id))
		return

	if (read_data(2) == CSW_KNIFE)
		apply_knife(id)
}

public fw_player_prethink(id)
{
	if (!is_user_alive(id) || zp_get_user_zombie(id))
		return FMRES_IGNORED

	if (get_user_weapon(id) != CSW_KNIFE)
		return FMRES_IGNORED

	new knife = g_selected_knife[id]
	if (knife == KNIFE_NONE || !can_use_knife(id, knife))
		return FMRES_IGNORED

	set_user_maxspeed(id, get_pcvar_float(g_cvar_speed[knife]))
	return FMRES_IGNORED
}

public fw_take_damage(victim, inflictor, attacker, Float:damage, damagebits)
{
	if (attacker < 1 || attacker > 32 || attacker == victim)
		return HAM_IGNORED

	if (!is_user_alive(attacker) || zp_get_user_zombie(attacker))
		return HAM_IGNORED

	if (get_user_weapon(attacker) != CSW_KNIFE)
		return HAM_IGNORED

	new knife = g_selected_knife[attacker]
	if (knife == KNIFE_NONE || !can_use_knife(attacker, knife))
		return HAM_IGNORED

	SetHamParamFloat(4, damage * get_pcvar_float(g_cvar_damage[knife]))

	if (is_user_alive(victim) && zp_get_user_zombie(victim))
		apply_knockback(victim, attacker, get_pcvar_float(g_cvar_knock[knife]))

	return HAM_IGNORED
}

public fw_emit_sound(id, channel, const sample[], Float:volume, Float:attn, flags, pitch)
{
	if (id < 1 || id > 32 || !is_user_connected(id))
		return FMRES_IGNORED

	if (!is_user_alive(id) || zp_get_user_zombie(id))
		return FMRES_IGNORED

	new knife = g_selected_knife[id]
	if (knife == KNIFE_NONE || !can_use_knife(id, knife))
		return FMRES_IGNORED

	if (contain(sample, "weapons/knife_") == -1)
		return FMRES_IGNORED

	new sound_index = -1

	if (contain(sample, "deploy") != -1)
		sound_index = 0
	else if (contain(sample, "hitwall") != -1)
		sound_index = 3
	else if (contain(sample, "hit") != -1)
		sound_index = random_num(1, 2)
	else if (contain(sample, "slash") != -1)
		sound_index = 4
	else if (contain(sample, "stab") != -1)
		sound_index = 5

	if (sound_index == -1)
		return FMRES_IGNORED

	emit_knife_sound(id, channel, knife, sound_index, volume, attn, flags, pitch)
	return FMRES_SUPERCEDE
}

stock apply_knife(id)
{
	if (!is_user_alive(id) || zp_get_user_zombie(id))
		return

	if (get_user_weapon(id) != CSW_KNIFE)
		return

	new knife = g_selected_knife[id]
	if (knife == KNIFE_NONE)
		return

	if (!can_use_knife(id, knife))
	{
		g_selected_knife[id] = KNIFE_NONE
		return
	}

	switch (knife)
	{
		case KNIFE_KATANA:
		{
			set_pev(id, pev_viewmodel2, KNIFE1_V_MODEL)
			set_pev(id, pev_weaponmodel2, KNIFE1_P_MODEL)
		}
		case KNIFE_LASER:
		{
			set_pev(id, pev_viewmodel2, KNIFE2_V_MODEL)
			set_pev(id, pev_weaponmodel2, KNIFE2_P_MODEL)
		}
		case KNIFE_VIP_SKULL:
		{
			set_pev(id, pev_viewmodel2, KNIFE3_V_MODEL)
			set_pev(id, pev_weaponmodel2, KNIFE3_P_MODEL)
		}
		case KNIFE_ADMIN_FIRE:
		{
			set_pev(id, pev_viewmodel2, KNIFE4_V_MODEL)
			set_pev(id, pev_weaponmodel2, KNIFE4_P_MODEL)
		}
		case KNIFE_ADMIN_WAR:
		{
			set_pev(id, pev_viewmodel2, KNIFE5_V_MODEL)
			set_pev(id, pev_weaponmodel2, KNIFE5_P_MODEL)
		}
	}

	set_user_maxspeed(id, get_pcvar_float(g_cvar_speed[knife]))
}

stock emit_knife_sound(id, channel, knife, sound_index, Float:volume, Float:attn, flags, pitch)
{
	switch (knife)
	{
		case KNIFE_KATANA:
			engfunc(EngFunc_EmitSound, id, channel, g_snd_katana[sound_index], volume, attn, flags, pitch)
		case KNIFE_LASER:
			engfunc(EngFunc_EmitSound, id, channel, g_snd_laser[sound_index], volume, attn, flags, pitch)
		case KNIFE_VIP_SKULL:
			engfunc(EngFunc_EmitSound, id, channel, g_snd_skull[sound_index], volume, attn, flags, pitch)
		case KNIFE_ADMIN_FIRE:
			engfunc(EngFunc_EmitSound, id, channel, g_snd_fire[sound_index], volume, attn, flags, pitch)
		case KNIFE_ADMIN_WAR:
			engfunc(EngFunc_EmitSound, id, channel, g_snd_war[sound_index], volume, attn, flags, pitch)
	}
}

stock apply_knockback(victim, attacker, Float:multiplier)
{
	new Float:victim_origin[3], Float:attacker_origin[3]
	new Float:velocity[3]

	pev(victim, pev_origin, victim_origin)
	pev(attacker, pev_origin, attacker_origin)
	pev(victim, pev_velocity, velocity)

	new Float:dx = victim_origin[0] - attacker_origin[0]
	new Float:dy = victim_origin[1] - attacker_origin[1]
	new Float:length = floatsqroot(dx * dx + dy * dy)

	if (length < 1.0)
		return

	dx /= length
	dy /= length

	new Float:force = 220.0 * multiplier
	velocity[0] += dx * force
	velocity[1] += dy * force
	velocity[2] += 80.0

	set_pev(victim, pev_velocity, velocity)
}

stock bool:is_vip(id)
{
	return (zv_get_user_flags(id) & ZV_MAIN) != 0
}

stock bool:is_admin(id)
{
	return (get_user_flags(id) & ADMIN_KNIFE_FLAG) != 0
}

stock bool:can_use_knife(id, knife)
{
	if (knife == KNIFE_KATANA || knife == KNIFE_LASER)
		return true

	if (knife == KNIFE_VIP_SKULL)
		return is_vip(id) || is_admin(id)

	if (knife == KNIFE_ADMIN_FIRE || knife == KNIFE_ADMIN_WAR)
		return is_admin(id)

	return false
}

stock get_knife_name(knife, name[], len)
{
	switch (knife)
	{
		case KNIFE_KATANA: copy(name, len, "Катана")
		case KNIFE_LASER: copy(name, len, "Лазерный клинок")
		case KNIFE_VIP_SKULL: copy(name, len, "Skull Hammer [VIP]")
		case KNIFE_ADMIN_FIRE: copy(name, len, "Fire Hammer [ADMIN]")
		case KNIFE_ADMIN_WAR: copy(name, len, "War Hammer [ADMIN]")
		default: copy(name, len, "Стандартный нож")
	}
}
