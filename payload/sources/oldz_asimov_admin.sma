#include <amxmodx>
#include <fakemeta>
#include <cstrike>
#include <fun>
#include <engine>
#include <hamsandwich>

native oldz_has_zp_admin_access(id)


#define 	weapon_awp 			18
#define 	IMPULSE 			8678

#define m_pActiveItem 373

const PRIMARY_WEAPONS_BIT_SUM = (1<<CSW_SCOUT)|(1<<CSW_XM1014)|(1<<CSW_MAC10)|(1<<CSW_AUG)|(1<<CSW_UMP45)|(1<<CSW_SG550)|(1<<CSW_GALIL)|(1<<CSW_FAMAS)|(1<<CSW_AWP)|(1<<CSW_MP5NAVY)|(1<<CSW_M249)|(1<<CSW_M3)|(1<<CSW_M4A1)|(1<<CSW_TMP)|(1<<CSW_G3SG1)|(1<<CSW_SG552)|(1<<CSW_AK47)|(1<<CSW_P90);
const OFFSET_LINUX = 5;
const MsgId_ScreenFade = 98;

new AWP_V_MODEL[] =	{	"models/oldz_w3/asimov_v.mdl"	};
new AWP_P_MODEL[] =	{	"models/oldz_w3/asimov_p.mdl"	};
new AWP_W_MODEL[] =	{	"models/oldz_w3/asimov_w.mdl"	};

new AsimovSwitch[33];
new ButtonTimeReload[33];

new bool:IsUserHaveAwp[33];

public plugin_init()
{
	register_plugin("OLD ZOMBIE - AWP Asiimov ADMIN", "2.0", "OLD ZOMBIE");
	
	register_clcmd("Asimov", "GetAsimov");
	register_clcmd("oldz_give_asimov", "GetAsimov");
	register_clcmd("drop","cmdDrop");
	
	RegisterHam(Ham_Killed, "player", "fw_PlayerKilled");
	RegisterHam(Ham_Item_AddToPlayer, "weapon_awp", "fw_Awp_AddToPlayer");
	RegisterHam(Ham_TraceAttack, "player", "Ham_TraceAttack_Player", false);
	RegisterHam(Ham_Item_Deploy, "weapon_awp", "HamHook_Item_Deploy", true);
	register_forward(FM_SetModel, "Fakemeta_SetModel");
	register_touch("weaponbox", "player", "OnWeaponboxTouch");
	register_event("HLTV", "event_round_start", "a", "1=0", "2=0")
}

public client_putinserver(id)
{
	IsUserHaveAwp[id] = false;
	AsimovSwitch[id] = 1;
	ButtonTimeReload[id] = 0;
}

public plugin_precache()
{
	precache_model(AWP_V_MODEL);
	precache_model(AWP_P_MODEL);
	precache_model(AWP_W_MODEL);
}

public event_round_start()
{
	for (new id; id <= 32; id++) IsUserHaveAwp[id] = false;
}

public cmdDrop(id) 
{
	if(IsUserHaveAwp[id]) 
	{
		new clip,ammo;
		new weapon = get_user_weapon(id,clip,ammo);
		if(weapon == CSW_AWP) 
		{
			IsUserHaveAwp[id] = false;
			return PLUGIN_HANDLED
		}
	}
	return PLUGIN_CONTINUE
}

public GetAsimov(id)
{
	if (!is_user_alive(id))
    {
        oldz_weapon_chat(id, "Оружие можно получить только когда вы живы.");
        return PLUGIN_HANDLED;
    }

    if (!oldz_is_admin(id))
    {
        oldz_weapon_chat(id, "AWP Asiimov доступна только администратору.");
        return PLUGIN_HANDLED;
    }

    drop_weapons(id, 1);
    IsUserHaveAwp[id] = true;
    give_item_ex2(id, "weapon_awp", 30, true, IMPULSE);
    oldz_weapon_chat(id, "Вы получили AWP Asiimov [ADMIN] - урон 40000.");
    return PLUGIN_HANDLED;
}

public fw_PlayerKilled(iVictim, iAttacker, shouldgib) IsUserHaveAwp[iVictim] = false;

public Ham_TraceAttack_Player(iVictim, iAttacker, Float:fDamage, Float:fDeriction[3], iTraceHandle, iBitDamage)
{
	if(!is_user_connected(iVictim) || !is_user_connected(iAttacker))
		return HAM_IGNORED;
		
	new iEntity = get_pdata_cbase(iAttacker, m_pActiveItem, OFFSET_LINUX);
	
	if(!pev_valid(iEntity))
		return HAM_IGNORED;
	
	new Impulse = pev(iEntity, pev_impulse);
	if(Impulse != IMPULSE)
		return HAM_IGNORED;
	
	if(cs_get_user_team(iVictim) != cs_get_user_team(iAttacker))
	{
		SetHamParamFloat(3, 40000.0);

		// Original second mode is preserved: it additionally freezes the target.
		if(AsimovSwitch[iAttacker] == 2)
			FreezePlayer(iVictim);
	}
	return HAM_IGNORED;
}

public client_PreThink(id)
{ 
    if(entity_get_int(id, EV_INT_button) & IN_USE) 
    { 
		new iEntity = get_pdata_cbase(id, m_pActiveItem, OFFSET_LINUX);
		if(pev_valid(iEntity) && pev(iEntity, pev_impulse) == IMPULSE && ButtonTimeReload[id] == 0)
		{
			switch(AsimovSwitch[id])
			{
				case 1:
				{
					AsimovSwitch[id] = 2;
					ButtonTimeReload[id] = 1;
					set_task(2.0, "ButtonReset", id + IMPULSE);
					client_print(id, print_center, "Вы переключились на режим заморозки!");
				}
				case 2:
				{
					AsimovSwitch[id] = 1;
					ButtonTimeReload[id] = 1;
					set_task(2.0, "ButtonReset", id + IMPULSE);
					client_print(id, print_center, "Вы переключились на режим критов!");
				}
			}
		}
    } 
}

public ButtonReset(id)
{
	id -= IMPULSE;
	ButtonTimeReload[id] = 0;
}


public HamHook_Item_Deploy(iItem)
{
	if (pev_valid(iItem) != 2)
		return HAM_IGNORED;
	
	new id = get_pdata_cbase(iItem, 41, 4);
	if(cs_get_weapon_id(iItem) == weapon_awp && pev(iItem, pev_impulse) == IMPULSE && IsUserHaveAwp[id])
	{
		set_pev(id, pev_viewmodel2, AWP_V_MODEL);
		set_pev(id, pev_weaponmodel2, AWP_P_MODEL);
	}
	
	return HAM_IGNORED;
}

public fw_Awp_AddToPlayer(iWeapon, id)
{
    if (!pev_valid(iWeapon) || !is_user_connected(id))
        return HAM_IGNORED;

    if (pev(iWeapon, pev_impulse) != IMPULSE)
        return HAM_IGNORED;

    if (!oldz_is_admin(id))
        return HAM_SUPERCEDE;

    IsUserHaveAwp[id] = true;
    return HAM_HANDLED;
}

public Fakemeta_SetModel(const iEntity, szModel[])
{
	if(!pev_valid(iEntity))
		return FMRES_IGNORED;
		
	new szClassName[32];
	pev(iEntity, pev_classname, szClassName, charsmax(szClassName));
	
	if (!equali(szClassName, "weaponbox"))
		return FMRES_IGNORED;
	
	for(new iSlot, iWeapon; iSlot < 6; iSlot++)
	{
		iWeapon = get_pdata_cbase(iEntity, 34 + iSlot, 4);
		if(pev_valid(iWeapon))
		{
			if(pev(iWeapon, pev_impulse) == IMPULSE)
			{
				engfunc(EngFunc_SetModel, iEntity, AWP_W_MODEL);
				return FMRES_SUPERCEDE;
			}
		}
	}
	return FMRES_IGNORED;
}

public OnWeaponboxTouch(wEnt, id)
{
	static szModel[32]; entity_get_string(wEnt, EV_SZ_model, szModel, charsmax(szModel));
	if(equal(szModel, AWP_W_MODEL))
    {
        if(!oldz_is_admin(id))
        {
            oldz_weapon_chat(id, "Поднять AWP Asiimov может только администратор.");
            return PLUGIN_HANDLED;
        }
        return PLUGIN_CONTINUE;
    }
	
	return PLUGIN_CONTINUE;
}

public FreezePlayer(id)
{
	set_pev(id, pev_renderfx, kRenderFxGlowShell);
	set_pev(id, pev_rendercolor, {0.0, 100.0, 200.0});
	set_pev(id, pev_rendermode, kRenderNormal);
	set_pev(id, pev_renderamt, 18.0);
	
	new Float:vecOrigin[3];
	pev(id, pev_origin, vecOrigin);
	
	set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN);
	set_pev(id, pev_origin, vecOrigin);
	
	message_begin(MSG_ONE_UNRELIABLE, MsgId_ScreenFade, _, id);
	write_short(1<<0);
	write_short(1<<0);
	write_short(1<<2);
	write_byte(0);
	write_byte(50);
	write_byte(200);
	write_byte(100);
	message_end();
	
	set_task(4.0, "UnFreezePlayer", id + IMPULSE);
}

public UnFreezePlayer(id)
{
	id -= IMPULSE;
	
	set_pev(id, pev_flags, pev(id, pev_flags) & ~FL_FROZEN);
	
	message_begin(MSG_ONE_UNRELIABLE, MsgId_ScreenFade, _, id);
	write_short(1<<0);
	write_short(1<<0);
	write_short(1<<1);
	write_byte(0);
	write_byte(0);
	write_byte(0);
	write_byte(0);
	message_end();
	
	set_pev(id, pev_renderfx, kRenderFxNone);
	set_pev(id, pev_rendercolor, {255.0, 255.0, 255.0});
	set_pev(id, pev_rendermode, kRenderNormal);
	set_pev(id, pev_renderamt, 18.0);
}

stock drop_weapons(id, dropwhat)
{
	static weapons[32], num, i, weaponid;
	num = 0;
	get_user_weapons(id, weapons, num);
    
	for (i = 0; i < num; i++)
	{
		weaponid = weapons[i];
		if (dropwhat == 1 && ((1<<weaponid) & PRIMARY_WEAPONS_BIT_SUM))
		{
			static wname[32];
			get_weaponname(weaponid, wname, sizeof wname - 1);
            
			engclient_cmd(id, "drop", wname);
		}
	}
}

stock give_item_ex2(iPlayer, const szWeaponName[], iAmmo = 0, bool:bDrop = false, iKey = 0)
{
	if (!equal(szWeaponName, "weapon_", 7))
		return false;
	
	new iWeapon = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, szWeaponName));
	
	if (!pev_valid(iWeapon))
		return false;
	
	if (bDrop)
	{
		new szWeapon[ 32 ],
			iSlot = ExecuteHamB(Ham_Item_ItemSlot, iWeapon),
			iItem = get_pdata_cbase(iPlayer, 367 + iSlot, 5);
		
		while ((pev_valid(iItem) == 2))
		{
			pev(iItem, pev_classname, szWeapon, charsmax(szWeapon));
			
			iItem = get_pdata_cbase(iItem, 42, 4);
		}
	}
	
	set_pev(iWeapon, pev_spawnflags, pev(iWeapon, pev_spawnflags) | SF_NORESPAWN);
	
	if (iKey > 0)	set_pev(iWeapon, pev_impulse, iKey);
	if (iAmmo > 0)	cs_set_user_bpammo(iPlayer, get_weaponid(szWeaponName), iAmmo);
	
	dllfunc(DLLFunc_Spawn, iWeapon);
	dllfunc(DLLFunc_Touch, iWeapon, iPlayer);
	
	return true;
}

stock bool:oldz_is_admin(id)
{
    return oldz_has_zp_admin_access(id) != 0
}

stock oldz_weapon_chat(id, const message[])
{
    client_print_color(id, print_team_default, "^4[OLD ZOMBIE | ZM 4.3]^1 %s", message)
}
