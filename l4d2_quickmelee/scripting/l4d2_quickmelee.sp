#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.3.0"

// Default refire_delay matching L4D2's Fireaxe script (scripts/melee/fireaxe.txt)
#define FIREAXE_REFIRE_DELAY 0.85

enum QuickMeleeState
{
    QM_Idle = 0,
    QM_ReadyToSwing,
    QM_Swinging
};

StringMap g_hMeleeRefireMap;
int g_iStaggerTimerOffset = -1;

bool g_bNotifiedThisMap[MAXPLAYERS + 1];
QuickMeleeState g_eState[MAXPLAYERS + 1];
float g_flLastSwingTime[MAXPLAYERS + 1];
float g_flSwingReadyTime[MAXPLAYERS + 1];
float g_flReturnTime[MAXPLAYERS + 1];
int g_iSwingAttemptTicks[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "[L4D2] Quick Melee",
    author      = "dudeDX & Gemini 4 Hydrogen",
    description = "Call of Duty style quick melee attack",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_iStaggerTimerOffset = FindSendPropInfo("CTerrorPlayer", "m_staggerTimer");

    BuildMeleeRefireMap();

    // Registers both console command "sm_qmelee" and chat trigger "!qmelee" / "/qmelee"
    RegConsoleCmd("sm_qmelee", Command_QuickMelee, "Instantly pull out melee, swing, and return to primary.");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerReset);
    HookEvent("player_incapacitated", Event_PlayerReset);
    HookEvent("weapon_fire", Event_WeaponFire);

    // Support late-loading the plugin mid-map
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
}

void BuildMeleeRefireMap()
{
    g_hMeleeRefireMap = new StringMap();

    // Official L4D2 melee script refire_delay values
    g_hMeleeRefireMap.SetValue("fireaxe",         0.85);
    g_hMeleeRefireMap.SetValue("baseball_bat",    0.75);
    g_hMeleeRefireMap.SetValue("cricket_bat",     0.75);
    g_hMeleeRefireMap.SetValue("crowbar",         0.85);
    g_hMeleeRefireMap.SetValue("electric_guitar", 0.85);
    g_hMeleeRefireMap.SetValue("frying_pan",      0.75);
    g_hMeleeRefireMap.SetValue("golfclub",        0.75);
    g_hMeleeRefireMap.SetValue("katana",          0.65);
    g_hMeleeRefireMap.SetValue("knife",           0.60);
    g_hMeleeRefireMap.SetValue("machete",         0.65);
    g_hMeleeRefireMap.SetValue("tonfa",           0.65);
    g_hMeleeRefireMap.SetValue("pitchfork",       0.85);
    g_hMeleeRefireMap.SetValue("shovel",          0.90);
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bNotifiedThisMap[i] = false;
        ResetClientState(i);
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientState(i);
    }
}

public void Event_PlayerReset(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        ResetClientState(client);
    }
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    char weaponName[32];
    event.GetString("weapon", weaponName, sizeof(weaponName));
    if (!StrEqual(weaponName, "melee", false))
    {
        return;
    }

    float now = GetGameTime();
    g_flLastSwingTime[client] = now;

    // Transition to QM_Swinging only after L4D2 confirms the swing actually started
    if (g_eState[client] == QM_ReadyToSwing)
    {
        int melee = GetPlayerWeaponSlot(client, 1);
        float refireDelay = IsValidEntity(melee) ? GetMeleeRefireDelay(melee) : FIREAXE_REFIRE_DELAY;

        g_flReturnTime[client] = now + refireDelay;
        g_eState[client] = QM_Swinging;
        g_iSwingAttemptTicks[client] = 0;
    }
}

public void OnClientPutInServer(int client)
{
    g_bNotifiedThisMap[client] = false;
    g_flLastSwingTime[client] = 0.0;
    ResetClientState(client);

    if (!IsFakeClient(client))
    {
        SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
    }
}

public void OnClientDisconnect(int client)
{
    g_bNotifiedThisMap[client] = false;
    g_flLastSwingTime[client] = 0.0;
    ResetClientState(client);
}

void ResetClientState(int client)
{
    g_eState[client] = QM_Idle;
    g_flSwingReadyTime[client] = 0.0;
    g_flReturnTime[client] = 0.0;
    g_iSwingAttemptTicks[client] = 0;
}

public void OnWeaponEquipPost(int client, int weapon)
{
    if (g_bNotifiedThisMap[client] || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    // Survivor team only
    if (GetClientTeam(client) != 2 || !IsValidEntity(weapon))
    {
        return;
    }

    char classname[32];
    GetEntityClassname(weapon, classname, sizeof(classname));

    if (StrEqual(classname, "weapon_melee", false))
    {
        g_bNotifiedThisMap[client] = true;

        PrintHintText(client, "Quick Melee available! Bind a key in console: bind v sm_qmelee");
        PrintToChat(client, "\x04[Quick Melee]\x01 Type \x03!qmelee\x01 or bind a key in console (\x05bind <key> sm_qmelee\x01) for a quick melee attack!");
    }
}

public Action Command_QuickMelee(int client, int args)
{
    // Silent return if invalid or blocked by any restriction
    if (!CanExecuteQuickMelee(client))
    {
        return Plugin_Handled;
    }

    // Ignore duplicate presses while a quick melee sequence is already active
    if (g_eState[client] != QM_Idle)
    {
        return Plugin_Handled;
    }

    int melee = GetPlayerWeaponSlot(client, 1);
    float now = GetGameTime();
    float refireDelay = GetMeleeRefireDelay(melee);

    // Enforce refire_delay from the last melee swing (ignoring deploy animation lock)
    float readyTime = g_flLastSwingTime[client] + refireDelay;
    if (readyTime < now)
    {
        readyTime = now;
    }

    g_flSwingReadyTime[client] = readyTime;
    g_iSwingAttemptTicks[client] = 0;
    g_eState[client] = QM_ReadyToSwing;

    // Pull out the melee weapon immediately
    int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (activeWeapon != melee)
    {
        FakeClientCommand(client, "use weapon_melee");
    }

    // Return Plugin_Handled so nothing is echoed to chat or console
    return Plugin_Handled;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (g_eState[client] == QM_Idle)
    {
        return Plugin_Continue;
    }

    // Abort immediately if the player becomes dead, incapped, pinned, staggered, or drops their melee
    if (!CanExecuteQuickMelee(client))
    {
        ResetClientState(client);
        return Plugin_Continue;
    }

    int melee = GetPlayerWeaponSlot(client, 1);
    int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    float now = GetGameTime();

    if (g_eState[client] == QM_ReadyToSwing)
    {
        // Step 1: Ensure melee is the active weapon before attempting to swing
        if (activeWeapon != melee)
        {
            buttons &= ~IN_ATTACK;
            weapon = melee;
            return Plugin_Changed;
        }

        // Step 2: Wait for the previous swing's refire_delay to finish before swinging
        if (now < g_flSwingReadyTime[client])
        {
            buttons &= ~IN_ATTACK;
            SetEntPropFloat(client, Prop_Send, "m_flNextAttack", 0.0);
            return Plugin_Changed;
        }

        // Safety failsafe (~1 second) so a player can never get stuck in QM_ReadyToSwing
        if (g_iSwingAttemptTicks[client] > 100)
        {
            ResetClientState(client);
            return Plugin_Continue;
        }

        // Step 3: Zero out deploy animation timers (using 0.0 avoids m_nTickBase clock drift)
        SetEntPropFloat(client, Prop_Send, "m_flNextAttack", 0.0);
        SetEntPropFloat(melee, Prop_Send, "m_flNextPrimaryAttack", 0.0);
        SetEntPropFloat(melee, Prop_Send, "m_flNextSecondaryAttack", 0.0);

        // Pulse IN_ATTACK on even ticks and release on odd ticks until Event_WeaponFire confirms the swing
        if ((g_iSwingAttemptTicks[client] % 2) == 0)
        {
            int oldButtons = GetEntProp(client, Prop_Data, "m_nButtons");
            SetEntProp(client, Prop_Data, "m_nButtons", oldButtons & ~IN_ATTACK);
            buttons |= IN_ATTACK;
        }
        else
        {
            buttons &= ~IN_ATTACK;
        }

        g_iSwingAttemptTicks[client]++;
        return Plugin_Changed;
    }
    else if (g_eState[client] == QM_Swinging)
    {
        // Wait until the full swing animation and hit rays finish playing out
        if (now >= g_flReturnTime[client])
        {
            int primary = GetPlayerWeaponSlot(client, 0);
            ResetClientState(client);

            if (IsValidEntity(primary))
            {
                FakeClientCommand(client, "slot1");
                weapon = primary;
                return Plugin_Changed;
            }
        }
    }

    return Plugin_Continue;
}

bool CanExecuteQuickMelee(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    // Excludes Infected, Spectators, and Idle players (idle players sit on team 1 / observer)
    if (GetClientTeam(client) != 2 || IsClientObserver(client) || !IsPlayerAlive(client))
    {
        return false;
    }

    // Excludes incapacitated or ledge-hanging survivors
    if (GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0 ||
        GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
    {
        return false;
    }

    // Excludes survivors pinned by Smoker, Hunter, Jockey, or Charger
    if (GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0 ||
        GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0 ||
        GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0 ||
        GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0 ||
        GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0)
    {
        return false;
    }

    // Excludes stunned / stumbled / staggered survivors
    if (IsPlayerStaggering(client))
    {
        return false;
    }

    // Must have a melee weapon in secondary slot (slot 1)
    int secondary = GetPlayerWeaponSlot(client, 1);
    if (!IsValidEntity(secondary))
    {
        return false;
    }

    char classname[32];
    GetEntityClassname(secondary, classname, sizeof(classname));
    if (!StrEqual(classname, "weapon_melee", false))
    {
        return false;
    }

    return true;
}

bool IsPlayerStaggering(int client)
{
    if (g_iStaggerTimerOffset == -1)
    {
        return false;
    }

    // CountdownTimer stores its expiration timestamp at offset + 8
    float staggerEndTime = GetEntDataFloat(client, g_iStaggerTimerOffset + 8);
    return (staggerEndTime > GetGameTime());
}

float GetMeleeRefireDelay(int melee)
{
    char scriptName[64];
    GetEntPropString(melee, Prop_Data, "m_strMapSetScriptName", scriptName, sizeof(scriptName));

    float delay = FIREAXE_REFIRE_DELAY;
    if (scriptName[0] != '\0' && g_hMeleeRefireMap.GetValue(scriptName, delay))
    {
        return delay;
    }

    // Custom or unrecognized melee script falls back to Fireaxe's refire_delay
    return FIREAXE_REFIRE_DELAY;
}