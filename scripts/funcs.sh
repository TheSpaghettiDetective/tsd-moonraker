#!/bin/sh

DEBUG="n"

green=$(echo -en "\e[92m")
yellow=$(echo -en "\e[93m")
magenta=$(echo -en "\e[35m")
red=$(echo -en "\e[91m")
cyan=$(echo -en "\e[96m")
default=$(echo -en "\e[39m")


cfg_existed() {
  if [ -f "${OBICO_CFG_FILE}" ] ; then
    if [ $OVERWRITE_CONFIG = "y" ]; then
      backup_config_file="${OBICO_CFG_FILE}-$(date '+%Y-%m-%d')"
      echo -e "${yellow}\n!!!WARNING: Overwriting ${OBICO_CFG_FILE}..."
      cp  ${OBICO_CFG_FILE} ${backup_config_file}
      echo -e "Old file moved to ${backup_config_file}\n${default}"
      return 1
    else
      return 0
    fi
  else
    return 1
  fi
}

is_k1() {
  if [ -n "$CREALITY_VARIANT" -a "$CREALITY_VARIANT" = "k1" ]; then
    return 0
  else
    return 1
  fi
}

is_k2() {
  if [ -n "$CREALITY_VARIANT" -a "$CREALITY_VARIANT" = "k2" ]; then
    return 0
  else
    return 1
  fi
}

create_config() {
  if [ -z "${OBICO_SERVER}" ]; then
    print_header " Obico Server URL "
    cat <<EOF

Now tell us what Obico Server you want to link your printer to.
You can use a self-hosted Obico Server or the Obico Cloud. For more information, please visit: https://www.obico.io.
For self-hosted server, specify "http://server_ip:port". For instance, http://192.168.0.5:3334.

EOF
    if [ -n "$CREALITY_VARIANT" ]; then
        printf "The Obico Server. Press 'enter' to accept the default [https://app.obico.io]: "
        read user_input
        # If user_input is empty, assign the default value
        : ${user_input:="https://app.obico.io"}
    else
        read -p "The Obico Server (Don't change unless you are linking to a self-hosted Obico Server): " -e -i "https://app.obico.io" user_input
    fi
    echo ""
    OBICO_SERVER="${user_input%/}"
  fi

  debug OBICO_SERVER: ${OBICO_SERVER}

  report_status "Creating config file ${OBICO_CFG_FILE} ..."
  cat <<EOF > "${OBICO_CFG_FILE}"
[server]
url = ${OBICO_SERVER}

[moonraker]
host = ${MOONRAKER_HOST}
port = ${MOONRAKER_PORT}
# api_key = <grab one or set trusted hosts in moonraker>

[webcam]
disable_video_streaming = False

# CAUTION: Don't modify the settings below unless you know what you are doing
#   In most cases webcam configuration will be automatically retrived from moonraker
#
# Lower target_fps if ffmpeg is using too much CPU. Capped at 25 for Pro users (including self-hosted) and 5 for Free users
# target_fps = 25
#
# snapshot_url = http://127.0.0.1:8080/?action=snapshot
# stream_url = http://127.0.0.1:8080/?action=stream
# flip_h = False
# flip_v = False
# rotation = 0
# aspect_ratio_169 = False

[logging]
path = ${OBICO_LOG_FILE}
# level = INFO

[tunnel]
# CAUTION: Don't modify the settings below unless you know what you are doing
# dest_host = 127.0.0.1
# dest_port = 80
# dest_is_ssl = False

EOF
}

recreate_update_file() {
  cat <<EOF > "${OBICO_UPDATE_FILE}"
[update_manager ${OBICO_SERVICE_NAME}]
type: git_repo
path: ${OBICO_DIR}
origin: ${OBICO_REPO}
env: ${OBICO_ENV}/bin/python
requirements: requirements.txt
install_script: install.sh
managed_services:
  ${OBICO_SERVICE_NAME}
EOF

  if ! grep -q "include moonraker-obico-update.cfg" "${MOONRAKER_CONFIG_FILE}" ; then
    echo "" >> "${MOONRAKER_CONFIG_FILE}"
    echo "[include moonraker-obico-update.cfg]" >> "${MOONRAKER_CONFIG_FILE}"
	fi

  "${OBICO_DIR}/scripts/ensure_include_cfgs.sh" "${MOONRAKER_CONF_DIR}/printer.cfg"
}


ensure_venv() {
  OBICO_ENV="${OBICO_DIR}/../moonraker-obico-env"
  if [ ! -f "${OBICO_ENV}/bin/activate" ] ; then
    report_status "Creating python virtual environment for moonraker-obico..."
    mkdir -p "${OBICO_ENV}"
    if is_k1; then
      virtualenv -p /opt/bin/python3 --system-site-packages "${OBICO_ENV}"
    else
      virtualenv -p /usr/bin/python3 --system-site-packages "${OBICO_ENV}"
    fi
  fi
}

report_status() {
  echo -e "${magenta}###### $*\n${default}"
}

exit_on_error() {
  oops
  cat <<EOF

The installation has run into an error:

${red}${1}${default}

Please fix the error above and re-run this setup script:

-------------------------------------------------------------------------------------------------
cd ~/moonraker-obico
./install.sh
-------------------------------------------------------------------------------------------------

EOF
  need_help
  exit 1
}

unknown_error() {
  exit_on_error "Installation interrupted by user or for unknown error."
}


debug() {
  if [ $DEBUG = "y" ]; then
    echo -e "DEBUG: ${magenta}###### $*${default}"
  fi
}

banner() {
  echo -en "${cyan}"
  cat "${OBICO_DIR}/scripts/banner"
  echo -en "${default}"
}

brand() {
  echo -en "${cyan}"
  cat "${OBICO_DIR}/scripts/brand"
  echo -en "${default}"
}

welcome() {
  brand
  echo ""
  print_header "> Obico for Klipper (Moonraker-Obico) <"
  echo -n "${cyan}"
  print_centered_line ""
  print_centered_line "* AI-Powered Failure Detection"
  print_centered_line "* Free Remote Monitoring and Access "
  print_centered_line "* 25FPS High-Def Webcam Streaming "
  print_centered_line "* Free 4.9-Star Mobile App"
  print_centered_line ""

  print_header "="
  echo ""
}

oops() {
  cat <<EOF

   ____
  / __ \\
 | |  | | ___   ___   ___   ___  _ __  ___
 | |  | |/ _ \\ / _ \\ / _ \\ / _ \\| '_ \\/ __|
 | |__| | (_) | (_) | (_) | (_) | |_) \\__ \\  _   _   _
  \\____/ \\___/ \\___/ \\___/ \\___/| .__/|___/ (_) (_) (_)
                                | |
                                |_|


EOF
}

need_help() {
  cat <<EOF
Need help? Stop by:

- The Obico's help docs: https://www.obico.io/help/
- The Moonraker-Obico support channel: https://www.obico.io/discord-obico-klipper
- The Obico discord community: https://www.obico.io/discord/

EOF
}

print_centered_line() {
  local line="$@"
    local line_length=${#line}
    local padding_length=$(( (65 - line_length) / 2 ))

    local padding=""
    i=0
    while [ $i -lt $padding_length ]; do
      padding="$padding "
      i=$((i + 1))
    done

    local centered_line="###${padding}${line} ${padding}###"
    echo -e "$centered_line"
}

print_header() {
  local text="$1"
  local line_length=72
  local text_length=${#text}

  # Calculate the number of "=" characters to add on each side
  local padding_length=$(( (line_length - text_length) / 2 ))

  # Create the padding string filled with "=" characters
  local padding="$(printf '%*s' "$padding_length" | tr ' ' '=')"

  # Print the final line with the centered text
  echo "${cyan}${padding}${text}${padding}${default}"
}
