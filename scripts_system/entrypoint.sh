#!/bin/bash
set -Eeuo pipefail

DIR_MODS_SYS="/opt/dst_server/mods"
DIR_MODS_USER="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1/mods"
FILE_CLUSTER_TOKEN="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1/cluster_token.txt"
FILE_CLUSTER_INI="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1/cluster.ini"
FILE_MODS_SETUP="${DIR_MODS_USER}/dedicated_server_mods_setup.lua"
FILE_MODOVERRIDES_MASTER="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1/Master/modoverrides.lua"
FILE_MODOVERRIDES_CAVES="${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1/Caves/modoverrides.lua"

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
        touch "${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1/cluster_token.txt"
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

	set_cluster_ini "game_mode" "${DST_GAME_MODE:-endless}"
	set_cluster_ini "max_players" "${DST_MAX_PLAYERS:-10}"
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
        >&2 echo "Please fill in \`DoNotStarveTogether/Cluster_1/cluster_token.txt\` with your cluster token and restart server!"
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
	cp -r /opt/dst_default_config/DoNotStarveTogether/Cluster_1/mods "${DIR_MODS_SYS}"
    fi

    # Update game
    # note that the update process modifies (resets) the mods folder so we symlink that later
    echo "Updating server..."
    steamcmd +runscript /opt/steamcmd_scripts/install_dst_server

    # if there are no mods config, use the one that comes with the server
    if [ ! -d "${DIR_MODS_USER}" ]; then
        echo "Creating default mod config..."
        mkdir -p "${DST_USER_DATA_PATH}/DoNotStarveTogether/Cluster_1"
        cp -r "${DIR_MODS_SYS}" "${DIR_MODS_USER}"
    fi

    # inject mods from environment variables
    if [ -n "${DST_MOD_IDS:-}" ]; then
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

	IFS=',' read -ra mod_ids_raw <<< "${DST_MOD_IDS}"
	mod_ids=()
	for id in "${mod_ids_raw[@]}"; do
	    mod_ids+=("$(echo "${id}" | xargs)")
	done

	generate_mods_setup "${FILE_MODS_SETUP}" "${mod_ids[@]}"

	# merge (add-if-missing, preserve configuration_options, disable-if-removed)
	# instead of a blind regeneration, so in-game mod config survives restarts
	merge_modoverrides "${FILE_MODOVERRIDES_MASTER}" "${DST_MOD_IDS}" "${DST_MOD_IDS_MASTER:-${DST_MOD_IDS}}"
	merge_modoverrides "${FILE_MODOVERRIDES_CAVES}" "${DST_MOD_IDS}" "${DST_MOD_IDS_CAVES:-${DST_MOD_IDS}}"
    fi

    # override server mods folder with the user provided one
    rm -rf "${DIR_MODS_SYS}"
    ln -s "${DIR_MODS_USER}" "${DIR_MODS_SYS}"

    # update mods
    # Note: cluster-agnostic downloading is somehow broken
    # https://forums.kleientertainment.com/forums/topic/128188-what-is-ugc/?do=findComment&comment=1440420
    echo "Updating mods..."
    su --preserve-environment --group "${DST_GROUP}" -c "dontstarve_dedicated_server_nullrenderer -persistent_storage_root \"${DST_USER_DATA_PATH}\" -ugc_directory \"${DST_USER_DATA_PATH}\"/ugc -cluster Cluster_1 -only_update_server_mods" "${DST_USER}"

    # remove any existing supervisor socket
    rm -f /var/run/supervisor.sock

    # create the unix socket file for supervisor
    touch /var/run/supervisor.sock
fi

exec "$@"
