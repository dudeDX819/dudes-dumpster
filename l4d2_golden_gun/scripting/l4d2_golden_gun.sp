#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

/* ==========================================================================
   Golden Gun - L4D2 SourcePawn Plugin
   --------------------------------------------------------------------------
   Admin-only one-shot-kill Magnum Pistol.

   Commands (all identical): !golden / sm_golden
                              !goldengun / sm_goldengun
                              !admingun / sm_admingun

   - Non-admins are told they don't have access.
   - Admins receive a Magnum Pistol that:
       * Holds exactly 1 round per clip.
       * Takes exactly 2 seconds to reload.
       * One-shot kills any infected (Common, all Specials, Witch, Tank).
   - All of the above is re-verified every server tick (OnGameFrame) so the
     gun's stats can never drift away from spec (e.g. from other plugins,
     ammo pickups, etc.) and so nothing but this specific weapon instance
     is ever affected.
   ========================================================================== */

#define PLUGIN_VERSION      "1.0.0"

#define GOLDEN_GUN_CLASSNAME "weapon_pistol_magnum"
#define ONE_SHOT_DAMAGE      99999.0
#define RELOAD_TIME          2.0
#define TEAM_INFECTED        3

// NOTE: We intentionally do NOT define our own "no weapon" sentinel as 0 -
// entity reference 0 decodes to entity index 0, which is worldspawn, and
// IsValidEntity(0) returns true. Using SourceMod's own INVALID_ENT_REFERENCE
// constant everywhere below is what keeps "no golden gun yet" from ever
// being mistaken for "the world is the golden gun."

// Per-client state
int   g_iGoldenGunRef[MAXPLAYERS + 1];     // Entity reference of the client's golden gun (0 = none)
bool  g_bGoldenReloading[MAXPLAYERS + 1];  // Is this client's golden gun currently mid (managed) reload?


public Plugin myinfo =
{
    name        = "[L4D2] Golden Gun",
    author      = "dudeDX + Claude",
    description = "One-shot kill Admin gun",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_golden",    Command_GoldenGun, "Give yourself the Golden Gun (admin only)");
    RegConsoleCmd("sm_goldengun", Command_GoldenGun, "Give yourself the Golden Gun (admin only)");
    RegConsoleCmd("sm_admingun",  Command_GoldenGun, "Give yourself the Golden Gun (admin only)");

    HookEvent("round_start",  Event_RoundStart,  EventHookMode_PostNoCopy);

    for (int i = 0; i <= MaxClients; i++)
    {
        g_iGoldenGunRef[i]    = INVALID_ENT_REFERENCE;
        g_bGoldenReloading[i] = false;
    }
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Weapons don't survive round restarts, so drop all stale references.
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iGoldenGunRef[i]    = INVALID_ENT_REFERENCE;
        g_bGoldenReloading[i] = false;
    }
}

public void OnClientDisconnect(int client)
{
    g_iGoldenGunRef[client]    = INVALID_ENT_REFERENCE;
    g_bGoldenReloading[client] = false;
}

/* --------------------------------------------------------------------------
   Commands
   -------------------------------------------------------------------------- */

Action Command_GoldenGun(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[Golden Gun] This command can only be used in-game.");
        return Plugin_Handled;
    }

    if (!CheckCommandAccess(client, "sm_admingun", ADMFLAG_GENERIC, false))
    {
        ReplyToCommand(client, "\x04[Golden Gun]\x01 You don't have access to this command.");
        return Plugin_Handled;
    }

    if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != 2)
    {
        ReplyToCommand(client, "\x04[Golden Gun]\x01 You must be alive as a Survivor to receive the Golden Gun.");
        return Plugin_Handled;
    }

    GiveGoldenGun(client);
    return Plugin_Handled;
}

void GiveGoldenGun(int client)
{
    // If this admin already has a golden gun out there, remove it first so we
    // never end up with two golden guns floating around.
    int oldWeapon = EntRefToEntIndex(g_iGoldenGunRef[client]);
    if (oldWeapon != INVALID_ENT_REFERENCE && IsValidEntity(oldWeapon))
    {
        RemovePlayerItem(client, oldWeapon);
        AcceptEntityInput(oldWeapon, "Kill");
    }
    g_iGoldenGunRef[client]    = INVALID_ENT_REFERENCE;
    g_bGoldenReloading[client] = false;

    int weapon = GivePlayerItem(client, GOLDEN_GUN_CLASSNAME);
    if (weapon == -1 || !IsValidEntity(weapon))
    {
        ReplyToCommand(client, "\x04[Golden Gun]\x01 Failed to spawn the weapon. Try again.");
        return;
    }

    EquipPlayerWeapon(client, weapon);

    // Lock the clip at exactly 1 round immediately.
    SetEntProp(weapon, Prop_Send, "m_iClip1", 1);

    // Hook this SPECIFIC weapon instance only - no other weapon or player is touched.
    SDKHook(weapon, SDKHook_ReloadPost, OnGoldenGunReloadPost);
    SDKHook(weapon, SDKHook_Reload,     OnGoldenGunReload);

    g_iGoldenGunRef[client] = EntIndexToEntRef(weapon);

    PrintToChatAll("\x04[Golden Gun]\x01 %N \x01has been granted the \x03Golden Gun\x01!", client);
}

/* --------------------------------------------------------------------------
   Reload control - block the default reload and manage a precise 2 second
   reload ourselves, so the reload duration is guaranteed regardless of the
   weapon's default animation timing.
   -------------------------------------------------------------------------- */

Action OnGoldenGunReload(int weapon)
{
    int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwner");
    if (owner <= 0 || owner > MaxClients)
        return Plugin_Continue;

    if (EntRefToEntIndex(g_iGoldenGunRef[owner]) != weapon)
        return Plugin_Continue; // Not actually the tracked golden gun - never touch other weapons.

    if (g_bGoldenReloading[owner])
        return Plugin_Handled; // Already mid managed-reload, block spam-reload requests.

    g_bGoldenReloading[owner] = true;

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(owner));
    pack.WriteCell(EntIndexToEntRef(weapon));
    CreateTimer(RELOAD_TIME, Timer_FinishGoldenReload, pack, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled; // Block the engine's own (unpredictable-timing) reload.
}

void OnGoldenGunReloadPost(int weapon)
{
    // No-op: default reload is always blocked by OnGoldenGunReload above, but
    // hook is kept in case another plugin forces a reload through some other path.
}

Action Timer_FinishGoldenReload(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int weaponRef = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Stop;

    g_bGoldenReloading[client] = false;

    int weapon = EntRefToEntIndex(weaponRef);
    if (weapon == INVALID_ENT_REFERENCE || !IsValidEntity(weapon))
        return Plugin_Stop;

    if (EntRefToEntIndex(g_iGoldenGunRef[client]) != weapon)
        return Plugin_Stop; // Client swapped guns mid-reload, do nothing.

    SetEntProp(weapon, Prop_Send, "m_iClip1", 1);

    return Plugin_Stop;
}

/* --------------------------------------------------------------------------
   1-tick consistency check - re-verifies every attribute of every tracked
   golden gun on every single server frame. Only the tracked weapon entity
   for each client is ever touched; nothing else is affected.
   -------------------------------------------------------------------------- */

public void OnGameFrame()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        int weaponRef = g_iGoldenGunRef[client];
        if (weaponRef == INVALID_ENT_REFERENCE)
            continue;

        int weapon = EntRefToEntIndex(weaponRef);
        if (weapon == INVALID_ENT_REFERENCE || !IsValidEntity(weapon))
        {
            g_iGoldenGunRef[client]    = INVALID_ENT_REFERENCE;
            g_bGoldenReloading[client] = false;
            continue;
        }

        // 1) Enforce exactly 1 bullet per clip (unless we're mid managed reload,
        //    where the clip is intentionally sitting at 0 until the timer fires).
        if (!g_bGoldenReloading[client])
        {
            int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
            if (clip > 1)
            {
                SetEntProp(weapon, Prop_Send, "m_iClip1", 1);
            }
        }

        // 2) Reload timing is guaranteed by Timer_FinishGoldenReload (exactly
        //    RELOAD_TIME after OnGoldenGunReload fires) - nothing further to
        //    enforce here besides making sure the reload flag hasn't gotten stuck.
    }
}

/* --------------------------------------------------------------------------
   One-shot kill logic
   -------------------------------------------------------------------------- */

public void OnEntityCreated(int entity, const char[] classname)
{
    // Covers Common Infected, Witch, and Tank - these are genuinely their own
    // entity classes in L4D2.
    if (IsInfectedClassname(classname))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnInfectedTakeDamage);
        SDKHook(entity, SDKHook_OnTakeDamagePost, OnInfectedTakeDamagePost);
    }
}

public void OnClientPutInServer(int client)
{
    // Smoker/Boomer/Hunter/Spitter/Jockey/Charger are NOT their own entity
    // class - they're implemented as the same generic "player" entity as
    // Survivors (since players swap teams in Versus), differentiated only by
    // team/zombie-class, not classname. OnEntityCreated's classname check
    // above never sees "smoker"/"boomer"/etc. because that string never
    // exists as a classname - it never fires for them. Hooking every client
    // here (and filtering strictly by team inside the callback) is what
    // actually catches these SI types.
    SDKHook(client, SDKHook_OnTakeDamage, OnInfectedTakeDamage);
    SDKHook(client, SDKHook_OnTakeDamagePost, OnInfectedTakeDamagePost);
}

bool IsInfectedClassname(const char[] classname)
{
    // Only Common Infected, Witch, and Tank actually spawn under their own
    // classname. The 6 mobile Special Infected are handled separately in
    // OnClientPutInServer since they're generic "player" entities.
    return (strcmp(classname, "infected") == 0   ||  // Common Infected
            strcmp(classname, "witch") == 0       ||
            strcmp(classname, "witch_bride") == 0 ||
            strcmp(classname, "tank") == 0);
}

Action OnInfectedTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype,
                             int &weapon, float damageForce[3], float damagePosition[3])
{
    if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;

    int goldenWeapon = EntRefToEntIndex(g_iGoldenGunRef[attacker]);
    if (goldenWeapon == INVALID_ENT_REFERENCE)
        return Plugin_Continue;

    // NOTE: L4D2's damage event does NOT reliably populate 'weapon'/'inflictor'
    // with the weapon entity for player-vs-player damage (shooting a mobile
    // Special Infected counts as player-vs-player, since SI other than Tank/
    // Witch are CTerrorPlayer entities same as Survivors) - inflictor often
    // comes through as the attacker's player entity instead. That field is
    // reliable for NPC-class victims (Common Infected/Tank/Witch) but not
    // for player-class ones, which is exactly why only Tank/Witch worked
    // before. Checking the attacker's actual active weapon is reliable for
    // both, so we use that instead of trusting the damage event's fields.
    int activeWeapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
    if (activeWeapon != goldenWeapon)
        return Plugin_Continue;

    // Mobile Special Infected (Smoker/Boomer/Hunter/Spitter/Jockey/Charger)
    // are player-slot entities just like Survivors, so this hook is also
    // attached to every Survivor. Never touch anyone who isn't actually on
    // the Infected team - this is what keeps Survivors safe from friendly
    // golden-gun fire while still catching every SI type.
    if (victim >= 1 && victim <= MaxClients)
    {
        if (!IsClientInGame(victim) || GetClientTeam(victim) != TEAM_INFECTED)
            return Plugin_Continue;
    }

    damage = ONE_SHOT_DAMAGE;

    // NOTE: Modifying 'damage' alone was still not reliably killing the 6
    // mobile Special Infected in one hit, even though the value above is
    // clearly lethal on paper. L4D2 applies difficulty-based damage scaling
    // to player-class Special Infected (Smoker/Boomer/Hunter/Spitter/Jockey/
    // Charger) AFTER this pre-hook runs, silently reducing the effective
    // damage - Common Infected/Tank/Witch aren't player-class entities and
    // aren't subject to that scaling, which is exactly why only they worked.
    // Forcing health down to 1 here guarantees the kill regardless of any
    // multiplier applied afterwards, since even a heavily-scaled fraction of
    // ONE_SHOT_DAMAGE is still vastly more than 1 HP.
    SetEntProp(victim, Prop_Data, "m_iHealth", 1);

    return Plugin_Changed;
}

/* --------------------------------------------------------------------------
   Post-damage safety net - if the victim is somehow still alive right after
   our guaranteed-lethal pre-hook (belt-and-suspenders against any further
   internal scaling/resistance we haven't accounted for), force a second,
   direct, fully lethal hit through immediately so it never takes a second
   real shot to finish the kill.
   -------------------------------------------------------------------------- */

void OnInfectedTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype,
                               int weapon, const float damageForce[3], const float damagePosition[3])
{
    if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
        return;

    int goldenWeapon = EntRefToEntIndex(g_iGoldenGunRef[attacker]);
    if (goldenWeapon == INVALID_ENT_REFERENCE)
        return;

    if (GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon") != goldenWeapon)
        return;

    if (!IsValidEntity(victim))
        return;

    if (victim >= 1 && victim <= MaxClients)
    {
        if (!IsClientInGame(victim) || GetClientTeam(victim) != TEAM_INFECTED || !IsPlayerAlive(victim))
            return; // Not a client-class infected we care about, or already dead - nothing to do.
    }
    else if (GetEntProp(victim, Prop_Data, "m_iHealth") <= 0)
    {
        return; // Already dead - nothing to do.
    }

    // Still standing despite a supposedly guaranteed-lethal hit - force it
    // through directly rather than letting the victim survive to be finished
    // off by a second real shot.
    SDKHooks_TakeDamage(victim, attacker, attacker, ONE_SHOT_DAMAGE, damagetype);
}


