/*
    [E-BOT] Wallhack for Zombies
    
    Description:
    Forces E-BOT Zombies to be aware of human locations through walls by overriding
    the pev_enemy field, allowing bots to navigate and hunt humans even without
    line of sight.
*/

#include <amxmodx>
#include <fakemeta>
#include <fakemeta_util>
#include <hamsandwich>
#include <cstrike>

// Plugin Information
#define PLUGIN_NAME     "[E-BOT] Zombie Wallhack"
#define PLUGIN_VERSION  "1.0"
#define PLUGIN_AUTHOR   "KuNh4"

// Configuration Defines
#define TASK_ID_BASE 201125
#define MAX_PLAYERS 32

// CVars
new g_pCvarEnabled
new g_pCvarDebug
new g_pCvarMaxDistance
new g_pCvarUpdateInterval
new g_pCvarMinDistance

// Task Management
new bool:g_bTaskRunning

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)
    
    // Register CVars
    g_pCvarEnabled = register_cvar("ebot_wallhack", "1")
    // ^ 0 = disabled, 1 = enabled
    
    g_pCvarDebug = register_cvar("ebot_wallhack_debug", "0")
    // ^ 0 = no debug, 1 = show debug messages
    
    g_pCvarMaxDistance = register_cvar("ebot_wallhack_max_distance", "4096.0")
    // ^ Maximum detection distance (units)
    
    g_pCvarUpdateInterval = register_cvar("ebot_wallhack_hunt_interval", "10.0")
    // ^ How often to update bot targets (in seconds)
    // ^ Higher values = less frequent updates = less aim flicking (bots) 
    
    g_pCvarMinDistance = register_cvar("ebot_wallhack_min_distance", "0.0")
    // ^ Minimum "scent" distance - bots only get forced target if human is FURTHER than this
    // ^ If human is CLOSER, bot uses normal navigation
    // ^ Set to 0.0 to disable distance check (always force target)

    // Server command to display info
    register_srvcmd("ebot_wallhack_info", "ServerCmd_Info")

    server_print("[E-BOT Zombie Wallhack] Plugin has loaded successfully! [Type ebot_wallhack_info]")
    
    set_task(1.0, "task_dynamic_wallhack", TASK_ID_BASE)
}

public plugin_cfg()
{
    // Auto-execute config file if it exists
    server_cmd("exec addons/amxmodx/configs/ebot_wallhack.cfg")
}

public ServerCmd_Info()
{
    server_print("========================================")
    server_print(" %s v%s by %s", PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)
    server_print("========================================")
    server_print(" Status: %s", get_pcvar_num(g_pCvarEnabled) ? "Active [Zombie Only]" : "Deactivated")
    server_print(" Debug mode: %s", get_pcvar_num(g_pCvarDebug) ? "ON" : "OFF")
    server_print("----------------------------------------")
    server_print(" Update Interval: %.1f seconds", get_pcvar_float(g_pCvarUpdateInterval))
    server_print(" Maximum Detection Distance: %.0f units", get_pcvar_float(g_pCvarMaxDistance))
    server_print(" Minimum Hunt Distance: %.0f units%s", 
        get_pcvar_float(g_pCvarMinDistance), 
        get_pcvar_float(g_pCvarMinDistance) == 0.0 ? " [DISABLED - Always Force]" : "")
    server_print("----------------------------------------")
    
    return PLUGIN_HANDLED
}

/*
    Dynamic Task Manager: Adjusts task interval based on CVAR
    This checks the interval CVAR and reschedules the task accordingly
*/
public task_dynamic_wallhack()
{
    // Check if feature is enabled
    if (!get_pcvar_num(g_pCvarEnabled))
    {
        if (g_bTaskRunning)
        {
            g_bTaskRunning = false
            if (get_pcvar_num(g_pCvarDebug))
                client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 System disabled")
        }
        
        // Reschedule check
        set_task(1.0, "task_dynamic_wallhack", TASK_ID_BASE)
        return
    }
    
    if (!g_bTaskRunning)
    {
        g_bTaskRunning = true
        if (get_pcvar_num(g_pCvarDebug))
            client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 System enabled")
    }
    
    // Update all zombie bots
    update_zombie_bot_targets()
    
    // Reschedule based on CVAR interval
    new Float:fInterval = get_pcvar_float(g_pCvarUpdateInterval)
    
    // Clamp interval to reasonable range (minimum 0.5 seconds)
    if (fInterval < 0.5)
        fInterval = 0.5
    
    set_task(fInterval, "task_dynamic_wallhack", TASK_ID_BASE)
}

/*
    Core Function: Scans all bots and assigns nearest human as target
    
    Enhanced Logic:
    1. Checks if bot already has line of sight to an enemy
    2. Applies distance threshold to prevent close-range flicking
    3. Only forces pev_enemy when conditions are met
*/
update_zombie_bot_targets()
{
    new iPlayers[MAX_PLAYERS], iNum, iPlayer
    new bool:bDebug = bool:get_pcvar_num(g_pCvarDebug)
    new Float:fMaxDistance = get_pcvar_float(g_pCvarMaxDistance)
    new Float:fMaxDistSq = fMaxDistance * fMaxDistance
    new Float:fMinDistance = get_pcvar_float(g_pCvarMinDistance)
    new Float:fMinDistSq = fMinDistance * fMinDistance
    new bool:bUseMinDist = (fMinDistance > 0.0)
    
    if (bDebug)
    {
        client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 Update cycle (interval:^3 %.1fs^1, min_dist:^3 %.0f^1)", 
            get_pcvar_float(g_pCvarUpdateInterval), fMinDistance)
    }
    
    // Get all alive players
    get_players(iPlayers, iNum, "a")
    
    new iZombieBots = 0, iTargetsForced = 0, iSkippedLOS = 0, iSkippedDistance = 0
    
    // Iterate through all alive players
    for (new i = 0; i < iNum; i++)
    {
        iPlayer = iPlayers[i]
        
        // Check if player is a bot
        if (!is_user_bot(iPlayer))
            continue
        
        // Get player's team
        new iTeam = get_user_team(iPlayer)
        
        // Check if on Terrorist team (zombie team in ZP)
        if (iTeam != 1)
            continue
        
        iZombieBots++
        
        // Check if bot already has a valid enemy and has LINE OF SIGHT to them
        new iCurrentEnemy = pev(iPlayer, pev_enemy)
        
        if (is_valid_player(iCurrentEnemy))
        {
            // Bot has an enemy set - now check if they actually have LOS
            if (has_line_of_sight(iPlayer, iCurrentEnemy))
            {
                // Bot has TRUE line of sight - don't override
                if (bDebug)
                {
                    new szBotName[32], szEnemyName[32]
                    get_user_name(iPlayer, szBotName, charsmax(szBotName))
                    get_user_name(iCurrentEnemy, szEnemyName, charsmax(szEnemyName))
                    client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 Bot^3 %s^1 has TRUE LOS to^3 %s^1 - skipping", 
                        szBotName, szEnemyName)
                }
                iSkippedLOS++
                continue
            }
            else
            {
                // Bot has enemy set but NO line of sight - we can override
                if (bDebug)
                {
                    new szBotName[32]
                    get_user_name(iPlayer, szBotName, charsmax(szBotName))
                    client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 Bot^3 %s^1 has enemy but NO LOS - can override", 
                        szBotName)
                }
            }
        }
        
        // Find nearest human target
        new iTarget, Float:fTargetDistSq
        iTarget = find_nearest_human(iPlayer, fMaxDistSq, fTargetDistSq)
        
        if (iTarget > 0)
        {
            // Check minimum distance threshold
            if (bUseMinDist && fTargetDistSq < fMinDistSq)
            {
                // Target is too close - let bot use normal navigation
                if (bDebug)
                {
                    new szBotName[32], szTargetName[32]
                    get_user_name(iPlayer, szBotName, charsmax(szBotName))
                    get_user_name(iTarget, szTargetName, charsmax(szTargetName))
                    client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 Bot^3 %s^1 target^3 %s^1 too close (^3%.0f^1 < ^3%.0f^1) - skipping", 
                        szBotName, szTargetName, floatsqroot(fTargetDistSq), fMinDistance)
                }
                iSkippedDistance++
                continue
            }
            
            // Target is far enough - force wallhack logic
            set_pev(iPlayer, pev_enemy, iTarget)
            
            // Get target position for pathfinding
            new Float:vTargetOrigin[3]
            pev(iTarget, pev_origin, vTargetOrigin)
            
            // Update bot's view angles to point toward target
            new Float:vBotOrigin[3]
            pev(iPlayer, pev_origin, vBotOrigin)
            
            // Calculate direction vector from bot to target
            new Float:vDirection[3]
            vDirection[0] = vTargetOrigin[0] - vBotOrigin[0]
            vDirection[1] = vTargetOrigin[1] - vBotOrigin[1]
            vDirection[2] = vTargetOrigin[2] - vBotOrigin[2]
            
            // Convert direction to angles
            new Float:vAngles[3]
            vector_to_angle(vDirection, vAngles)
            
            // Update bot angles to face target
            set_pev(iPlayer, pev_v_angle, vAngles)
            set_pev(iPlayer, pev_angles, vAngles)
            
            // Set ideal yaw for smooth bot rotation
            set_pev(iPlayer, pev_ideal_yaw, vAngles[1])
            
            // Force bot to "see" the target
            set_pev(iPlayer, pev_dmgtime, get_gametime())
            
            iTargetsForced++
            
            if (bDebug)
            {
                new szBotName[32], szTargetName[32]
                get_user_name(iPlayer, szBotName, charsmax(szBotName))
                get_user_name(iTarget, szTargetName, charsmax(szTargetName))
                client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 Bot^3 %s^1 FORCED target^3 %s^1 (dist:^3 %.0f^1)", 
                    szBotName, szTargetName, floatsqroot(fTargetDistSq))
            }
        }
        else
        {
            // No valid target found - clear enemy
            set_pev(iPlayer, pev_enemy, 0)
        }
    }
    
    if (bDebug)
    {
        client_print_color(0, print_team_default, "^4[BOT WALLHACK]^1 Summary: Bots:^3 %d^1 | Forced:^3 %d^1 | Skipped(LOS):^3 %d^1 | Skipped(Dist):^3 %d^1", 
            iZombieBots, iTargetsForced, iSkippedLOS, iSkippedDistance)
    }
}


/*
    Helper Function: Finds the nearest alive human to a zombie bot
    
    Parameters:
    - iBot: The bot entity ID to search from
    - fMaxDistSq: Maximum squared distance to consider
    - &fFoundDistSq: Output parameter - distance to found target
    
    Returns: Entity ID of nearest human, or 0 if none found
*/
find_nearest_human(iBot, Float:fMaxDistSq, &Float:fFoundDistSq)
{
    new Float:vBotOrigin[3]
    pev(iBot, pev_origin, vBotOrigin)
    
    new Float:fMinDistSq = fMaxDistSq
    new iNearestHuman = 0
    
    new iPlayers[MAX_PLAYERS], iNum, iPlayer
    get_players(iPlayers, iNum, "ah") // "a" = alive, "h" = no HLTV
    
    for (new i = 0; i < iNum; i++)
    {
        iPlayer = iPlayers[i]
        
        // Skip the bot itself
        if (iPlayer == iBot)
            continue
        
        // Check if player is on Counter-Terrorist team (human team in ZP)
        if (get_user_team(iPlayer) != 2)
            continue
        
        // Calculate squared distance
        new Float:vPlayerOrigin[3]
        pev(iPlayer, pev_origin, vPlayerOrigin)
        
        new Float:fDistSq = vector_distance_squared(vBotOrigin, vPlayerOrigin)
        
        // Check if this is the closest human so far
        if (fDistSq < fMinDistSq)
        {
            fMinDistSq = fDistSq
            iNearestHuman = iPlayer
        }
    }
    
    // Output the distance to the found target
    fFoundDistSq = fMinDistSq
    
    return iNearestHuman
}

/*
    Utility Function: Validates if entity is a connected, alive player
*/
bool:is_valid_player(iPlayer)
{
    if (iPlayer < 1 || iPlayer > MAX_PLAYERS)
        return false
    
    if (!is_user_connected(iPlayer))
        return false
    
    if (!is_user_alive(iPlayer))
        return false
    
    return true
}

/*
    Utility Function: Calculates squared distance between two points
*/
Float:vector_distance_squared(const Float:vPoint1[3], const Float:vPoint2[3])
{
    new Float:fDx = vPoint1[0] - vPoint2[0]
    new Float:fDy = vPoint1[1] - vPoint2[1]
    new Float:fDz = vPoint1[2] - vPoint2[2]
    
    return (fDx * fDx + fDy * fDy + fDz * fDz)
}

/*
    Utility Function: Checks if there is TRUE line of sight between two entities
    Uses engine TraceLine to detect walls/obstacles
    
    Parameters:
    - iPlayer1: First entity (usually the bot)
    - iPlayer2: Second entity (usually the target)
    
    Returns: true if clear LOS, false if blocked by walls
*/
bool:has_line_of_sight(iPlayer1, iPlayer2)
{
    // Get eye positions for accurate trace
    new Float:vStart[3], Float:vEnd[3]
    
    // Get bot's eye position (view origin)
    pev(iPlayer1, pev_origin, vStart)
    pev(iPlayer1, pev_view_ofs, vEnd) // view offset from origin
    vStart[0] += vEnd[0]
    vStart[1] += vEnd[1]
    vStart[2] += vEnd[2]
    
    // Get target's eye position
    pev(iPlayer2, pev_origin, vEnd)
    new Float:vViewOfs[3]
    pev(iPlayer2, pev_view_ofs, vViewOfs)
    vEnd[0] += vViewOfs[0]
    vEnd[1] += vViewOfs[1]
    vEnd[2] += vViewOfs[2]
    
    // Perform trace line from bot to target
    new iHit = 0
    engfunc(EngFunc_TraceLine, vStart, vEnd, IGNORE_MONSTERS, iPlayer1, 0)
    
    // Get what entity was hit
    iHit = get_tr2(0, TR_pHit)
    
    // Check results:
    // - If hit the target player directly = clear LOS
    // - If hit world (0) or any other entity = blocked
    if (iHit == iPlayer2)
        return true // Direct line of sight to target
    
    // Check if trace reached end point (fraction = 1.0 means no obstruction)
    new Float:fFraction
    get_tr2(0, TR_flFraction, fFraction)
    
    if (fFraction >= 0.99) // Almost complete trace = clear path
        return true
    
    return false // Blocked by wall or obstacle
}

/*
    Cleanup: Remove tasks when plugin unloads
*/
public plugin_end()
{
    remove_task(TASK_ID_BASE)
}