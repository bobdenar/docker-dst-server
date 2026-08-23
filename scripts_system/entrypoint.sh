#!/bin/bash
set -Eeuo pipefail

# Mods this cluster's 4-shard (Forest/Cave/Island/Volcano) setup structurally depends
# on. Gem Core is required by other mods that import it, so it's always installed and
# enabled on every shard. Island Adventures ports the Shipwrecked/Volcano content the
# Island and Volcano shards generate their worlds from, and needs its separate IA Core
# dependency to even load (without it, its modmain.lua errors out with "variable ...
# is not declared" and the shard process crashes) -- but IA Core's forest_map.lua
# override breaks worldgen on a plain (non-Island/Volcano) map with "attempt to index
# local 'start_loc' (a nil value)", so both must stay enabled ONLY on Island/Volcano,
# never on Master/Caves. DST_MOD_IDS / DST_MOD_IDS_* from the environment only add
# extra mods on top of all this, they never remove it.
CORE_MOD_IDS_ALL_SHARDS="1378549454"
CORE_MOD_IDS_ISLAND_VOLCANO="1467214795,3435352667"

DIR_MODS_SYS="/opt/dst_server/mods"
DIR_MODS_USER="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/mods"
FILE_CLUSTER_TOKEN="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/cluster_token.txt"
FILE_CLUSTER_INI="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/cluster.ini"
FILE_MODS_SETUP="${DIR_MODS_USER}/dedicated_server_mods_setup.lua"
FILE_MODOVERRIDES_MASTER="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/Master/modoverrides.lua"
FILE_MODOVERRIDES_CAVES="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/Caves/modoverrides.lua"
FILE_MODOVERRIDES_ISLAND="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/Island/modoverrides.lua"
FILE_MODOVERRIDES_VOLCANO="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/Volcano/modoverrides.lua"

# set -e error handler.
on_error() {
    echo >&2 "Error on line ${1}${3+: ${3}}; RET ${2}."
    exit "$2"
}
trap 'on_error ${LINENO} $?' ERR 2>/dev/null || true # some shells don't have ERR trap.

if [ "$1" == "dontstarve_dedicated_server_nullrenderer" ] || [ "$1" == "supervisord" ]; then
    # create a default server config if there is none
    if [ ! -d "${DST_USER_DATA_PATH}/DoNotStarveTogether" ]; then
        echo "Creating default server config..."
	mkdir -p "${DST_USER_DATA_PATH}"
        cp -r /opt/dst_default_config/* "${DST_USER_DATA_PATH}"
        touch "${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA/cluster_token.txt"
    fi

    # fill cluster token from environment variable
    if [ -n "${DST_CLUSTER_TOKEN:-}" ]; then
	echo "Filling cluster token from environment variable"
	printf "%s" "${DST_CLUSTER_TOKEN}" > "${FILE_CLUSTER_TOKEN}"
    fi

    # apply cluster.ini settings from environment variables
    if [ -f "${FILE_CLUSTER_INI}" ]; then
	# name, description and password have no default: only touched if explicitly set
	set_cluster_ini_optional() {
	    local key="$1" value="$2"
	    if [ -n "${value}" ]; then
		sed -i "s/^${key} =.*/${key} = ${value}/" "${FILE_CLUSTER_INI}"
	    fi
	}
	# every other setting always applies, falling back to its default value
	set_cluster_ini() {
	    local key="$1" value="$2"
	    sed -i "s/^${key} =.*/${key} = ${value}/" "${FILE_CLUSTER_INI}"
	}

	echo "Applying cluster.ini settings from environment variables"

	set_cluster_ini_optional "cluster_name" "${DST_CLUSTER_NAME:-}"
	set_cluster_ini_optional "cluster_description" "${DST_CLUSTER_DESCRIPTION:-}"
	set_cluster_ini_optional "cluster_password" "${DST_CLUSTER_PASSWORD:-}"

	set_cluster_ini "offline_cluster" "${DST_OFFLINE_CLUSTER:-false}"
	set_cluster_ini "lan_only_cluster" "${DST_LAN_ONLY_CLUSTER:-false}"
	set_cluster_ini "whitelist_slots" "${DST_WHITELIST_SLOTS:-1}"
	set_cluster_ini "cluster_intention" "${DST_CLUSTER_INTENTION:-social}"
	set_cluster_ini "autosaver_enabled" "${DST_AUTOSAVER_ENABLED:-true}"

	set_cluster_ini "game_mode" "${DST_GAME_MODE:-survival}"
	set_cluster_ini "max_players" "${DST_MAX_PLAYERS:-64}"
	set_cluster_ini "pvp" "${DST_PVP:-false}"
	set_cluster_ini "pause_when_empty" "${DST_PAUSE_WHEN_EMPTY:-true}"
	set_cluster_ini "vote_kick_enabled" "${DST_VOTE_KICK_ENABLED:-false}"

	set_cluster_ini "steam_group_only" "${DST_STEAM_GROUP_ONLY:-false}"
	set_cluster_ini "steam_group_id" "${DST_STEAM_GROUP_ID:-0}"
	set_cluster_ini "steam_group_admins" "${DST_STEAM_GROUP_ADMINS:-false}"

	set_cluster_ini "console_enabled" "${DST_CONSOLE_ENABLED:-true}"
	set_cluster_ini "max_snapshots" "${DST_MAX_SNAPSHOTS:-6}"
    fi

    # check cluster token file format
    if [ ! -f "${FILE_CLUSTER_TOKEN}" ]; then
        >&2 echo "Please fill in \`DoNotStarveTogether/Cluster_IA/cluster_token.txt\` with your cluster token and restart server!"
        exit
    else
        if [ -z "$(tail -c 1 "${FILE_CLUSTER_TOKEN}")" ]; then
            # the cluster_token.txt needs to be terminated without newline, try to fix
            mv "${FILE_CLUSTER_TOKEN}" /tmp/cluster_token.txt
            tr -d '\n' < /tmp/cluster_token.txt > "${FILE_CLUSTER_TOKEN}"
            rm -f /tmp/cluster_token.txt
        fi
    fi

    # fix config file permission
    chown -R "${DST_USER}:${DST_GROUP}" "${DST_USER_DATA_PATH}"

    # protect our mods dir
    # if the mods dir is already a symlink, then we temporary remove it to protect it, so that it survives a container restart
    if [[ -L "${DIR_MODS_SYS}" ]]; then
    	rm -f "${DIR_MODS_SYS}"
	cp -r /opt/dst_default_config/DoNotStarveTogether/Cluster_IA/mods "${DIR_MODS_SYS}"
    fi

    # Update game
    # note that the update process modifies (resets) the mods folder so we symlink that later
    echo "Updating server..."
    steamcmd +runscript /opt/steamcmd_scripts/install_dst_server

    # if there are no mods config, use the one that comes with the server
    if [ ! -d "${DIR_MODS_USER}" ]; then
        echo "Creating default mod config..."
        mkdir -p "${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_IA"
        cp -r "${DIR_MODS_SYS}" "${DIR_MODS_USER}"
    fi

    # inject mods: CORE_MOD_IDS_ALL_SHARDS + CORE_MOD_IDS_ISLAND_VOLCANO (always
    # present) plus whatever DST_MOD_IDS adds from the environment
    {
	all_mod_ids="${CORE_MOD_IDS_ALL_SHARDS},${CORE_MOD_IDS_ISLAND_VOLCANO}${DST_MOD_IDS:+,${DST_MOD_IDS}}"
	echo "Applying mod list from environment variables"

	# writes the list of workshop ids to download to dedicated_server_mods_setup.lua
	generate_mods_setup() {
	    local file="$1"
	    shift
	    {
		echo "-- generated from DST_MOD_IDS by entrypoint.sh, do not edit by hand"
		for id in "$@"; do
		    echo "ServerModSetup(\"${id}\")"
		done
	    } > "${file}"
	}

	IFS=',' read -ra mod_ids_raw <<< "${all_mod_ids}"
	mod_ids=()
	for id in "${mod_ids_raw[@]}"; do
	    mod_ids+=("$(echo "${id}" | xargs)")
	done

	generate_mods_setup "${FILE_MODS_SETUP}" "${mod_ids[@]}"

	# each shard's enabled set is CORE_MOD_IDS_ALL_SHARDS (+ CORE_MOD_IDS_ISLAND_VOLCANO
	# on Island/Volcano only) plus its own override (DST_MOD_IDS_<SHARD>), falling back
	# to the shared DST_MOD_IDS
	enabled_master="${CORE_MOD_IDS_ALL_SHARDS},${DST_MOD_IDS_MASTER:-${DST_MOD_IDS:-}}"
	enabled_caves="${CORE_MOD_IDS_ALL_SHARDS},${DST_MOD_IDS_CAVES:-${DST_MOD_IDS:-}}"
	enabled_island="${CORE_MOD_IDS_ALL_SHARDS},${CORE_MOD_IDS_ISLAND_VOLCANO},${DST_MOD_IDS_ISLAND:-${DST_MOD_IDS:-}}"
	enabled_volcano="${CORE_MOD_IDS_ALL_SHARDS},${CORE_MOD_IDS_ISLAND_VOLCANO},${DST_MOD_IDS_VOLCANO:-${DST_MOD_IDS:-}}"

	# merge (add-if-missing, preserve configuration_options, disable-if-removed)
	# instead of a blind regeneration, so in-game mod config survives restarts
	merge_modoverrides "${FILE_MODOVERRIDES_MASTER}" "${all_mod_ids}" "${enabled_master}"
	merge_modoverrides "${FILE_MODOVERRIDES_CAVES}" "${all_mod_ids}" "${enabled_caves}"
	merge_modoverrides "${FILE_MODOVERRIDES_ISLAND}" "${all_mod_ids}" "${enabled_island}"
	merge_modoverrides "${FILE_MODOVERRIDES_VOLCANO}" "${all_mod_ids}" "${enabled_volcano}"
    }

    # override server mods folder with the user provided one
    rm -rf "${DIR_MODS_SYS}"
    ln -s "${DIR_MODS_USER}" "${DIR_MODS_SYS}"

    # update mods
    # Note: cluster-agnostic downloading is somehow broken
    # https://forums.kleientertainment.com/forums/topic/128188-what-is-ugc/?do=findComment&comment=1440420
    echo "Updating mods..."
    su --preserve-environment --group "${DST_GROUP}" -c "dontstarve_dedicated_server_nullrenderer -persistent_storage_root \"${DST_USER_DATA_PATH}\" -ugc_directory \"${DST_USER_DATA_PATH}\"/ugc -cluster Cluster_IA -only_update_server_mods" "${DST_USER}"

    # remove any existing supervisor socket
    rm -f /var/run/supervisor.sock

    # create the unix socket file for supervisor
    touch /var/run/supervisor.sock
fi

exec "$@"
