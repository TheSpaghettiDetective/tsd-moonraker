#!/bin/sh

set -e

export OBICO_DIR=$(readlink -f $(dirname "$0"))/..

. "${OBICO_DIR}/scripts/funcs.sh"

SUFFIX=""
MOONRAKER_HOST="127.0.0.1"
MOONRAKER_PORT="7125"
OVERWRITE_CONFIG="n"
SKIP_LINKING="n"

usage() {
  if [ -n "$1" ]; then
    echo "${red}${1}${default}"
    echo ""
  fi
  cat <<EOF
Usage: $0 <[options]>   # Interactive installation to get moonraker-obico set up. Recommended if you have only 1 printer

Options:
          -s   Install moonraker-obico on a Sonic Pad
          -k   Install moonraker-obico on a K1/K1 Max
          -u   Show uninstallation instructions
EOF
}

ensure_deps() {
  report_status "Installing required system packages..."
  PKGLIST="python3 python3-pip"
  if [ $CREALITY_VARIANT = "sonic_pad" ]; then
    opkg install ${PKGLIST}
    pip3 install -q --no-cache-dir virtualenv
  elif [ $CREALITY_VARIANT = "k1" ]; then
    /opt/bin/opkg install ${PKGLIST}
    pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --no-cache-dir virtualenv
  elif [ $CREALITY_VARIANT = "k2" ]; then
    /opt/bin/opkg install ${PKGLIST}
    pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --no-cache-dir virtualenv
  fi
  ensure_venv
  if [ $CREALITY_VARIANT = "sonic_pad" ]; then
    pip3 install -q --no-cache-dir --upgrade pip
    debug Running... "${OBICO_ENV}"/bin/pip3 install -q --require-virtualenv --no-cache-dir -r "${OBICO_DIR}"/requirements.txt
    "${OBICO_ENV}"/bin/pip3 install -q --require-virtualenv --no-cache-dir -r "${OBICO_DIR}"/requirements.txt
  elif [ $CREALITY_VARIANT = "k1" ]; then
    pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --no-cache-dir --upgrade pip
    debug Running... "${OBICO_ENV}"/bin/pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --require-virtualenv --no-cache-dir -r "${OBICO_DIR}"/requirements.txt
    "${OBICO_ENV}"/bin/pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --require-virtualenv --no-cache-dir -r "${OBICO_DIR}"/requirements.txt
  elif [ $CREALITY_VARIANT = "k2" ]; then
    pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --no-cache-dir --upgrade pip
    debug Running... "${OBICO_ENV}"/bin/pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --require-virtualenv --no-cache-dir -r "${OBICO_DIR}"/requirements.txt
    "${OBICO_ENV}"/bin/pip3 install -q --trusted-host pypi.python.org --trusted-host pypi.org --trusted-host=files.pythonhosted.org --require-virtualenv --no-cache-dir -r "${OBICO_DIR}"/requirements.txt
  fi
  echo ""
}

recreate_service() {
  if [ $CREALITY_VARIANT = "sonic_pad" ]; then
    cp "${OBICO_DIR}"/scripts/openwrt_init.d/moonraker_obico_service /etc/init.d/
    rm -f /etc/rc.d/S67moonraker_obico_service
    rm -f /etc/rc.d/K1moonraker_obico_service
    ln -s ../init.d/moonraker_obico_service /etc/rc.d/S67moonraker_obico_service
    ln -s ../init.d/moonraker_obico_service /etc/rc.d/K1moonraker_obico_service
  elif [ $CREALITY_VARIANT = "k1" ]; then
    cp "${OBICO_DIR}"/scripts/openwrt_init.d/S99moonraker_obico /etc/init.d/
  elif [ $CREALITY_VARIANT = "k2" ]; then
    cp "${OBICO_DIR}"/scripts/openwrt_init.d/k2_moonraker_obico_service /etc/init.d/moonraker_obico_service
    PARENT_DIR=$(readlink -f $(dirname "$0")/../..)
    sed --in-place \
      --expression "s,ROOT_HOME_DIR,${HOME},g" \
      --expression "s,PARENT_DIR,${PARENT_DIR},g" \
      /etc/init.d/moonraker_obico_service
    # register the start/stop scripts
    /etc/init.d/moonraker_obico_service enable
  fi
}

uninstall() {
  cat <<EOF
To uninstall Moonraker-Obico, please

1. Run these commands:

-------------------------

rm -rf $OBICO_DIR
rm -rf $OBICO_DIR/../moonraker-obico-env
EOF

  if is_k1; then

    cat <<EOF
rm -f /etc/init.d/S99moonraker_obico
EOF

  elif is_k2; then

    cat <<EOF
/etc/init.d/moonraker_obico_service disable
rm -f /etc/init.d/moonraker_obico_service
EOF

  else

    cat <<EOF
rm -f /etc/init.d/moonraker_obico_service
rm -f /etc/rc.d/S67moonraker_obico_service
rm -f /etc/rc.d/K1moonraker_obico_service
EOF

  fi

  cat <<EOF

-------------------------


2. Remove this line in "printer.cfg":

[include moonraker_obico_macros.cfg]


3. Remove this line in "moonraker.conf":

[include moonraker-obico-update.cfg]

EOF

  exit 0
}

trap 'unknown_error' INT

prompt_for_variant_if_needed() {

  if [ -n "${CREALITY_VARIANT}" ]; then
    return
  fi

  echo "What Creality system are you installing Obico on right now?"
  echo "1) Sonic Pad"
  echo "2) K1/K1 Max"
  echo "3) K2"
  echo "4) Other"
  echo ""

  read user_input
  if [ "$user_input" = "1" ]; then
      CREALITY_VARIANT="sonic_pad"
  elif [ "$user_input" = "2" ]; then
      CREALITY_VARIANT="k1"
  elif [ "$user_input" = "3" ]; then
      CREALITY_VARIANT="k2"
  else
      echo "Obico doesn't currently support this model."
      exit 0
  fi
}

# Parse command line arguments
while getopts "sku" arg; do
    case $arg in
        s) CREALITY_VARIANT="sonic_pad" ;;
        k) CREALITY_VARIANT="k1" ;;
        u) prompt_for_variant_if_needed && uninstall ;;
        *) usage && exit 1;;
    esac
done

prompt_for_variant_if_needed

if is_k1; then
  MOONRAKER_CONF_DIR="/usr/data/printer_data/config"
  MOONRAKER_LOG_DIR="/usr/data/printer_data/logs"
elif is_k2; then
  MOONRAKER_CONF_DIR="/mnt/UDISK/printer_data/config"
  MOONRAKER_LOG_DIR="/mnt/UDISK/printer_data/logs"
else
  MOONRAKER_CONF_DIR="/mnt/UDISK/printer_config"
  MOONRAKER_LOG_DIR="/mnt/UDISK/printer_logs"
fi

MOONRAKER_CONFIG_FILE="${MOONRAKER_CONF_DIR}/moonraker.conf"
OBICO_CFG_FILE="${MOONRAKER_CONF_DIR}/moonraker-obico.cfg"
OBICO_UPDATE_FILE="${MOONRAKER_CONF_DIR}/moonraker-obico-update.cfg"
OBICO_LOG_FILE="${MOONRAKER_LOG_DIR}/moonraker-obico.log"

welcome
ensure_deps

if ! cfg_existed ; then
  create_config
fi

recreate_service
recreate_update_file

trap - INT

if [ $SKIP_LINKING != "y" ]; then
  debug Running... "sh ${OBICO_DIR}/scripts/link.sh" -c "${OBICO_CFG_FILE}" -n \"${SUFFIX:1}\" -S
  sh "${OBICO_DIR}/scripts/link.sh" -c "${OBICO_CFG_FILE}" -n "${SUFFIX:1}" -S
fi
