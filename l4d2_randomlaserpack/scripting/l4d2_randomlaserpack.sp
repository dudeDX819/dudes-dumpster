/**
 * =============================================================================
 * Ammo Pack to Laser Sight (L4D2)
 * =============================================================================
 *
 * Description:
 *   When a Survivor deploys an Explosive or Incendiary ammo pack, there is a
 *   configurable chance (default 25%) that the deployed ammo is replaced by
 *   a Laser Sight upgrade pack in its exact position.
 *
 * CVars:
 *   l4d2_randomlaserpack_chance  - Probability (0.0–100.0) of the swap. Default: 25.0
 *   l4d2_randomlaserpack_enabled - 1 = plugin active, 0 = disabled. Default: 1
 *
 * Tested on:
 *   Left 4 Dead 2 (v2.2.x), SourceMod 1.11+
 * =============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// ── Plugin metadata ──────────────────────────────────────────────────────────
public Plugin myinfo =
{
    name        = "[L4D2] Random Laser Sight Pack",
    author      = "dudeDX + Claude AI",
    description = "Grants a chance to turn your deployed ammo into a laser sight! (customizable)",
    version     = "1.0.0",
    url         = ""
};

// ── ConVars ──────────────────────────────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvChance;

// ── Ammo entity classnames that we watch ─────────────────────────────────────
static const char g_sAmmoClasses[][] =
{
    "upgrade_ammo_explosive",
    "upgrade_ammo_incendiary"
};

// ── Laser Sight entity classname ─────────────────────────────────────────────
static const char LASER_CLASSNAME[] = "upgrade_laser_sight";

// ── Forward declarations ──────────────────────────────────────────────────────
void Hook_OnEntityCreated(int entity, const char[] classname);

// =============================================================================
// Plugin load / unload
// =============================================================================

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "l4d2_randomlaserpack_enabled",
        "1",
        "Enable (1) or disable (0) the ammo pack Laser Sight replacement. (default: 1)",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_cvChance = CreateConVar(
        "l4d2_randomlaserpack_chance",
        "25.0",
        "Percentage chance (0–100) that a deployed ammo pack is replaced by a Laser Sight. (default: 25)",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 100.0
    );

    // Auto-create the plugin's config file under cfg/sourcemod/
    AutoExecConfig(true, "ammo_to_lasersight");

    // Hook new entity spawns
    HookEntityOutput("upgrade_ammo_explosive",  "OnPlayerPickup", Callback_AmmoPickup);
    HookEntityOutput("upgrade_ammo_incendiary", "OnPlayerPickup", Callback_AmmoPickup);
}

// =============================================================================
// Entity creation hook – catch the moment an ammo pack is spawned in the world
// =============================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;

    // Only care about explosive / incendiary ammo packs
    bool isAmmo = false;
    for (int i = 0; i < sizeof(g_sAmmoClasses); i++)
    {
        if (StrEqual(classname, g_sAmmoClasses[i], false))
        {
            isAmmo = true;
            break;
        }
    }

    if (!isAmmo)
        return;

    // We need to wait one frame so the entity's origin is fully initialised.
    // Use SDKHooks' SpawnPost to fire after the entity has been placed.
    SDKHook(entity, SDKHook_SpawnPost, Hook_AmmoSpawnPost);
}

// =============================================================================
// SpawnPost hook – entity is fully initialised; roll the dice
// =============================================================================

public void Hook_AmmoSpawnPost(int entity)
{
    SDKUnhook(entity, SDKHook_SpawnPost, Hook_AmmoSpawnPost);

    if (!g_cvEnabled.BoolValue)
        return;

    // Roll the dice
    float roll = GetRandomFloat(0.0, 100.0);
    if (roll > g_cvChance.FloatValue)
        return;   // no swap this time

    // --- Find who deployed this ammo (the thrower / placer) ---
    // The "m_hOwnerEntity" netprop stores the deployer.
    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");

    // Grab the world position & angles before we remove the entity
    float vOrigin[3], vAngles[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vOrigin);
    GetEntPropVector(entity, Prop_Send, "m_angRotation", vAngles);

    // Remove the ammo pack
    RemoveEntity(entity);

    // Spawn a Laser Sight in its place
    int laser = CreateEntityByName(LASER_CLASSNAME);
    if (laser == -1)
    {
        LogError("[Ammo→LaserSight] Failed to create %s", LASER_CLASSNAME);
        return;
    }

    DispatchSpawn(laser);
    TeleportEntity(laser, vOrigin, vAngles, NULL_VECTOR);

    // Notify chat
    if (owner > 0 && owner <= MaxClients && IsClientInGame(owner))
    {
        char sName[MAX_NAME_LENGTH];
        GetClientName(owner, sName, sizeof(sName));

        // Broadcast to all connected clients
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                PrintToChat(i,
                    "\x04[%s]\x01 got lucky! Their ammo pack was replaced by a \x05Laser Sight\x01!",
                    sName
                );
            }
        }
    }
}

// =============================================================================
// Safety net: entity output hook fires when a player *picks up* an ammo pack.
// Because the SpawnPost replacement happens before any pickup is possible this
// callback should never fire for swapped entities, but it's kept here as a
// reference / extension point.
// =============================================================================

public void Callback_AmmoPickup(const char[] output, int caller, int activator, float delay)
{
    // Reserved for future use – e.g. reroll on pickup instead of on spawn.
}

// =============================================================================
// Helper: is the entity classname one of our watched ammo types?
// (Useful if extending the logic later.)
// =============================================================================
stock bool IsAmmoEntity(int entity)
{
    if (!IsValidEntity(entity))
        return false;

    char cls[64];
    GetEntityClassname(entity, cls, sizeof(cls));

    for (int i = 0; i < sizeof(g_sAmmoClasses); i++)
    {
        if (StrEqual(cls, g_sAmmoClasses[i], false))
            return true;
    }
    return false;
}
