#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <zombieplague>

#define PLUGIN "Combo Zombie"
#define VERSION "1.0"
#define AUTHOR "NST"

new damage_player[33] = {0,...}
new time_show_set[33] = {0,...}
new spr_current[33] = {0,...}
new iconstatus, time_show = 2
new time_game, ghost_count_check

public plugin_init() 
{
	register_plugin(PLUGIN, VERSION, AUTHOR)
	
	register_event("TextMsg", "eRestart", "a", "2&#Game_C", "2&#Game_w")
	register_event("SendAudio", "eEndRound", "a", "2&%!MRAD_terwin", "2&%!MRAD_ctwin", "2&%!MRAD_rounddraw")
	register_event("RoundTime", "eNewRound", "bc")
	
	register_forward(FM_PlayerPreThink,"check_spr")
	iconstatus = get_user_msgid("StatusIcon")
	
}

public client_damage(attacker,victim,damage,wpnindex,hitplace,TA)
{
	if (attacker == victim || zp_get_user_zombie(attacker)) return PLUGIN_HANDLED
	
	new damage_fire
	new health_old = get_user_health(victim)+damage
	if (damage <= health_old) damage_fire = damage
	else damage_fire = health_old
	
	new damage_old = damage_player[attacker]
	new damage_new = damage_player[attacker] + damage_fire
	new aaaa_new = get_aaaa(damage_new)
	new aaaa_old = get_aaaa(damage_old)
	new aaa_new = get_aaa(damage_new)
	new aaa_old = get_aaa(damage_old)
	
	if (aaaa_new > aaaa_old)
	{
		show_spr(attacker, 6)
		update_frags(attacker, 1)
		client_cmd(attacker,"spk misc/zombie/damage_1000")
	}
	if (aaa_new != aaa_old) show_spr2(attacker, aaa_new)
	damage_player[attacker] = damage_new
	
	//client_print(attacker, print_chat, "%i - %i", damage_new, spr_current[attacker])
	
	return PLUGIN_CONTINUE
}
public zp_user_infected_pre(id, infector)
{
	if (infector)
	{
		show_spr(infector, 8)
		hide_spr2(id)
		client_cmd(infector,"spk misc/zombie/invader")
		//client_print(0, print_chat, "vic %i - kill %i - spr %i", id, infector, damage_player[infector])
	}
	
	return PLUGIN_CONTINUE
}

public client_death(killer, victim, wpnindex, hitplace, TK, id)
{
	
	if (!zp_get_user_zombie(killer) && zp_get_user_zombie(victim))
	{
		hide_spr2(killer)
		hide_spr(killer, 6)
		show_spr(killer, 7)
		client_cmd(killer,"spk misc/zombie/ghost_shot")

	}
	
	return PLUGIN_CONTINUE
}
public show_spr2(id, num)
{
	hide_spr2(id)
	if (spr_current[id] == 6)
	{
		hide_spr(id, 6)
		message_begin(MSG_ONE,iconstatus,{0,0,0},id);
		write_byte(1); // status (0=hide, 1=show, 2=flash)
		write_string(get_sprname(6)); // sprite name
		message_end();
	}
	
	new spr1, spr2
	if (num >= 5)
	{
		spr1 = 1
		spr2 = num-5
	}
	else
	{
		spr1 = 0
		spr2 = num
	}

	// Show Spr
	if (spr1 > 0) show_spr(id, 5)
	if (spr2 > 0) show_spr(id, spr2)


	return PLUGIN_CONTINUE
} 

public show_spr(id, idspr)
{
	if (idspr > 5)
	{
		new sec_c = get_systime()
		time_show_set[id] = sec_c
	
		hide_spr(id, spr_current[id])
		spr_current[id] = idspr
	}
		
	new spr_name[33]
	spr_name = get_sprname(idspr)
		
	if(!(pev(id,pev_button) & FL_ONGROUND))
	{    
		message_begin(MSG_ONE,iconstatus,{0,0,0},id);
		write_byte(1); // status (0=hide, 1=show, 2=flash)
		write_string(spr_name); // sprite name
		message_end();
	}

	return PLUGIN_CONTINUE
} 

public hide_spr2(id)
{
	for (new i = 1; i <= 5; i++)
	{
		new spr_name[33]
		spr_name = get_sprname(i)
		
		if(!(pev(id,pev_button) & FL_ONGROUND))
		{    
			message_begin(MSG_ONE,iconstatus,{0,0,0},id);
			write_byte(0); // status (0=hide, 1=show, 2=flash)
			write_string(spr_name); // sprite name
			message_end();
		}
	}

	return PLUGIN_CONTINUE
}
public hide_spr(id, idspr)
{
	if (idspr > 0)
	{
		new spr_name[33]
		spr_name = get_sprname(idspr)
		
		if(!(pev(id,pev_button) & FL_ONGROUND))
		{    
			message_begin(MSG_ONE,iconstatus,{0,0,0},id);
			write_byte(0); // status (0=hide, 1=show, 2=flash)
			write_string(spr_name); // sprite name
			message_end();
		}
		spr_current[id] = 0
	}
	
	return PLUGIN_CONTINUE
}  
public check_spr(id)
{
	if (!is_user_alive(id) || zp_get_user_zombie(id)) hide_spr2(id)
	new sec_c = get_systime()
	
	// Ghost Count
	new zp_delay_cvar = get_cvar_num("zp_delay")
	new ghost_count = (zp_delay_cvar+2) - (sec_c - time_game)
	if (ghost_count <= 10 && ghost_count > 0 && ghost_count != ghost_count_check)
	{
		client_cmd(0,"spk misc/zombie/Ghost_Count_%i", ghost_count)
		ghost_count_check = ghost_count
	}
	//client_print(0, print_chat, "%i", zp_delay_cvar)
	
	
	// Hide Spr
	new time_check = sec_c - time_show_set[id]
	if (time_check>time_show)
	{
		for (new i = 6; i <= 8; i++)
		{
			hide_spr(id, i)
		}
	}

	return PLUGIN_CONTINUE
}  

public eNewRound(id)
{
	time_game = get_systime()
	for (new i = 0; i < 33; i++)
	{
		damage_player[i] = 0
	}
}
public eRestart(id)
{
	eEndRound(id)
}
public eEndRound(id)
{
	//show_victims(id)
}


get_sprname(idspr)
{
	new spr_name[33]
	if (idspr==1) spr_name = "damage_100"
	if (idspr==2) spr_name = "damage_200"
	if (idspr==3) spr_name = "damage_300"
	if (idspr==4) spr_name = "damage_400"
	if (idspr==5) spr_name = "damage_500"
	if (idspr==6) spr_name = "damage_1000"
	if (idspr==7) spr_name = "ghost_shot"
	if (idspr==8) spr_name = "invader"

	return spr_name
}

get_aaa(num)
{
	new aaa, aa
	if (num >= 100)
	{
		if (num >= 1000) num = num % 1000
		aa = num % 100
		aaa = (num - aa)/100
	}
	else aaa = 0
	
	return aaa
}
get_aaaa(num)
{
	new aaa,aaaa
	if (num >= 1000)
	{
		if (num >= 10000) num = num % 10000
		aaa = num % 1000
		aaaa = (num - aaa)/1000
	}
	else aaaa = 0
	
	return aaaa
}

update_frags(player, num)
{
	set_pev(player, pev_frags, float(pev(player, pev_frags) + num))
}
/* AMXX-Studio Notes - DO NOT MODIFY BELOW HERE
*{\\ rtf1\\ ansi\\ deff0{\\ fonttbl{\\ f0\\ fnil Tahoma;}}\n\\ viewkind4\\ uc1\\ pard\\ lang1045\\ f0\\ fs16 \n\\ par }
*/
