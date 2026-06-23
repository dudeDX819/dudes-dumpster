#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define ZC_SMOKER  1
#define ZC_HUNTER  3
#define ZC_JOCKEY  5
#define ZC_CHARGER 6

/*
    This delay gives L4D2 enough time to finish its incap weapon handling,
    which helps prevent the survivor from keeping the incap pistol instead
    of getting their melee weapon back.
*/
#define LSS_REVIVE_DELAY 0.15
#define LSS_DAMAGE_NO  0
#define LSS_DAMAGE_YES 2

public Plugin myinfo =
{
    name = "[L4D2] Last Survivor Standing",
    author = "ChatGPT",
    description = "Reimplements the self-revive mechanic from Last Man on Earth as a co-op feature.",
    version = "1.1.0",
    url = ""
};

ConVar g_cvEnable;
ConVar g_cvTempHealth;
ConVar g_cvIgnoreTime;
ConVar g_cvMaxIncaps;
ConVar g_cvNbBlind;
ConVar g_cvNoDeathCheck;
ConVar g_cvPainPillsDecayRate;

int g_iSavedTakeDamage[MAXPLAYERS + 1];
bool g_bSavedTakeDamage[MAXPLAYERS + 1];

bool g_bPreIncapDeathCheck[MAXPLAYERS + 1];
Handle g_hPreIncapDeathCheckTimer[MAXPLAYERS + 1];

bool g_bUsed[MAXPLAYERS + 1];
bool g_bPending[MAXPLAYERS + 1];
bool g_bProtected[MAXPLAYERS + 1];

Handle g_hProtectTimer[MAXPLAYERS + 1];

int g_iNbBlindRefs;
bool g_bSavedNbBlind;
bool g_bSavedNbBlindValue;

int g_iNoDeathCheckRefs;
bool g_bSavedNoDeathCheck;
bool g_bSavedNoDeathCheckValue;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    char game[32];
    GetGameFolderName(game, sizeof(game));

    if (!StrEqual(game, "left4dead2", false))
    {
        strcopy(error, err_max, "This plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvEnable = CreateConVar(
        "l4d2_lss_enable",
        "1",
        "Enable Last Survivor Standing. 0 = off, 1 = on.",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_cvTempHealth = CreateConVar(
        "l4d2_lss_temp_health",
        "99",
        "Temporary health given after the self-revive. Final health is 1 permanent HP + this value.",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 99.0
    );

    g_cvIgnoreTime = CreateConVar(
        "l4d2_lss_ignore_time",
        "6.0",
        "Seconds of infected ignore/god-mode after revive. 0 = none, negative = indefinite until round end/map end.",
        FCVAR_NOTIFY
    );

    g_cvMaxIncaps = FindConVar("survivor_max_incapacitated_count");
    g_cvPainPillsDecayRate = FindConVar("pain_pills_decay_rate");
    g_cvNbBlind = FindConVar("nb_blind");
    g_cvNoDeathCheck = FindConVar("director_no_death_check");

    HookEvent("player_incapacitated", Event_PlayerIncapacitated_Pre, EventHookMode_Pre);
    HookEvent("player_incapacitated", Event_PlayerIncapacitated, EventHookMode_Post);
    HookEvent("heal_success", Event_HealSuccess, EventHookMode_Post);

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

    HookEvent("round_start", Event_ResetAll, EventHookMode_PostNoCopy);
    HookEventEx("round_end", Event_ResetAll, EventHookMode_PostNoCopy);
    HookEventEx("mission_lost", Event_ResetAll, EventHookMode_PostNoCopy);
    HookEventEx("map_transition", Event_ResetAll, EventHookMode_PostNoCopy);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
        }
    }

    AutoExecConfig(true, "l4d2_lastsurvivorstanding");
}

public void Event_PlayerIncapacitated_Pre(Event event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(g_cvEnable))
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));

    if (!IsValidSurvivor(client))
    {
        return;
    }

    if (g_bUsed[client] || g_bPending[client])
    {
        return;
    }

    /*
        Backup path for non-standard incap cases where damage prediction
        might not catch the exact moment.
    */
    if (!HasOtherAliveSurvivor(client))
    {
        StartPreIncapDeathCheck(client);
    }
}

public void OnMapEnd()
{
    ResetAllClients();
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);

    g_bUsed[client] = false;
    g_bPending[client] = false;
    g_bProtected[client] = false;
    g_hProtectTimer[client] = null;
    g_iSavedTakeDamage[client] = LSS_DAMAGE_YES;
    g_bSavedTakeDamage[client] = false;
}

public void OnClientDisconnect(int client)
{
    StopPreIncapDeathCheck(client, true);
    StopProtection(client, true, false);
    StopGodMode(client);

    g_bUsed[client] = false;
    g_bPending[client] = false;
    g_hProtectTimer[client] = null;
}

public void Event_ResetAll(Event event, const char[] name, bool dontBroadcast)
{
    ResetAllClients();
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client > 0)
    {
        StopProtection(client, true, false);
        g_bPending[client] = false;
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client > 0 && GetClientTeam(client) != TEAM_SURVIVOR)
    {
        StopProtection(client, true, false);
        g_bPending[client] = false;
    }
}

public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(g_cvEnable))
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));

    if (!IsValidSurvivor(client))
    {
        return;
    }

    if (g_bUsed[client] || g_bPending[client])
    {
        return;
    }

    /*
        Let incap state/netprops settle before deciding.
    */
    CreateTimer(0.10, Timer_CheckLastSurvivor, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(g_cvEnable))
    {
        return;
    }

    int healer = GetClientOfUserId(event.GetInt("userid"));
    int subject = GetClientOfUserId(event.GetInt("subject"));

    /*
        Reactivate only if the lone survivor healed themselves with a first aid kit.
        heal_success is the first-aid-kit success event.
    */
    if (healer <= 0 || healer != subject)
    {
        return;
    }

    if (!IsValidSurvivor(healer))
    {
        return;
    }

    if (!IsPlayerAlive(healer))
    {
        return;
    }

    if (IsIncapacitatedOrHanging(healer))
    {
        return;
    }

    /*
        Incapacitated teammates still count as alive here.
        The healer must truly be the only alive survivor.
    */
    if (HasOtherAliveSurvivor(healer))
    {
        return;
    }

    g_bUsed[healer] = false;
}

public Action Timer_CheckLastSurvivor(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (!IsEligibleForLastSurvivorRevive(client))
    {
        if (client > 0)
        {
            StopPreIncapDeathCheck(client, true);
        }

        return Plugin_Stop;
    }

    g_bPending[client] = true;

    /*
        Fallback in case the pre-damage/pre-event path missed it.
        This does not add duplicate refs if it is already active.
    */
    StartPreIncapDeathCheck(client);

    KillPinningInfected(client);

    CreateTimer(LSS_REVIVE_DELAY, Timer_DoSelfRevive, userid, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

public Action Timer_DoSelfRevive(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (client <= 0 || !g_bPending[client])
    {
        if (client > 0)
        {
            StopPreIncapDeathCheck(client, true);
        }

        return Plugin_Stop;
    }

    g_bPending[client] = false;

    if (!IsEligibleForLastSurvivorRevive(client))
    {
        StopPreIncapDeathCheck(client, true);
        return Plugin_Stop;
    }

    g_bUsed[client] = true;

    KillPinningInfected(client);
    SelfRevive(client);

    /*
        Re-enable death check only after the survivor is actually revived.
    */
    StopPreIncapDeathCheck(client, true);

    StartProtection(client);
    PrintReviveMessages(client);

    return Plugin_Stop;
}

public Action OnTakeDamage(
    int victim,
    int &attacker,
    int &inflictor,
    float &damage,
    int &damagetype
)
{
    if (victim > 0 && victim <= MaxClients && g_bProtected[victim])
    {
        damage = 0.0;
        return Plugin_Changed;
    }

    /*
        Enable director_no_death_check before L4D2 finishes processing
        the final survivor's incapacitating hit.
    */
    if (ShouldStartPreIncapDeathCheck(victim, damage))
    {
        StartPreIncapDeathCheck(victim);
    }

    return Plugin_Continue;
}

bool ShouldStartPreIncapDeathCheck(int client, float damage)
{
    if (!GetConVarBool(g_cvEnable))
    {
        return false;
    }

    if (damage <= 0.0)
    {
        return false;
    }

    if (!IsValidSurvivor(client))
    {
        return false;
    }

    if (!IsPlayerAlive(client))
    {
        return false;
    }

    if (g_bUsed[client] || g_bPending[client])
    {
        return false;
    }

    if (g_bProtected[client])
    {
        return false;
    }

    if (IsIncapacitatedOrHanging(client))
    {
        return false;
    }

    /*
        Incapacitated teammates still count as alive and block LSS.
    */
    if (HasOtherAliveSurvivor(client))
    {
        return false;
    }

    float effectiveHealth = GetSurvivorEffectiveHealth(client);

    /*
        Small tolerance helps with float/temp-health decay timing.
    */
    return damage + 0.5 >= effectiveHealth;
}

float GetSurvivorEffectiveHealth(int client)
{
    float health = float(GetEntProp(client, Prop_Send, "m_iHealth"));

    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    float bufferTime = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");

    float decayRate = 0.27;

    if (g_cvPainPillsDecayRate != null)
    {
        decayRate = GetConVarFloat(g_cvPainPillsDecayRate);
    }

    if (buffer > 0.0)
    {
        float elapsed = GetGameTime() - bufferTime;
        buffer -= elapsed * decayRate;

        if (buffer < 0.0)
        {
            buffer = 0.0;
        }

        health += buffer;
    }

    return health;
}

void StartGodMode(int client)
{
    if (!IsValidSurvivor(client))
    {
        return;
    }

    if (!g_bSavedTakeDamage[client])
    {
        g_iSavedTakeDamage[client] = GetEntProp(client, Prop_Data, "m_takedamage");
        g_bSavedTakeDamage[client] = true;
    }

    SetEntProp(client, Prop_Data, "m_takedamage", LSS_DAMAGE_NO);
}

void StopGodMode(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (!IsClientInGame(client))
    {
        g_bSavedTakeDamage[client] = false;
        return;
    }

    if (g_bSavedTakeDamage[client])
    {
        SetEntProp(client, Prop_Data, "m_takedamage", g_iSavedTakeDamage[client]);
        g_bSavedTakeDamage[client] = false;
    }
    else
    {
        SetEntProp(client, Prop_Data, "m_takedamage", LSS_DAMAGE_YES);
    }
}

void StartPreIncapDeathCheck(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (!g_bPreIncapDeathCheck[client])
    {
        g_bPreIncapDeathCheck[client] = true;
        StartNoDeathCheck();
    }

    /*
        Refresh the failsafe timer without adding another no-death-check ref.
    */
    if (g_hPreIncapDeathCheckTimer[client] != null)
    {
        delete g_hPreIncapDeathCheckTimer[client];
        g_hPreIncapDeathCheckTimer[client] = null;
    }

    g_hPreIncapDeathCheckTimer[client] = CreateTimer(
        3.0,
        Timer_PreIncapDeathCheckFailsafe,
        GetClientUserId(client),
        TIMER_FLAG_NO_MAPCHANGE
    );
}

public Action Timer_PreIncapDeathCheckFailsafe(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (client > 0)
    {
        g_hPreIncapDeathCheckTimer[client] = null;

        /*
            If the actual LSS revive flow did not begin, restore the cvar.
            If g_bPending is true, Timer_DoSelfRevive will restore it.
        */
        if (!g_bPending[client])
        {
            StopPreIncapDeathCheck(client, false);
        }
    }

    return Plugin_Stop;
}

void StopPreIncapDeathCheck(int client, bool closeTimer)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (closeTimer && g_hPreIncapDeathCheckTimer[client] != null)
    {
        delete g_hPreIncapDeathCheckTimer[client];
        g_hPreIncapDeathCheckTimer[client] = null;
    }

    if (!g_bPreIncapDeathCheck[client])
    {
        return;
    }

    g_bPreIncapDeathCheck[client] = false;
    StopNoDeathCheck();
}

bool IsEligibleForLastSurvivorRevive(int client)
{
    if (!GetConVarBool(g_cvEnable))
    {
        return false;
    }

    if (!IsValidSurvivor(client))
    {
        return false;
    }

    if (!IsPlayerAlive(client))
    {
        return false;
    }

    if (g_bUsed[client])
    {
        return false;
    }

    if (!IsIncapacitatedOrHanging(client))
    {
        return false;
    }

    /*
        Important change:
        Other incapacitated/hanging/falling survivors are still alive,
        so they block this mechanic.
    */
    if (HasOtherAliveSurvivor(client))
    {
        return false;
    }

    return true;
}

bool HasOtherAliveSurvivor(int client)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client)
        {
            continue;
        }

        if (!IsValidSurvivor(i))
        {
            continue;
        }

        /*
            Incapacitated survivors still return IsPlayerAlive() true,
            which is exactly what we want now.
        */
        if (IsPlayerAlive(i))
        {
            return true;
        }
    }

    return false;
}

bool IsValidSurvivor(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_SURVIVOR;
}

bool IsValidInfected(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_INFECTED;
}

bool IsIncapacitatedOrHanging(int client)
{
    if (GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0)
    {
        return true;
    }

    if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
    {
        return true;
    }

    if (GetEntProp(client, Prop_Send, "m_isFallingFromLedge") != 0)
    {
        return true;
    }

    return false;
}

void SelfRevive(int client)
{
    /*
        Use L4D2's own recovery path instead of manually clearing incap props.
        This should avoid the forced-incap pistol state sticking around.
    */
    RunCheatClientCommand(client, "give", "health");

    /*
        If give health failed for some reason, fallback so the mechanic still works.
    */
    if (IsIncapacitatedOrHanging(client))
    {
        ClearIncapState(client);
    }

    /*
        Re-apply LSS health values after the game revives the survivor.
    */
    SetEntProp(client, Prop_Send, "m_iHealth", 1);

    int tempHealth = GetConVarInt(g_cvTempHealth);
    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", float(tempHealth));
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());

    int maxIncaps = 2;

    if (g_cvMaxIncaps != null)
    {
        maxIncaps = GetConVarInt(g_cvMaxIncaps);
    }

    if (maxIncaps < 1)
    {
        maxIncaps = 1;
    }

    /*
        Put them back into black-and-white state after the revive.
    */
    SetEntProp(client, Prop_Send, "m_currentReviveCount", maxIncaps);
    SetEntProp(client, Prop_Send, "m_isGoingToDie", 1);

    SetEntityMoveType(client, MOVETYPE_WALK);

    float zeroVel[3] = {0.0, 0.0, 0.0};
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, zeroVel);
}

void ClearIncapState(int client)
{
    SetEntProp(client, Prop_Send, "m_isIncapacitated", 0);
    SetEntProp(client, Prop_Send, "m_isHangingFromLedge", 0);
    SetEntProp(client, Prop_Send, "m_isFallingFromLedge", 0);

    SetEntPropEnt(client, Prop_Send, "m_reviveOwner", -1);
    SetEntPropEnt(client, Prop_Send, "m_reviveTarget", -1);
}

void KillPinningInfected(int client)
{
    KillPinnerIfClass(GetEntPropEnt(client, Prop_Send, "m_tongueOwner"), ZC_SMOKER);
    KillPinnerIfClass(GetEntPropEnt(client, Prop_Send, "m_pounceAttacker"), ZC_HUNTER);
    KillPinnerIfClass(GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker"), ZC_JOCKEY);

    /*
        Charger can be carrying or pummeling.
    */
    KillPinnerIfClass(GetEntPropEnt(client, Prop_Send, "m_carryAttacker"), ZC_CHARGER);
    KillPinnerIfClass(GetEntPropEnt(client, Prop_Send, "m_pummelAttacker"), ZC_CHARGER);
}

void KillPinnerIfClass(int infected, int expectedClass)
{
    if (!IsValidInfected(infected))
    {
        return;
    }

    if (!IsPlayerAlive(infected))
    {
        return;
    }

    int zombieClass = GetEntProp(infected, Prop_Send, "m_zombieClass");

    if (zombieClass != expectedClass)
    {
        return;
    }

    ForcePlayerSuicide(infected);
}

void StartProtection(int client)
{
    float seconds = GetConVarFloat(g_cvIgnoreTime);

    if (seconds == 0.0)
    {
        return;
    }

    if (!g_bProtected[client])
    {
        g_bProtected[client] = true;

        /*
            nb_blind makes infected ignore the survivor.
            godmode protects against commons/specials that were already attacking.
        */
        StartNbBlind();
        StartGodMode(client);
    }

    if (g_hProtectTimer[client] != null)
    {
        delete g_hProtectTimer[client];
        g_hProtectTimer[client] = null;
    }

    /*
        Negative value = indefinite until round end, map end, death, disconnect, or team change.
    */
    if (seconds > 0.0)
    {
        g_hProtectTimer[client] = CreateTimer(
            seconds,
            Timer_EndProtection,
            GetClientUserId(client),
            TIMER_FLAG_NO_MAPCHANGE
        );
    }
}

public Action Timer_EndProtection(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (client > 0)
    {
        g_hProtectTimer[client] = null;
        StopProtection(client, false, true);
    }

    return Plugin_Stop;
}

void StopProtection(int client, bool closeTimer, bool announce)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (closeTimer && g_hProtectTimer[client] != null)
    {
        delete g_hProtectTimer[client];
        g_hProtectTimer[client] = null;
    }

    if (!g_bProtected[client])
    {
        return;
    }

    g_bProtected[client] = false;

    StopNbBlind();
    StopGodMode(client);

    if (announce && IsClientInGame(client) && !IsFakeClient(client))
    {
        PrintToChat(client, "\x05[LSS]\x01 You are now vulnerable.");
    }
}

void PrintReviveMessages(int client)
{
    char timeText[32];
    FormatProtectionTime(timeText, sizeof(timeText), GetConVarFloat(g_cvIgnoreTime));

    if (!IsFakeClient(client))
    {
        PrintToChat(
            client,
            "\x05[LSS]\x01 You have been given another chance! You're protected for \x03%s\x01 seconds.",
            timeText
        );
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client)
        {
            continue;
        }

        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        PrintToChat(
            i,
            "\x05[LSS]\x01 \x03%N\x01 has been given another chance!",
            client
        );
    }
}

void FormatProtectionTime(char[] buffer, int size, float seconds)
{
    if (seconds < 0.0)
    {
        strcopy(buffer, size, "indefinite");
        return;
    }

    if (FloatAbs(seconds - float(RoundToNearest(seconds))) < 0.01)
    {
        Format(buffer, size, "%d", RoundToNearest(seconds));
        return;
    }

    Format(buffer, size, "%.1f", seconds);
}

void StartNbBlind()
{
    if (g_cvNbBlind == null)
    {
        return;
    }

    if (g_iNbBlindRefs == 0)
    {
        g_bSavedNbBlindValue = GetConVarBool(g_cvNbBlind);
        g_bSavedNbBlind = true;

        SetCheatConVarBool(g_cvNbBlind, true);
    }

    g_iNbBlindRefs++;
}

void StopNbBlind()
{
    if (g_cvNbBlind == null)
    {
        return;
    }

    if (g_iNbBlindRefs <= 0)
    {
        return;
    }

    g_iNbBlindRefs--;

    if (g_iNbBlindRefs == 0 && g_bSavedNbBlind)
    {
        SetCheatConVarBool(g_cvNbBlind, g_bSavedNbBlindValue);
        g_bSavedNbBlind = false;
    }
}

void ForceRestoreNbBlind()
{
    if (g_cvNbBlind != null && g_bSavedNbBlind)
    {
        SetCheatConVarBool(g_cvNbBlind, g_bSavedNbBlindValue);
    }

    g_iNbBlindRefs = 0;
    g_bSavedNbBlind = false;
}

void StartNoDeathCheck()
{
    if (g_cvNoDeathCheck == null)
    {
        return;
    }

    if (g_iNoDeathCheckRefs == 0)
    {
        g_bSavedNoDeathCheckValue = GetConVarBool(g_cvNoDeathCheck);
        g_bSavedNoDeathCheck = true;

        SetCheatConVarBool(g_cvNoDeathCheck, true);
    }

    g_iNoDeathCheckRefs++;
}

void StopNoDeathCheck()
{
    if (g_cvNoDeathCheck == null)
    {
        return;
    }

    if (g_iNoDeathCheckRefs <= 0)
    {
        return;
    }

    g_iNoDeathCheckRefs--;

    if (g_iNoDeathCheckRefs == 0 && g_bSavedNoDeathCheck)
    {
        SetCheatConVarBool(g_cvNoDeathCheck, g_bSavedNoDeathCheckValue);
        g_bSavedNoDeathCheck = false;
    }
}

void ForceRestoreNoDeathCheck()
{
    if (g_cvNoDeathCheck != null && g_bSavedNoDeathCheck)
    {
        SetCheatConVarBool(g_cvNoDeathCheck, g_bSavedNoDeathCheckValue);
    }

    g_iNoDeathCheckRefs = 0;
    g_bSavedNoDeathCheck = false;
}

void SetCheatConVarBool(ConVar cvar, bool value)
{
    if (cvar == null)
    {
        return;
    }

    int flags = GetConVarFlags(cvar);

    SetConVarFlags(cvar, flags & ~FCVAR_CHEAT);
    SetConVarBool(cvar, value, false, false);
    SetConVarFlags(cvar, flags);
}

void RunCheatClientCommand(int client, const char[] command, const char[] arguments = "")
{
    int flags = GetCommandFlags(command);
    SetCommandFlags(command, flags & ~FCVAR_CHEAT);

    if (arguments[0] == '\0')
    {
        FakeClientCommand(client, "%s", command);
    }
    else
    {
        FakeClientCommand(client, "%s %s", command, arguments);
    }

    SetCommandFlags(command, flags);
}

void ResetAllClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bUsed[i] = false;
        g_bPending[i] = false;

        if (g_hPreIncapDeathCheckTimer[i] != null)
        {
            delete g_hPreIncapDeathCheckTimer[i];
            g_hPreIncapDeathCheckTimer[i] = null;
        }

        g_bPreIncapDeathCheck[i] = false;

        StopProtection(i, true, false);
        StopGodMode(i);
    }

    ForceRestoreNbBlind();
    ForceRestoreNoDeathCheck();
}